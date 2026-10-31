import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Smack

struct DockerMonitorTests {
    private static let engine = #"{"Name":"desktop-linux","OperatingSystem":"Docker Desktop","ServerVersion":"28.0","MemTotal":8589934592,"NCPU":8}"#
    private static let containers = #"""
    {"id":"abc","name":"/web","image":"nginx","state":"running","status":"running (healthy)","project":"demo","ports":{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"},{"HostIp":"::","HostPort":"8080"}],"53/udp":[{"HostIp":"127.0.0.1","HostPort":"8080"}],"443/tcp":null}}
    {"id":"def","name":"/old","image":"postgres","state":"exited","status":"exited (exit 0)","project":"","ports":null}
    """#

    @Test func countsPublishedPortsByProtocolAndDeduplicatesDualStack() throws {
        let containers = try DockerCollector.decodeLines(Self.containers, as: DockerContainer.self)
        let snapshot = DockerSnapshot(containers: containers)
        #expect(snapshot.runningCount == 1)
        #expect(snapshot.stoppedCount == 1)
        #expect(snapshot.openPortCount == 2)
        #expect(containers[0].displayName == "web")
        #expect(containers[0].group == "demo")
        #expect(containers[1].group == "Started alone")
        #expect(containers[0].portDescriptions.contains("[::]:8080 → 80/tcp"))
        #expect(containers[0].portDescriptions.count == 3)
    }

    @Test func browserLinksUsePublishedHostPortsAndReachableAddresses() {
        let cases: [(String, String, String, String?)] = [
            ("0.0.0.0", "8080", "80/tcp", "http://localhost:8080"),
            ("", "8080", "80/tcp", "http://localhost:8080"),
            ("::", "8080", "80/tcp", "http://[::1]:8080"),
            ("::1", "8443", "443/tcp", "https://[::1]:8443"),
            ("127.0.0.1", "3000", "80/tcp", "http://127.0.0.1:3000"),
            ("192.0.2.10", "443", "8443/tcp", "https://192.0.2.10:443"),
            ("0.0.0.0", "5353", "53/udp", nil),
            ("0.0.0.0", "invalid", "80/tcp", nil),
            ("0.0.0.0", "0", "80/tcp", nil),
            ("0.0.0.0", "65536", "80/tcp", nil)
        ]
        for (host, port, containerPort, expected) in cases {
            let binding = DockerPortBinding(HostIp: host, HostPort: port)
            #expect(binding.browserURL(containerPort: containerPort)?.absoluteString == expected)
        }
    }

    @Test func stoppedContainersDoNotContributePorts() throws {
        let data = Self.containers.replacingOccurrences(of: #""state":"running""#, with: #""state":"exited""#)
        let snapshot = DockerSnapshot(containers: try DockerCollector.decodeLines(data, as: DockerContainer.self))
        #expect(snapshot.openPortCount == 0)
        #expect(snapshot.runningCount == 0)
    }

    @Test func unreachableEngineDoesNotReportZeroContainers() async {
        let collector = DockerCollector(run: { _, _ in .unavailable("Cannot connect to the Docker daemon") })
        let snapshot = await collector.collect(executable: "/docker", details: false)
        #expect(snapshot.runningCount == nil)
        #expect(snapshot.openPortCount == nil)
        #expect(snapshot.warnings.first?.contains("Cannot connect") == true)
    }

    @Test func pausedContainersRetainPublishedPorts() throws {
        let data = Self.containers.replacingOccurrences(of: #""state":"running""#, with: #""state":"paused""#)
        let snapshot = DockerSnapshot(containers: try DockerCollector.decodeLines(data, as: DockerContainer.self))
        #expect(snapshot.runningCount == 0)
        #expect(snapshot.openPortCount == 2)
    }

    @Test func detailsDecodeStatsDiskAndMemoryUnits() async {
        let collector = DockerCollector(run: { _, args in
            switch args.first {
            case "info": return .init(status: 0, output: Self.engine, error: "")
            case "container" where args[1] == "ls": return .init(status: 0, output: "abc\ndef", error: "")
            case "container": return .init(status: 0, output: Self.containers, error: "")
            case "stats": return .init(status: 0, output: #"{"ID":"abc","CPUPerc":"1.25%","MemUsage":"1.5MiB / 8GiB","MemPerc":"0.01%","NetIO":"1kB / 2kB","BlockIO":"0B / 0B","PIDs":"3"}"#, error: "")
            case "image": return .init(status: 0, output: #"{"ID":"sha256:abc","Repository":"nginx","Tag":"latest","Size":"20MB","CreatedSince":"2 days ago"}"#, error: "")
            case "volume": return .init(status: 0, output: #"{"Name":"data","Driver":"local","Scope":"local"}"#, error: "")
            case "network": return .init(status: 0, output: #"{"ID":"net","Name":"bridge","Driver":"bridge","Scope":"local"}"#, error: "")
            case "system": return .init(status: 0, output: #"{"Type":"Images","TotalCount":"3","Active":"1","Size":"2.1GB","Reclaimable":"1GB (48%)"}"#, error: "")
            default: return .unavailable("Unexpected command")
            }
        })
        let snapshot = await collector.collect(executable: "/docker", details: true)
        #expect(snapshot.warnings.isEmpty)
        #expect(snapshot.images?.first?.Repository == "nginx")
        #expect(snapshot.volumes?.first?.Name == "data")
        #expect(snapshot.networks?.first?.Driver == "bridge")
        #expect(snapshot.containerMemoryBytes == 1_572_864)
        #expect(snapshot.stats.first?.CPUPerc == "1.25%")
        #expect(snapshot.disk?.first?.Reclaimable == "1GB (48%)")
        var missingStats = snapshot
        missingStats.stats = []
        #expect(missingStats.containerMemoryBytes == nil)
    }

    @Test func summarySkipsStatsAndDiskCommands() async {
        let collector = DockerCollector(run: { _, args in
            switch args.first {
            case "info": return .init(status: 0, output: Self.engine, error: "")
            case "container" where args[1] == "ls": return .init(status: 0, output: "abc\ndef\n", error: "")
            case "container" where args[1] == "inspect": return .init(status: 0, output: Self.containers, error: "")
            default:
                Issue.record("Unexpected summary command: \(args)")
                return .unavailable("Unexpected command")
            }
        })
        let snapshot = await collector.collect(executable: "/docker", details: false)
        #expect(snapshot.runningCount == 1)
        #expect(snapshot.engine?.MemTotal == 8589934592)
        #expect(snapshot.warnings.isEmpty)
    }

    @Test func detailFailuresPreserveCountsAndExposeUnavailableMetrics() async {
        let collector = DockerCollector(run: { _, args in
            if args.first == "info" { return .init(status: 0, output: Self.engine, error: "") }
            if args.first == "container", args[1] == "ls" { return .init(status: 0, output: "abc\ndef", error: "") }
            if args.first == "container", args[1] == "inspect" { return .init(status: 0, output: Self.containers, error: "") }
            return .unavailable("Not available")
        })
        let snapshot = await collector.collect(executable: "/docker", details: true)
        #expect(snapshot.runningCount == 1)
        #expect(snapshot.stats.isEmpty)
        #expect(snapshot.disk == nil)
        #expect(snapshot.images == nil)
        #expect(snapshot.volumes == nil)
        #expect(snapshot.networks == nil)
        #expect(snapshot.warnings.count == 5)
    }

    @Test func emptyEngineReportsZeroAndTruncatedDataIsRejected() async {
        let empty = DockerCollector(run: { _, args in
            .init(status: 0, output: args.first == "info" ? Self.engine : "", error: "")
        })
        let snapshot = await empty.collect(executable: "/docker", details: false)
        #expect(snapshot.runningCount == 0)
        #expect(snapshot.openPortCount == 0)
        let truncated = DockerCollector(run: { _, _ in
            .init(status: 0, output: Self.engine, error: "", truncated: true)
        })
        let failed = await truncated.collect(executable: "/docker", details: false)
        #expect(failed.containers == nil)
        #expect(failed.warnings.first?.contains("limit") == true)
    }
    @Test func imageTagsHaveDistinctRowIdentities() throws {
        let images = try DockerCollector.decodeLines("""
        {"ID":"sha256:abc","Repository":"nginx","Tag":"latest","Size":"20MB","CreatedSince":"2 days ago"}
        {"ID":"sha256:abc","Repository":"nginx","Tag":"stable","Size":"20MB","CreatedSince":"2 days ago"}
        """, as: DockerImage.self)
        #expect(images[0].ID == images[1].ID)
        #expect(images[0].id != images[1].id)
    }

    @Test func emptyInventoriesAreAvailableAndDistinctFromCollectionFailures() async {
        let collector = DockerCollector(run: { _, args in
            .init(status: 0, output: args.first == "info" ? Self.engine : "", error: "")
        })
        let snapshot = await collector.collect(executable: "/docker", details: true)
        #expect(snapshot.images?.isEmpty == true)
        #expect(snapshot.volumes?.isEmpty == true)
        #expect(snapshot.networks?.isEmpty == true)
        #expect(snapshot.warnings.isEmpty)
    }

    @Test func filtersPartitionEveryContainerStateAndActionsMatchState() {
        for state in ["running", "paused", "restarting", "exited", "created", "dead", "removing"] {
            let container = DockerContainer(id: "full-id", name: "/test", image: "test", state: state,
                                            status: state, project: "", ports: nil)
            #expect(DockerContainerFilter.running.matches(container) == (state == "running"))
            #expect(DockerContainerFilter.stopped.matches(container) != DockerContainerFilter.running.matches(container))
            #expect(DockerContainerAction.pause.isAvailable(for: container) == (state == "running"))
            #expect(DockerContainerAction.unpause.isAvailable(for: container) == (state == "paused"))
            #expect(DockerContainerAction.start.isAvailable(for: container) == ["created", "exited"].contains(state))
            if ["dead", "removing"].contains(state) {
                #expect(DockerContainerAction.allCases.allSatisfy { !$0.isAvailable(for: container) })
            }
        }
    }

    @Test func fullInspectionsPreserveAllFieldsAndUseExplicitObjectTypes() async throws {
        for kind in [DockerObjectKind.container, .image, .volume, .network, .engine, .storage] {
            let target = DockerInspectionTarget(kind: kind, identifier: "full-object-id", name: "Example")
            let collector = DockerCollector(run: { executable, arguments in
                #expect(executable == "/docker")
                switch kind {
                case .engine:
                    #expect(arguments == ["info", "--format", "{{json .}}"])
                case .storage:
                    #expect(arguments == ["system", "df", "--verbose"])
                    return .init(status: 0, output: "Images space usage:\nall storage details", error: "")
                case .network:
                    #expect(arguments == ["network", "inspect", "--verbose", "--", "full-object-id"])
                default:
                    #expect(arguments == [kind.rawValue, "inspect", "--", "full-object-id"])
                }
                return .init(status: 0, output: #"[{"Id":"full-object-id","Config":{"Env":["EXAMPLE=complete"]},"UnknownField":{"nested":[1,2]}}]"#, error: "")
            })
            let output = try await collector.inspect(executable: "/docker", target: target)
            if kind == .storage {
                #expect(output == "Images space usage:\nall storage details")
            } else {
                #expect(output.contains("EXAMPLE=complete"))
                #expect(output.contains("UnknownField"))
                #expect(output.contains("\n"))
                #expect(try JSONSerialization.jsonObject(with: Data(output.utf8)) is [Any])
            }
        }
    }

    @Test func inspectionRejectsFailurePartialAndMalformedOutput() async {
        let target = DockerInspectionTarget(kind: .container, identifier: "missing", name: "Missing")
        for result in [CommandRunner.Result.unavailable("No such container"),
                       .init(status: 0, output: "[]", error: "", timedOut: true),
                       .init(status: 0, output: "[]", error: "", truncated: true),
                       .init(status: 0, output: "[]", error: "", cancelled: true),
                       .init(status: 0, output: "{", error: "")] {
            let collector = DockerCollector(run: { _, _ in result })
            await #expect(throws: (any Error).self) { try await collector.inspect(executable: "/docker", target: target) }
        }
    }

    private actor LifecycleDaemon {
        var data = DockerMonitorTests.containers
        var commands: [[String]] = []
        let fail: Bool

        init(fail: Bool = false) { self.fail = fail }

        func run(_ arguments: [String]) -> CommandRunner.Result {
            if arguments.first == "container",
               DockerContainerAction.allCases.contains(where: { $0.rawValue == arguments.dropFirst().first }) {
                commands.append(arguments)
                if fail { return .unavailable("daemon denied action") }
                data = data.replacingOccurrences(of: #""state":"exited""#, with: #""state":"running""#)
                return .init(status: 0, output: "def\n", error: "")
            }
            let output: String
            if arguments.first == "info" { output = DockerMonitorTests.engine }
            else if arguments.prefix(2) == ["container", "ls"] { output = "abc\ndef" }
            else if arguments.prefix(2) == ["container", "inspect"] { output = data }
            else { output = "" }
            return .init(status: 0, output: output, error: "")
        }
    }

    @Test @MainActor func lifecycleUsesFullIdentityRefreshesInventoryAndExposesFailure() async throws {
        for fail in [false, true] {
            let daemon = LifecycleDaemon(fail: fail)
            let model = DockerMonitor(collector: .init(run: { _, arguments in await daemon.run(arguments) }), locate: { "/docker" })
            await model.refresh()
            let container = try #require(model.snapshot?.containers?.first { $0.id == "def" })
            let operation = DockerContainerOperation(action: .start, container: container)
            await model.perform(operation)
            #expect(await daemon.commands == [["container", "start", "--", "def"]])
            #expect(model.operationFailed == fail)
            #expect(model.snapshot?.runningCount == (fail ? 1 : 2))
            #expect(model.operationOutput.contains(fail ? "daemon denied action" : "def"))
            #expect(!model.busy)
            model.dismissOperation()
            #expect(model.operation == nil)
        }
    }

    @Test @MainActor func unavailableActionsDoNotRunAndDefaultFilterIsRunning() async throws {
        let daemon = LifecycleDaemon()
        let model = DockerMonitor(collector: .init(run: { _, arguments in await daemon.run(arguments) }), locate: { "/docker" })
        await model.refresh()
        let container = try #require(model.snapshot?.containers?.first { $0.id == "abc" })
        await model.perform(DockerContainerOperation(action: .start, container: container))
        #expect(await daemon.commands.isEmpty)
        #expect(model.operationFailed)
        #expect(DockerDetailView(model: model).containerFilter == .running)
    }

    private actor SlowStatisticsDaemon {
        var continuation: CheckedContinuation<Void, Never>?
        var statsStarted = false
        var commands: [[String]] = []

        func run(_ arguments: [String]) async -> CommandRunner.Result {
            if arguments.first == "container", DockerContainerAction.allCases.contains(where: { $0.rawValue == arguments.dropFirst().first }) {
                commands.append(arguments)
                return .init(status: 0, output: "abc", error: "")
            }
            if arguments.first == "stats", !statsStarted {
                statsStarted = true
                await withCheckedContinuation { continuation = $0 }
            }
            let output: String
            if arguments.first == "info" { output = DockerMonitorTests.engine }
            else if arguments.prefix(2) == ["container", "ls"] { output = "abc" }
            else if arguments.prefix(2) == ["container", "inspect"] {
                output = DockerMonitorTests.containers.components(separatedBy: "\n").first ?? ""
            } else { output = "" }
            return .init(status: 0, output: output, error: "")
        }

        func finish() { continuation?.resume(); continuation = nil }
    }

    @Test @MainActor func runningContainerControlsRemainAvailableDuringStatisticsRefresh() async throws {
        let daemon = SlowStatisticsDaemon()
        let model = DockerMonitor(collector: .init(run: { _, args in await daemon.run(args) }), locate: { "/docker" })
        await model.refresh()
        let container = try #require(model.snapshot?.containers?.first)
        model.detailsWanted = true
        let refresh = Task { await model.refresh() }
        for _ in 0..<100 {
            if await daemon.statsStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await daemon.statsStarted)
        #expect(model.loading)
        let page = DockerDetailView(model: model)
        #expect(page.containerActions(for: container) == [.stop, .restart, .pause])
        let operation = Task { await model.perform(.init(action: .stop, container: container)) }
        await daemon.finish()
        await refresh.value
        await operation.value
        #expect(await daemon.commands == [["container", "stop", "--", "abc"]])
        #expect(!model.operationFailed)
    }

    @Test @MainActor func containerRowsOnlyOfferActionsSupportedByTheirState() {
        let model = DockerMonitor(locate: { "/docker" })
        let page = DockerDetailView(model: model)
        let cases: [(String, [DockerContainerAction])] = [
            ("running", [.stop, .restart, .pause]),
            ("paused", [.unpause]),
            ("exited", [.start, .restart]),
            ("created", [.start, .restart]),
            ("restarting", [.stop, .restart]),
            ("dead", []), ("removing", [])
        ]
        for (state, expected) in cases {
            let container = DockerContainer(id: "abc", name: "web", image: "nginx", state: state,
                                            status: state, project: "", ports: nil)
            #expect(page.containerActions(for: container) == expected)
        }
    }

    @Test @MainActor func sidebarSectionsRenderWithInventory() async throws {
        let collector = DockerCollector(run: { _, args in
            let output: String
            switch args.first {
            case "info": output = Self.engine
            case "container" where args[1] == "ls": output = "abc\ndef"
            case "container": output = Self.containers
            case "image": output = #"{"ID":"sha256:abc","Repository":"nginx","Tag":"latest","Size":"20MB","CreatedSince":"2 days ago"}"#
            case "volume": output = #"{"Name":"demo_data","Driver":"local","Scope":"local"}"#
            case "network": output = #"{"ID":"net","Name":"demo_default","Driver":"bridge","Scope":"local"}"#
            default: output = ""
            }
            return .init(status: 0, output: output, error: "")
        })
        let model = DockerMonitor(collector: collector, locate: { "/docker" })
        model.detailsWanted = true
        await model.refresh()
        let pages = DockerSection.allCases.map { ($0, DockerContainerFilter.running) } + [(.containers, .stopped)]
        for (section, filter) in pages {
            for width in [900.0, 1400.0] {
                let host = NSHostingView(rootView: DockerDetailView(model: model, section: section, containerFilter: filter)
                    .environment(\.colorScheme, .light).background(Color.white))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 650)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                #expect(bitmap.pixelsWide >= Int(width))
                if width == 1400, let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: "/tmp/smack-docker-\(section.rawValue)\(filter == .stopped ? "-stopped" : "").png"))
                }
            }
        }
    }

}
