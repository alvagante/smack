import Foundation
import Testing
@testable import Smack

struct ResourceBudgetTests {
    private actor Commands {
        var values: [[String]] = []
        func record(_ args: [String]) { values.append(args) }
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
        model.detailsWanted = true
        model.section = .storage
        await model.refresh()
        await model.refresh(automatic: true)
        #expect(await commands.values.filter { $0.first == "system" }.count == 1)
        model.section = .images
        await model.refresh()
        await model.refresh(automatic: true)
        #expect(await commands.values.filter { $0.first == "image" }.count == 1)
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
