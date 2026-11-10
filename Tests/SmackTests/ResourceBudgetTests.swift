import Foundation
import Testing
@testable import Smack

struct ResourceBudgetTests {
    private actor Commands {
        var values: [[String]] = []
        func record(_ args: [String]) { values.append(args) }
    }

    private actor Probes {
        var values: [String] = []
        func record(_ host: String, _ port: UInt16) { values.append("\(host):\(port)") }
    }

    @Test @MainActor func webEndpointChecksProbeEachListenerOnceAndSkipOtherProtocols() async {
        let probes = Probes()
        let model = DevServersModel(probe: { host, port in
            await probes.record(host, port)
            return port == 3000 ? .http : nil
        })
        func server(_ ports: [ListeningPort]) -> [DevServer] {
            [DevServer(id: "s", process: ProcessIdentity(pid: 10, startTime: .distantPast), processName: "node", ports: ports)]
        }
        let all = [obsPort(port: 3000, host: "*"), obsPort(port: 3000, host: "::1", fd: 4), obsPort(port: 5432, fd: 5), obsPort(port: 6006, fd: 6)]
        await model.checkWebEndpoints(server(all))
        await model.checkWebEndpoints(server(all))
        #expect(await probes.values.sorted() == ["127.0.0.1:3000", "127.0.0.1:6006", "::1:3000"])
        #expect(model.webSchemes.count == 2)
        // A listener that closes is forgotten, and checked again if it comes back.
        await model.checkWebEndpoints(server(Array(all.prefix(3))))
        await model.checkWebEndpoints(server(all))
        #expect(await probes.values.count == 4)
    }

    @Test func projectDiscoveryRunsNoCommandsAndInspectionRunsOnlyStatusAndLog() async throws {
        let commands = Commands()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("smack-budget-project-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let head = folder.appendingPathComponent("repo/.git/HEAD")
        try FileManager.default.createDirectory(at: head.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: head)
        let ref = folder.appendingPathComponent("repo/.git/refs/heads/main")
        try FileManager.default.createDirectory(at: ref.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abcdef1234567890\n".utf8).write(to: ref)

        let snapshot = ProjectCollector().discover(folders: [folder.path], depth: 2)
        #expect(snapshot.projects.count == 1)
        #expect(await commands.values.isEmpty, "discovery reads directory entries and .git files only")

        let inspector = ProjectGitInspector(run: { _, args in
            await commands.record(args)
            return args.first == "status"
                ? .init(status: 0, output: "# branch.head main\n", error: "")
                : .init(status: 0, output: "abcdef1\u{0}\(1_700_000_000)\u{0}Subject", error: "")
        })
        _ = await inspector.inspect(root: folder.appendingPathComponent("repo").path)
        #expect(await commands.values == [
            ["status", "--porcelain=v2", "--branch"],
            ["log", "-1", "--format=%h%x00%ct%x00%s%x00%aN"],
            ["log", "--since=12.weeks", "-2000", "--format=%ct%x00%aN"],
        ], "the Overview's cadence is one bounded log of dates and authors, no diffs")
    }

    @Test func projectHistoryIsOnDemandBoundedAndCommitDetailsUseOneReadOnlyCommand() async {
        let commands = Commands()
        let inspector = ProjectHistoryInspector(run: { _, args in
            await commands.record(args)
            return .init(status: 0, output: "", error: "")
        })
        #expect(await commands.values.isEmpty)
        _ = await inspector.history(root: "/project")
        #expect(await commands.values == [
            ["log", "-100", "--date-order", "--format=%H%x00%an%x00%ct%x00%s%x00%D"],
            ["for-each-ref", "--count=200", "--sort=-committerdate",
             "--format=%(refname:short) %(objectname:short) %(subject)"],
            ["remote", "-v"],
        ])
        _ = await inspector.commit(root: "/project", id: "--output=/tmp/file")
        #expect(await commands.values.count == 3)
        _ = await inspector.commit(root: "/project", id: "abcdef123456")
        #expect(await commands.values.last == [
            "show", "--no-ext-diff", "--no-textconv", "--format=fuller", "--stat", "--patch", "abcdef123456", "--",
        ])
        #expect(await commands.values.count == 4)
    }

    @Test func dockerOnlyCollectsSelectedDetailsIncludingRemoteFailure() async {
        for section in DockerSection.allCases {
            let commands = Commands()
            let collector = DockerCollector(run: { _, args in
                await commands.record(args)
                let output = args.first == "info"
                    ? #"{"Name":"remote","OperatingSystem":"Linux","ServerVersion":"28","MemTotal":1024,"NCPU":1}"# : ""
                return .init(status: 0, output: output, error: "")
            })
            _ = await collector.collect(executable: "/docker", details: true, section: section)
            let calls = await commands.values
            #expect(calls.contains { $0.first == "stats" } == (section == .containers))
            #expect(calls.contains { $0.first == "system" } == (section == .storage))
            #expect(calls.contains { $0.first == "image" } == (section == .images))
            #expect(calls.contains { $0.first == "volume" } == (section == .volumes))
            #expect(calls.contains { $0.first == "network" } == (section == .networks))
        }
        let commands = Commands()
        let stopped = DockerCollector(run: { _, args in
            await commands.record(args)
            return .unavailable("Remote daemon unreachable")
        })
        let value = await stopped.collect(executable: "/docker", details: true, section: .storage)
        #expect(await commands.values.count == 1)
        #expect(value.disk == nil)
    }

    @Test func largeDockerInventoryUsesBoundedBatchesWithoutStorageCommands() async {
        let commands = Commands()
        let collector = DockerCollector(run: { _, args in
            await commands.record(args)
            let output: String
            if args.first == "info" {
                output = #"{"Name":"remote","OperatingSystem":"Linux","ServerVersion":"28","MemTotal":1024,"NCPU":1}"#
            } else if args.prefix(2) == ["container", "ls"] {
                output = (0..<10_000).map { "id\($0)" }.joined(separator: "\n")
            } else if args.prefix(2) == ["container", "inspect"] {
                output = args.dropFirst(4).map {
                    #"{"id":""# + $0 + #"","name":"/app","image":"test","state":"exited","status":"exited","project":"","ports":null}"#
                }.joined(separator: "\n")
            } else { output = "" }
            return .init(status: 0, output: output, error: "")
        })
        let snapshot = await collector.collect(executable: "/docker", details: true, section: .engine)
        #expect(snapshot.containers?.count == 10_000)
        let calls = await commands.values
        let batches = calls.filter { $0.prefix(2) == ["container", "inspect"] }
        #expect(batches.count == 100)
        #expect(batches.allSatisfy { $0.count <= 104 })
        #expect(!calls.contains { $0.first == "system" || $0.first == "stats" })
    }

    @Test @MainActor func periodicDockerRefreshNeverRequestsStorageAndCachesInventory() async {
        let commands = Commands()
        let model = DockerMonitor(collector: .init(run: { _, args in
            await commands.record(args)
            return .init(status: 0, output: args.first == "info"
                ? #"{"Name":"test","OperatingSystem":"Linux","ServerVersion":"28","MemTotal":1024,"NCPU":1}"# : "", error: "")
        }), locate: { "/docker" })
        model.requestDetails(.storage)
        await model.refresh()
        await model.refresh(automatic: true)
        #expect(await commands.values.filter { $0.first == "system" }.count == 1)
        model.section = .images
        await model.refresh()
        await model.refresh(automatic: true)
        #expect(await commands.values.filter { $0.first == "image" }.count == 1)
    }

    /// The Docker page and a Project's Docker tab both ask for container details; the page that appears next can
    /// ask before the one leaving releases, so statistics stop only when the last one is gone.
    @Test @MainActor func dockerStatisticsRunOnlyWhileAPageRequestsDetails() async {
        let commands = Commands()
        let model = DockerMonitor(collector: .init(run: { _, args in
            await commands.record(args)
            let output = switch args.first {
            case "info": #"{"Name":"test","OperatingSystem":"Linux","ServerVersion":"28","MemTotal":1024,"NCPU":1}"#
            case "container" where args[1] == "ls": "abc"
            case "container": #"{"id":"abc","name":"/web","image":"nginx","state":"running","status":"Up","project":"demo","ports":null}"#
            default: ""
            }
            return .init(status: 0, output: output, error: "")
        }), locate: { "/docker" })
        func statsRuns() async -> Int { await commands.values.filter { $0.first == "stats" }.count }

        await model.refresh(automatic: true)
        #expect(await statsRuns() == 0, "no page asked for details")

        model.requestDetails(.containers)
        model.requestDetails(.containers)
        model.releaseDetails()
        await model.refresh(automatic: true)
        #expect(await statsRuns() == 1, "one page still shows containers")

        model.releaseDetails()
        model.releaseDetails()
        await model.refresh(automatic: true)
        #expect(await statsRuns() == 1, "released by every page, and an extra release does not go negative")
        model.requestDetails(.containers)
        await model.refresh(automatic: true)
        #expect(await statsRuns() == 2)
    }

    @Test func brewOnlyWalksCellarOnCleanupRequest() async {
        for section in BrewSection.allCases {
            let commands = Commands()
            let collector = BrewCollector(run: { _, args in
                await commands.record(args)
                let output: String
                switch args.first {
                case "info", "outdated": output = #"{"formulae":[],"casks":[]}"#
                case "--prefix": output = "/brew"
                case "-sk": output = "42 /brew/Cellar"
                case "services": output = "[]"
                default: output = ""
                }
                return .init(status: 0, output: output, error: "")
            })
            _ = await collector.collect(executable: "/brew", details: true, section: section)
            let calls = await commands.values
            #expect(calls.contains { $0.first == "-sk" } == (section == .cleanup))
            #expect(calls.contains { $0.first == "services" } == (section == .services))
        }
    }

    @Test @MainActor func inspectionCacheEvictsLeastRecentlyUsedAndRejectsOversizedEntry() async {
        let collector = DevEnvironmentCollector(run: { _, _ in .init(status: 0, output: String(repeating: "x", count: 100), error: "") })
        let model = DevEnvironmentMonitor(collector: collector, inspectionBudget: 500)
        let items = (0..<3).map { DevEnvironment(language: .bun, executable: "/bun\($0)", resolvedPath: "/bun\($0)", source: "Test", onPath: false) }
        await model.inspect(items[0])
        await model.inspect(items[1])
        await model.inspect(items[0])
        await model.inspect(items[2])
        #expect(model.inspections[items[0].id] != nil)
        #expect(model.inspections[items[1].id] == nil)
        #expect(model.inspections[items[2].id] != nil)
        let tiny = DevEnvironmentMonitor(collector: collector, inspectionBudget: 1)
        await tiny.inspect(items[0])
        #expect(tiny.inspections.isEmpty)
    }

    @Test func directoryAndBundleWalkBudgetsExposeIncompleteResults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<20 { try Data([1]).write(to: root.appendingPathComponent("file\(index)")) }
        let scan = try HomeDirectory.names(root, limit: 10)
        #expect(scan.names.count == 10)
        #expect(scan.truncated)
        #expect(InstalledAppsCollector.allocatedSize(of: root, entryLimit: 10) == nil)
        #expect(InstalledAppsCollector.allocatedSize(of: root, timeLimit: 0) == nil)
        #expect(InstalledAppsCollector.allocatedSize(of: root) != nil)
    }

    #if !SMACK_APP_STORE
    private actor SlowHost {
        var calls = 0
        var continuation: CheckedContinuation<[NativeMenuBarItemSource]?, Never>?
        func discover() async -> [NativeMenuBarItemSource]? {
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        func finish() { continuation?.resume(returning: nil); continuation = nil }
    }

    @Test @MainActor func slowAccessibilityHostDoesNotBlockMainActorOrOverlapDiscovery() async throws {
        let host = SlowHost()
        let model = NativeMenuBarStore(hostPID: { 123 }, trusted: { true }, discoverHosted: { _, _ in await host.discover() })
        model.setFeatureEnabled(true)
        model.setPanelVisible(true)
        for _ in 0..<100 {
            if await host.calls == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        model.refresh()
        #expect(await host.calls == 1)
        model.setDisplay(42, scale: 2)
        await host.finish()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!model.loadAttempted)
        #expect(model.items.isEmpty)
        model.setPanelVisible(false)
        #expect(HostedMenuBarDiscovery.items(hostPID: 123, budget: 0, displayBounds: .zero, currentPID: 1, windowInfo: { _ in nil }) == nil)
    }
    #endif
}
