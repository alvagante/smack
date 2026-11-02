import Foundation
import SwiftUI
import Testing
import Synchronization
import SmackIPC
@testable import Smack

@Test func baselineDeterministicEncodingAndPortablePaths() throws {
    var a = BaselineDocument(sections: ["apps": .init(items: [
        ["bundleID": "z", "path": "/Users/example/Applications/Z.app", "version": "2"],
        ["bundleID": "a", "path": "/Applications/A.app", "version": "1"]
    ])])
    a.capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    var b = a
    b.sections["apps"]?.items.reverse()
    let bytes = try a.encoded(home: "/Users/example")
    #expect(bytes == (try b.encoded(home: "/Users/example")))
    #expect(!String(decoding: bytes, as: UTF8.self).contains("/Users/example"))
    #expect(try BaselineDocument.decode(bytes).sections["apps"]?.items.last?["path"] == "~/Applications/Z.app")
    #expect(BaselineDocument.normalize("/Users/example2/file", home: "/Users/example") == "/Users/example2/file")
}

@Test func baselineDiffIgnoresVolatilityAndIncompleteSections() {
    let base = BaselineDocument(sections: [
        "listeners": .init(items: [["protocol": "tcp", "scope": "local", "port": "3000", "program": "node", "path": "/bin/node", "pid": "1"]]),
        "apps": .init(items: [["bundleID": "app", "path": "/Applications/App.app", "version": "1"]])
    ])
    var now = base
    now.sections["listeners"]?.items[0]["pid"] = "99"
    now.sections["listeners"]?.durationMs = 999
    #expect(!BaselineDiff.compare(base, now).drift)
    now.sections["apps"] = .init(status: .incomplete, error: "Timed out")
    let partial = BaselineDiff.compare(base, now)
    #expect(!partial.drift)
    #expect(partial.sections["apps"]?.reason != nil)
    #expect(partial.sections["apps"]?.removed.isEmpty == true)
    #expect(partial.exitCode(strict: false) == 0)
    #expect(partial.exitCode(strict: true) == 2)
    now.sections["apps"] = .init(items: [["bundleID": "app", "path": "/Applications/App.app", "version": "2"]])
    let drift = BaselineDiff.compare(base, now)
    #expect(drift.sections["apps"]?.changed.first?.fields["version"]?.old == "1")
    #expect(drift.sections["apps"]?.changed.first?.fields["version"]?.new == "2")
    #expect(drift.exitCode(strict: false) == 2)
    #expect(drift.markdown.contains("macOS"))
    #expect(drift.markdown.contains("version: 1 -> 2"))
}

@Test func baselineAdditionRemovalAndReverseComparison() {
    let a = BaselineDocument(machine: ["model": "MacA"], sections: ["homebrew": .init(items: [
        ["name": "one", "type": "formula", "version": "1"]
    ])])
    let b = BaselineDocument(machine: ["model": "MacB"], sections: ["homebrew": .init(items: [
        ["name": "two", "type": "formula", "version": "2"]
    ])])
    let forward = BaselineDiff.compare(a, b)
    let reverse = BaselineDiff.compare(b, a)
    #expect(forward.sections["homebrew"]?.added == reverse.sections["homebrew"]?.removed)
    #expect(forward.sections["homebrew"]?.removed == reverse.sections["homebrew"]?.added)
    #expect(forward.baseMachine["model"] == "MacA")
    #expect(reverse.baseMachine["model"] == "MacB")
}

@Test func baselineRejectsVersionSizeAndDuplicateKeys() throws {
    let doc = BaselineDocument(sections: ["apps": .init(items: [])])
    var object = try #require(JSONSerialization.jsonObject(with: doc.encoded()) as? [String: Any])
    object["schemaVersion"] = 2
    #expect(throws: BaselineError.self) { try BaselineDocument.decode(JSONSerialization.data(withJSONObject: object)) }
    object["schemaVersion"] = 1
    object["futureField"] = "ignored"
    object.removeValue(forKey: "pinned")
    #expect(try BaselineDocument.decode(JSONSerialization.data(withJSONObject: object)).pinned == false)
    #expect(throws: BaselineError.self) { try BaselineDocument.decode(Data(repeating: 32, count: BaselineDocument.sizeLimit + 1)) }
    let duplicate = BaselineDocument(sections: ["apps": .init(items: [
        ["bundleID": "a", "path": "/a"], ["bundleID": "a", "path": "/a"]
    ])])
    #expect(throws: BaselineError.self) { try BaselineDocument.decode(duplicate.encoded()) }
    #expect(BaselineDiff.compare(duplicate, duplicate).sections["apps"]?.reason == "Duplicate identities")
}

@Test func baselineRetentionProtectsPinsAndGolden() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smack-baselines-" + UUID().uuidString)
    let repo = BaselineRepository(directory: directory)
    var doc = BaselineDocument(name: "golden")
    doc.capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let golden = try await repo.save(doc)
    doc.name = "pinned"; doc.pinned = true; doc.capturedAt.addTimeInterval(1)
    _ = try await repo.save(doc)
    doc.pinned = false
    for i in 1...4 {
        doc.name = "new"; doc.capturedAt.addTimeInterval(Double(i))
        _ = try await repo.save(doc, retention: 2, golden: golden.lastPathComponent)
    }
    let rows = try await repo.list()
    #expect(rows.count == 4)
    #expect(rows.contains { $0.0.lastPathComponent == golden.lastPathComponent })
    #expect(rows.contains { $0.1.pinned })
    #expect(throws: (any Error).self) { try BaselineDocument.read(directory) }
}

private struct FixtureBaselineCollector: BaselineSectionCollector {
    var id: String
    var timeout: Duration = .seconds(1)
    var delay: Duration = .zero
    func collect() async -> BaselineSection {
        do { try await Task.sleep(for: delay) }
        catch { return .init(status: .incomplete, error: "Cancelled", items: [["id": "partial"]]) }
        return .init(items: [["id": "done", "status": "pass"]])
    }
}

@Test func baselineParallelCaptureTimeoutAndCancellation() async throws {
    let document = try await BaselineCapture.capture(collectors: [
        FixtureBaselineCollector(id: "posture"),
        FixtureBaselineCollector(id: "startup", timeout: .milliseconds(20), delay: .seconds(10))
    ], name: "fixture")
    #expect(document.sections["posture"]?.status == .complete)
    #expect(document.sections["startup"]?.status == .incomplete)
    #expect(document.sections["startup"]?.items.first?["id"] == "partial")
    let task = Task {
        try await BaselineCapture.capture(collectors: [
            FixtureBaselineCollector(id: "posture", delay: .seconds(10))
        ], name: "cancel")
    }
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled capture succeeded") }
    catch is CancellationError {} catch { Issue.record("Unexpected cancellation error") }
}

@Test func baselineRequestValidationAndSettingsDefaults() throws {
    for action in ["create", "list", "diff", "export"] {
        var r = ControlRequest(op: "baseline")
        r.action = action
        if action == "export" { r.base = "file.json" }
        #expect(try ControlRequest.decode(JSONEncoder().encode(r)).action == action)
    }
    var r = ControlRequest(op: "baseline")
    r.action = "list"; r.against = "now"
    #expect(throws: ControlError.self) { try r.validate() }
    r = ControlRequest(op: "status"); r.strict = true
    #expect(throws: ControlError.self) { try r.validate() }
    let defaults = try JSONDecoder().decode(CollectionSettings.self, from: Data("{}".utf8))
    #expect(defaults.baselineRetentionCount == 20)
    #expect(!defaults.scheduledDriftCheck)
    #expect(defaults.goldenBaselineID == nil)
    #expect(ActivityEventKind.driftDetected.group == .security)
    #expect(DeepLinkParser.parse(URL(string: "smack://baseline")!).route == .baseline)
}

#if !SMACK_APP_STORE
@Test func baselineCLIReturnsDriftAndErrorCodes() async throws {
    let root = URL(fileURLWithPath: "/tmp/smack-bcli-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let socket = root.appendingPathComponent("c.sock").path
    let server = try ControlServer(paths: [socket]) { request in
        var response = ControlResponse()
        if request.action == "diff" {
            response.metadata = ["drift": request.strict == true ? "true" : "false",
                                 "payload": "{\"sections\":{}}", "markdown": "# Baseline drift"]
        } else if request.action == "create" { response.metadata = ["path": "/tmp/fixture-baseline.json"] }
        else { response.error = .notFound }
        return response
    }
    defer { server.stop() }
    let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug/SmackCLI")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
    func run(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["baseline"] + arguments + ["--socket", socket]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    #expect(try run(["diff", "--json"]).0 == 0)
    let strict = try run(["diff", "--strict", "--json"])
    #expect(strict.0 == 2)
    #expect(strict.1.contains("\"sections\""))
    let created = try run(["create", "--name", "fixture", "--sections", "system"])
    #expect(created.0 == 0)
    #expect(created.1.trimmingCharacters(in: .whitespacesAndNewlines) == "/tmp/fixture-baseline.json")
    #expect(try run(["export", "missing"]).0 == 1)
    #expect(try run(["diff", "--bad-flag", "value"]).0 == 1)
}
#endif

@Test func baselineLiveCaptureBudget() async throws {
    guard ProcessInfo.processInfo.environment["SMACK_BASELINE_LIVE"] == "1" else { return }
    let start = ContinuousClock.now
    let document = try await BaselineCapture.capture(collectors: BaselineDiff.rules.keys.sorted().map {
        MachineBaselineCollector(id: $0, settings: CollectionSettings(), workerExecutable: obsProduct("Smack").path)
    }, name: "Live validation")
    let elapsed = start.duration(to: .now)
    print("Baseline live capture: \(elapsed)")
    for id in document.sections.keys.sorted() {
        let section = document.sections[id]!
        print("Baseline \(id): \(section.status.rawValue), \(section.items.count) items, \(section.durationMs) ms")
    }
    #expect(elapsed < .seconds(60))
    #expect(document.sections.count == 11)
    let encoded = String(decoding: try document.encoded(), as: UTF8.self)
    #expect(!encoded.contains(FileManager.default.homeDirectoryForCurrentUser.path + "/"))
    #expect(!encoded.contains("\"arguments\""))
    #expect(!encoded.contains("\"environment\""))
}

@Test @MainActor func baselinePageRenders() async throws {
    let root = URL(fileURLWithPath: "/tmp/smack-baseline-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaults = try #require(UserDefaults(suiteName: "BaselineUI-" + UUID().uuidString))
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let scheduler = CollectionScheduler(systemCollector: SystemCollector(), processCollector: ProcessCollector(),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(),
        history: history, settings: settings.settings, onSystem: { _ in }, onProcesses: { _ in })
    let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)
    let repository = BaselineRepository(directory: root.appendingPathComponent("baselines"))
    let model = BaselineModel(repository: repository)
    model.name = "Post-onboarding"
    model.note = "Known good workstation"
    let base = BaselineDocument(name: "Post-onboarding", machine: ["model": "Mac15,6", "macOS": "27.2"],
                                sections: ["homebrew": .init(items: [])])
    let now = BaselineDocument(machine: ["model": "Mac15,6", "macOS": "27.2"],
                               sections: ["homebrew": .init(items: [["name": "jq", "type": "formula", "version": "1.8"]])])
    let saved = try await repository.save(base)
    await model.refresh()
    model.baseID = saved.lastPathComponent
    model.diff = BaselineDiff.compare(base, now)
    let host = NSHostingView(rootView: BaselineView(store: store, model: model)
        .environment(\.colorScheme, .light).background(Color.white))
    host.frame = NSRect(x: 0, y: 0, width: 1000, height: 850)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/smack-baseline.png"))
}

@Test func baselineUnknownNestedFieldsAndCoverageSafety() throws {
    let base = BaselineDocument(sections: ["apps": .init(items: [
        ["bundleID": "app", "path": "/Applications/App.app", "version": "1"]
    ], coverage: ["host"])])
    var json = try #require(JSONSerialization.jsonObject(with: base.encoded()) as? [String: Any])
    var machine = try #require(json["machine"] as? [String: Any])
    machine["future"] = ["nested": [1, 2]]
    json["machine"] = machine
    var sections = try #require(json["sections"] as? [String: Any])
    var apps = try #require(sections["apps"] as? [String: Any])
    var items = try #require(apps["items"] as? [[String: Any]])
    items[0]["future"] = ["private": "must be ignored"]
    apps["items"] = items
    sections["apps"] = apps
    sections["futureSection"] = ["newLayout": [1, 2, 3]]
    json["sections"] = sections
    let decoded = try BaselineDocument.decode(JSONSerialization.data(withJSONObject: json))
    #expect(decoded.sections["apps"] == base.sections["apps"])
    #expect(decoded.machine["future"] == nil)
    #expect(decoded.sections["futureSection"]?.status == .unavailable)
    var restricted = base
    restricted.sections["apps"] = .init(items: [], coverage: ["container"])
    let diff = BaselineDiff.compare(base, restricted)
    #expect(!diff.drift)
    #expect(diff.sections["apps"]?.reason?.contains("coverage") == true)
    #expect(diff.sections["apps"]?.removed.isEmpty == true)
}

private struct DuplicateBaselineCollector: BaselineSectionCollector {
    let id = "apps"
    let timeout = Duration.seconds(1)
    func collect() async -> BaselineSection {
        .init(items: [["bundleID": "a", "path": "/a"], ["bundleID": "a", "path": "/a"],
                      ["bundleID": "b", "path": "/b"]])
    }
}

@Test func baselineDuplicateCollectorDoesNotDiscardOtherSections() async throws {
    let doc = try await BaselineCapture.capture(collectors: [
        DuplicateBaselineCollector(), FixtureBaselineCollector(id: "posture")
    ], name: "partial")
    #expect(doc.sections["apps"]?.status == .incomplete)
    #expect(doc.sections["apps"]?.items.count == 1)
    #expect(doc.sections["posture"]?.status == .complete)
}

@Test func baselineOldImportSurvivesRetentionAndMetadataEdits() async throws {
    let root = URL(fileURLWithPath: "/tmp/smack-retention-" + UUID().uuidString)
    let repo = BaselineRepository(directory: root)
    var doc = BaselineDocument(name: "new")
    _ = try await repo.save(doc, retention: 1)
    doc.capturedAt = Date(timeIntervalSince1970: 1)
    let imported = try await repo.save(doc, retention: 1)
    #expect(FileManager.default.fileExists(atPath: imported.path))
    try await repo.update(imported.lastPathComponent, name: "renamed", note: "note", pinned: true)
    let edited = try await repo.load(imported.lastPathComponent)
    #expect(edited.name == "renamed" && edited.note == "note" && edited.pinned)
    #expect(try await repo.list().count == 1)
}

@Test func baselineSchedulePersistsCadenceAndReportsDisabledSections() async throws {
    let root = URL(fileURLWithPath: "/tmp/smack-drift-" + UUID().uuidString)
    let repository = BaselineRepository(directory: root.appendingPathComponent("baselines"))
    let golden = try await repository.save(BaselineDocument(name: "Golden", sections: [
        "system": .init(items: [["macOS": "1"]]),
        "posture": .init(items: [["id": "sip", "status": "pass"]])
    ]))
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    var settings = CollectionSettings()
    settings.scheduledDriftCheck = true
    settings.goldenBaselineID = golden.lastPathComponent
    settings.postureCheckInterval = nil
    let events = Mutex<[ActivityEvent]>([])
    let calls = Mutex(0)
    let scheduler = CollectionScheduler(systemCollector: SystemCollector(), processCollector: ProcessCollector(),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(),
        history: history, settings: settings, onSystem: { _ in }, onProcesses: { _ in },
        onEvents: { batch in events.withLock { $0 += batch } })
    let collect: @Sendable ([MachineBaselineCollector]) async throws -> BaselineDocument = { collectors in
        #expect(collectors.map(\.id) == ["system"])
        calls.withLock { $0 += 1 }
        return BaselineDocument(sections: ["system": .init(items: [["macOS": "2"]])])
    }
    let now = Date()
    async let first: Void = scheduler.checkScheduledDrift(repository: repository, now: now, capture: collect)
    async let second: Void = scheduler.checkScheduledDrift(repository: repository, now: now, capture: collect)
    _ = await (first, second)
    #expect(calls.withLock { $0 } == 1)
    let event = try #require(events.withLock { $0.first })
    #expect(event.kind == .driftDetected)
    #expect(event.details["skipped"] == "posture")
    #expect(event.details["system"] == "added=0,removed=0,changed=1")
    let persisted = try await history.events(from: now.addingTimeInterval(-5), to: now.addingTimeInterval(60),
                                             kinds: [.driftDetected], search: "", limit: 10)
    #expect(persisted.count == 1)
    await scheduler.checkScheduledDrift(repository: repository, now: now.addingTimeInterval(60), capture: collect)
    #expect(calls.withLock { $0 } == 1)
    let restarted = CollectionScheduler(systemCollector: SystemCollector(), processCollector: ProcessCollector(),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(),
        history: history, settings: settings, onSystem: { _ in }, onProcesses: { _ in })
    await restarted.checkScheduledDrift(repository: repository, now: now.addingTimeInterval(120), capture: collect)
    #expect(calls.withLock { $0 } == 1)
    await scheduler.checkScheduledDrift(repository: repository, now: now.addingTimeInterval(86401), capture: collect)
    #expect(calls.withLock { $0 } == 2)
    settings.scheduledDriftCheck = false
    await scheduler.updateFeatureSettings(settings)
    await scheduler.checkScheduledDrift(repository: repository, now: now.addingTimeInterval(172802), capture: collect)
    #expect(calls.withLock { $0 } == 2)
}

@Test func baselineScheduleSuppressesDeliveryWhenDisabledDuringCapture() async throws {
    let root = URL(fileURLWithPath: "/tmp/smack-drift-cancel-" + UUID().uuidString)
    let repository = BaselineRepository(directory: root.appendingPathComponent("baselines"))
    let golden = try await repository.save(BaselineDocument(name: "Golden", sections: [
        "system": .init(items: [["macOS": "1"]])
    ]))
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    var settings = CollectionSettings()
    settings.scheduledDriftCheck = true
    settings.goldenBaselineID = golden.lastPathComponent
    settings.postureCheckInterval = nil
    let scheduler = CollectionScheduler(systemCollector: SystemCollector(), processCollector: ProcessCollector(),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(),
        history: history, settings: settings, onSystem: { _ in }, onProcesses: { _ in })
    settings.scheduledDriftCheck = false
    let disabled = settings
    await scheduler.checkScheduledDrift(repository: repository) { _ in
        await scheduler.updateFeatureSettings(disabled)
        return BaselineDocument(sections: ["system": .init(items: [["macOS": "2"]])])
    }
    #expect(try await history.metadata("baseline.lastDriftCheck." + golden.lastPathComponent) == nil)
    let events = try await history.events(from: Date().addingTimeInterval(-60), to: Date().addingTimeInterval(60),
                                          kinds: [.driftDetected], search: "", limit: 10)
    #expect(events.isEmpty)
}

@Test(arguments: [false, true]) func baselineWorkerExitsWithParent(groupLeader: Bool) async throws {
    let fifo = "/tmp/smack-worker-" + UUID().uuidString
    defer { unlink(fifo) }
    // The held FIFO keeps the worker blocked on its request; the shell then exits as the parent.
    let script = """
        mkfifo "$1" || exit 1; [ "$2" = 1 ] && set -m
        sleep 10 >"$1" 2>/dev/null & s=$!
        "$0" --baseline-section <"$1" >/dev/null 2>&1 & echo $! $s; sleep 1
        """
    let result = await Subprocess.run("/bin/sh", ["-c", script, obsProduct("Smack").path, fifo, groupLeader ? "1" : "0"],
                                      timeout: 5)
    let pids = result.output.split(separator: " ").compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    try #require(pids.count == 2)
    defer { kill(pids[1], SIGKILL) }
    var alive = true
    for _ in 0..<40 where alive {
        alive = kill(pids[0], 0) == 0
        if alive { try await Task.sleep(for: .milliseconds(50)) }
    }
    #expect(!alive)
}
