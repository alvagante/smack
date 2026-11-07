import Foundation
import Synchronization
import Testing
import Darwin
@testable import Smack

// Opt-in evidence harness for spec 004 section 8. Select measurements with
// SMACK_PHASE7=alloc,posture,idle,burst,dropped (comma separated). Timings and counts are
// host evidence, never portable CI assertions. Each result is printed as one `PHASE7 {json}` line.

private func selected(_ name: String) -> Bool {
    (ProcessInfo.processInfo.environment["SMACK_PHASE7"] ?? "").split(separator: ",").contains { $0 == name }
}

private func emit(_ name: String, _ fields: [String: Any]) {
    var fields = fields
    fields["measurement"] = name
    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    print("PHASE7 " + String(data: data, encoding: .utf8)!)
}

private func cpuSeconds(_ who: Int32) -> Double {
    var usage = rusage()
    getrusage(who, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

private func phase7Directory(under parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
    let url = parent.appendingPathComponent("smack-phase7-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: Allocation profiling

private let allocationCount = Atomic<Int>(0)
private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
private let allocationHook: MallocLogger = { type, _, _, _, _, _ in
    // stack_logging_type_alloc is 2; realloc sets both alloc and dealloc.
    if type & 2 != 0 { allocationCount.wrappingAdd(1, ordering: .relaxed) }
}

private func setAllocationHook(_ hook: MallocLogger?) -> Bool {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return false }
    symbol.assumingMemoryBound(to: MallocLogger?.self).pointee = hook
    return true
}

/// Deliberately blocks the calling (main) thread; synchronous so it is allowed from an async test.
private func blockCurrentThread(_ seconds: Double, until finished: () -> Bool) {
    Thread.sleep(forTimeInterval: seconds)
    while !finished() { Thread.sleep(forTimeInterval: 0.1) }
}

private final class Token { var value = 0 }

@Test(.enabled(if: selected("alloc")))
func phase7SystemRuleAllocationProfile() async throws {
    // Validate the counter against a known number of allocations before trusting it.
    #expect(setAllocationHook(allocationHook))
    var keep = [Token]()
    keep.reserveCapacity(1000)
    let before = allocationCount.load(ordering: .relaxed)
    for _ in 0..<1000 { keep.append(Token()) }
    let known = allocationCount.load(ordering: .relaxed) - before
    _ = setAllocationHook(nil)
    #expect(known >= 1000)
    keep.removeAll()

    // A realistic sample: a startup volume, a second volume, interfaces and disks all present.
    func sample(_ index: Int, cpu: Double) -> SystemSample {
        var value = obsSystem(at: 1000 + Double(index), interfaces: [obsInterface("en0", ["10.0.0.1"])], cpu: cpu)
        value.volumes = [
            VolumeSample(name: "Macintosh HD", mountPath: "/", totalBytes: 1_000, availableBytes: 500),
            VolumeSample(name: "Data", mountPath: "/Volumes/Data", totalBytes: 2_000, availableBytes: 1_000)]
        return value
    }
    struct Workload { var name: String; var rules: [AlertRule]; var cpu: Double }
    func rules(_ count: Int, metric: SystemAlertMetric, value: Double, comparison: Comparison = .greaterThan, sustain: TimeInterval = 100_000) -> [AlertRule] {
        (0..<count).map { AlertRule(name: "R\($0)", enabled: true, kind: .systemThreshold(metric: metric, comparison: comparison, value: value, sustain: sustain, clear: nil)) }
    }
    let metrics: [(SystemAlertMetric, Double)] = SystemAlertMetric.allCases.map { ($0, $0 == .volumeFreeRatio || $0 == .startupDiskFreeRatio ? -1 : 1e18) }
    let workloads = [
        Workload(name: "no-rules", rules: [], cpu: 10),
        Workload(name: "cpu-50-armed", rules: rules(50, metric: .cpuTotal, value: 90), cpu: 10),
        Workload(name: "cpu-50-pending-sustain-100000s", rules: rules(50, metric: .cpuTotal, value: 0), cpu: 10),
        Workload(name: "cpu-50-pending-sustain-60s", rules: rules(50, metric: .cpuTotal, value: 0, sustain: 60), cpu: 10),
        Workload(name: "volume-free-50-armed", rules: rules(50, metric: .volumeFreeRatio, value: 0.01, comparison: .lessThan), cpu: 10),
        Workload(name: "all-metrics-armed", rules: metrics.flatMap { rules(4, metric: $0.0, value: $0.1, comparison: $0.0 == .volumeFreeRatio || $0.0 == .startupDiskFreeRatio ? .lessThan : .greaterThan) }, cpu: 10)]
    let iterations = 1000, rounds = 5
    var baseline = Double.infinity
    for workload in workloads {
        let engine = AlertEngine()
        await engine.update(rules: workload.rules)
        var index = 0
        for _ in 0..<50 { _ = await engine.evaluate(system: sample(index, cpu: workload.cpu), expectedInterval: 1); index += 1 }
        var perRound = [Double]()
        for _ in 0..<rounds {
            let samples = (0..<iterations).map { sample(index + $0, cpu: workload.cpu) }
            index += iterations
            _ = setAllocationHook(allocationHook)
            let start = allocationCount.load(ordering: .relaxed)
            for value in samples { _ = await engine.evaluate(system: value, expectedInterval: 1) }
            let used = allocationCount.load(ordering: .relaxed) - start
            _ = setAllocationHook(nil)
            perRound.append(Double(used) / Double(iterations))
        }
        let best = perRound.min()!
        if workload.name == "no-rules" { baseline = best }
        emit("system-rule-allocations", ["workload": workload.name, "rules": workload.rules.count, "iterations_per_round": iterations,
            "rounds": rounds, "allocations_per_evaluate_min": best, "allocations_per_evaluate_rounds": perRound,
            "above_no_rules_baseline": best - baseline, "counter_known_allocations": known])
    }
}

// MARK: Posture child cost

#if !SMACK_APP_STORE
@Test(.enabled(if: selected("posture")))
func phase7PostureCollectionCost() async throws {
    var runs = [[String: Any]]()
    for run in 0..<5 {
        let selfBefore = cpuSeconds(RUSAGE_SELF), childrenBefore = cpuSeconds(RUSAGE_CHILDREN)
        let start = ContinuousClock.now
        let snapshot = await PostureCollector().collect(listeners: nil)
        let wall = start.duration(to: .now)
        let seconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
        let counts = Dictionary(grouping: snapshot.checks, by: { $0.status.rawValue }).mapValues(\.count)
        runs.append(["run": run, "wall_s": seconds, "children_cpu_s": cpuSeconds(RUSAGE_CHILDREN) - childrenBefore,
                     "self_cpu_s": cpuSeconds(RUSAGE_SELF) - selfBefore, "checks": snapshot.checks.count, "statuses": counts])
    }
    emit("posture-collection", ["runs": runs])
}
#endif

// MARK: Production watcher

private final class Counter: Sendable {
    let paths = Atomic<Int>(0), scans = Atomic<Int>(0)
}

#if !SMACK_APP_STORE
/// Idle cost of the production PersistenceWatcher on the real watched roots. Home-directory activity
/// outside the persistence paths still reaches the callback, so the path count is recorded beside CPU.
@MainActor @Test(.enabled(if: selected("idle")))
func phase7ProductionWatcherIdleCost() async throws {
    let seconds = Double(ProcessInfo.processInfo.environment["SMACK_PHASE7_IDLE_SECONDS"] ?? "") ?? 600
    let dbRoot = try phase7Directory()
    defer { try? FileManager.default.removeItem(at: dbRoot) }
    let history = try HistoryRepository(databaseURL: dbRoot.appendingPathComponent("history.sqlite"))
    let scanner = PersistenceScanner(overrides: { _ in .init(status: 0, output: "disabled services = {}", error: "") })
    let counter = Counter()
    let watcher = PersistenceWatcher(isRelevant: { path in
        counter.paths.wrappingAdd(1, ordering: .relaxed)
        return PersistenceWatcher.relevant(path)
    }) { _ in
        _ = await scanner.scan(metadata: history)
        counter.scans.wrappingAdd(1, ordering: .relaxed)
    }
    watcher.start(pollInterval: nil)
    defer { watcher.stop() }
    // The first scan is the start-up cost, reported separately.
    let startupCPU = cpuSeconds(RUSAGE_SELF), startupChildren = cpuSeconds(RUSAGE_CHILDREN)
    while counter.scans.load(ordering: .relaxed) < 1 { try await Task.sleep(for: .milliseconds(100)) }
    try await Task.sleep(for: .seconds(3))
    let startup = cpuSeconds(RUSAGE_SELF) - startupCPU
    let scansAtStart = counter.scans.load(ordering: .relaxed), pathsAtStart = counter.paths.load(ordering: .relaxed)
    let cpuStart = cpuSeconds(RUSAGE_SELF), childrenStart = cpuSeconds(RUSAGE_CHILDREN)
    let clockStart = ContinuousClock.now
    var minutes = [Double]()
    var minuteStart = cpuStart
    var elapsed = 0.0
    while elapsed < seconds {
        let step = min(60, seconds - elapsed)
        try await Task.sleep(for: .seconds(step))
        elapsed += step
        let now = cpuSeconds(RUSAGE_SELF)
        minutes.append((now - minuteStart) / step * 100)
        minuteStart = now
    }
    let wall = clockStart.duration(to: .now)
    let wallSeconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
    let cpu = cpuSeconds(RUSAGE_SELF) - cpuStart
    emit("production-watcher-idle", ["window_s": wallSeconds, "cpu_s": cpu, "cpu_percent": cpu / wallSeconds * 100,
        "children_cpu_s": cpuSeconds(RUSAGE_CHILDREN) - childrenStart, "per_minute_cpu_percent": minutes,
        "paths_delivered": counter.paths.load(ordering: .relaxed) - pathsAtStart, "scans_in_window": counter.scans.load(ordering: .relaxed) - scansAtStart,
        "startup_scan_cpu_s": startup, "startup_children_cpu_s": cpuSeconds(RUSAGE_CHILDREN) - startupChildren,
        "watched": "real home, /Library/LaunchAgents, /Library/LaunchDaemons, /private/etc, /Library/Preferences"])
}

/// Burst cost: production watcher and scanner with enrichment, fixtures under a unique home subdirectory.
@MainActor @Test(.enabled(if: selected("burst") && ProcessInfo.processInfo.environment["SMACK_ENRICHMENT_APP"] != nil))
func phase7ProductionWatcherBurstCost() async throws {
    let child = ProcessInfo.processInfo.environment["SMACK_ENRICHMENT_APP"]!
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".smack-phase7-burst-" + UUID().uuidString)
    let agents = root.appendingPathComponent("agents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dbRoot = try phase7Directory()
    defer { try? FileManager.default.removeItem(at: dbRoot) }
    let history = try HistoryRepository(databaseURL: dbRoot.appendingPathComponent("history.sqlite"))
    let script = dbRoot.appendingPathComponent("unsigned-agent")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
    chmod(script.path, 0o755)
    let programs = ["/bin/ls", child, script.path, "/usr/bin/true"]
    let scanner = PersistenceScanner(files: [], directory: { $0 == .userAgents ? agents.path : dbRoot.appendingPathComponent("absent").path },
                                     overrides: { _ in .init(status: 0, output: "disabled services = {}", error: "") }, signatureChild: child)
    let state = Mutex((scans: 0, events: 0, enriched: 0))
    let watcher = PersistenceWatcher(paths: [root.path], isRelevant: { $0.hasPrefix(root.path) }) { _ in
        let events = await scanner.scan(metadata: history, enrich: true).1
        state.withLock {
            $0.scans += 1; $0.events += events.count
            $0.enriched += events.filter { $0.details["signingIdentifier"] != nil || $0.details["quarantine"] != nil }.count
        }
    }
    watcher.start(pollInterval: nil)
    defer { watcher.stop() }
    while state.withLock({ $0.scans }) < 1 { try await Task.sleep(for: .milliseconds(50)) }
    try await Task.sleep(for: .seconds(1))
    var bursts = [[String: Any]]()
    for burst in 0..<3 {
        let before = state.withLock { $0 }
        let selfBefore = cpuSeconds(RUSAGE_SELF), childrenBefore = cpuSeconds(RUSAGE_CHILDREN)
        let start = ContinuousClock.now
        for index in 0..<40 {
            let path = agents.appendingPathComponent("burst\(burst)-\(index).plist")
            try PropertyListSerialization.data(fromPropertyList: ["Label": "burst\(burst).\(index)", "Program": programs[index % programs.count]], format: .xml, options: 0).write(to: path)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while state.withLock({ $0.events - before.events }) < 40 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let wall = start.duration(to: .now)
        let after = state.withLock { $0 }
        bursts.append(["burst": burst, "wall_s": Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18,
            "self_cpu_s": cpuSeconds(RUSAGE_SELF) - selfBefore, "children_cpu_s": cpuSeconds(RUSAGE_CHILDREN) - childrenBefore,
            "events": after.events - before.events, "enriched": after.enriched - before.enriched, "scans": after.scans - before.scans])
        try await Task.sleep(for: .seconds(3))
    }
    emit("production-watcher-burst", ["bursts": bursts, "plists_per_burst": 40, "enrichment_cap": 20])
}

/// Real dropped-event behavior: the main queue is blocked while another thread floods the stream.
/// The relevance filter rejects every path, so only a delivered drop flag can trigger recovery.
@MainActor @Test(.enabled(if: selected("dropped")))
func phase7RealDroppedEventRecovery() async throws {
    let environment = ProcessInfo.processInfo.environment
    let files = Int(environment["SMACK_PHASE7_DROP_FILES"] ?? "") ?? 100_000
    let blocked = Double(environment["SMACK_PHASE7_DROP_BLOCK_SECONDS"] ?? "") ?? 10
    // /Users/Shared is outside the home directory watched by the running app and outside the temporary tree.
    let parent = URL(fileURLWithPath: environment["SMACK_PHASE7_DROP_PARENT"] ?? "/Users/Shared")
    let root = parent.appendingPathComponent("smack-phase7-drop-" + UUID().uuidString)
    let watched = root.appendingPathComponent("watched")
    try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: root.appendingPathComponent(".metadata_never_index").path, contents: nil)
    defer { try? FileManager.default.removeItem(at: root) }
    let dbRoot = try phase7Directory()
    defer { try? FileManager.default.removeItem(at: dbRoot) }
    let history = try HistoryRepository(databaseURL: dbRoot.appendingPathComponent("history.sqlite"))
    let sentinel = watched.appendingPathComponent(".zshrc")
    let scanner = PersistenceScanner(files: [sentinel.path], directory: { _ in dbRoot.appendingPathComponent("absent").path },
                                     overrides: { _ in .init(status: 0, output: "disabled services = {}", error: "") })
    let state = Mutex((scans: 0, recovered: false))
    let watcher = PersistenceWatcher(paths: [watched.path], isRelevant: { _ in false }) { _ in
        let events = await scanner.scan(metadata: history, enrich: false).1
        state.withLock { $0.scans += 1; if events.contains(where: { $0.subject == sentinel.path && $0.details["change"] == "added" }) { $0.recovered = true } }
    }
    watcher.start(pollInterval: nil)
    defer { watcher.stop() }
    while state.withLock({ $0.scans }) < 1 { try await Task.sleep(for: .milliseconds(50)) }

    // A second raw stream on the same blocked queue records which drop flags were actually delivered.
    final class Seen: @unchecked Sendable { var batches = 0, events = 0, flags: UInt32 = 0 }
    let seen = Seen()
    var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(seen).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let observer = FSEventStreamCreate(nil, { _, info, count, _, flags, _ in
        let seen = Unmanaged<Seen>.fromOpaque(info!).takeUnretainedValue()
        seen.batches += 1; seen.events += count
        for index in 0..<count { seen.flags |= flags[index] }
    }, &context, [watched.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2,
        UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))!
    FSEventStreamSetDispatchQueue(observer, .main)
    FSEventStreamStart(observer)
    defer { FSEventStreamStop(observer); FSEventStreamInvalidate(observer); FSEventStreamRelease(observer) }
    try await Task.sleep(for: .seconds(1))

    let scansBefore = state.withLock { $0.scans }
    let generator = Thread {
        let manager = FileManager.default
        for directory in 0..<200 { try? manager.createDirectory(at: watched.appendingPathComponent("d\(directory)"), withIntermediateDirectories: false) }
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            let manager = FileManager()
            for index in stride(from: worker, to: files, by: 8) {
                manager.createFile(atPath: watched.appendingPathComponent("d\(index % 200)/f\(index)").path, contents: Data("x".utf8))
            }
        }
        manager.createFile(atPath: sentinel.path, contents: Data("added during the flood".utf8))
    }
    let started = ContinuousClock.now
    generator.start()
    // Block the main queue, where both streams deliver, while the flood is generated.
    blockCurrentThread(blocked) { generator.isFinished }
    let generated = started.duration(to: .now)
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    while ContinuousClock.now < deadline && !(state.withLock { $0.recovered }) { try await Task.sleep(for: .milliseconds(100)) }
    try await Task.sleep(for: .seconds(3))
    let flags = seen.flags
    emit("real-dropped-events", ["files": files, "main_blocked_s": blocked, "flood_and_block_wall_s": Double(generated.components.seconds),
        "observed_batches": seen.batches, "observed_events": seen.events,
        "must_scan_subdirs": flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0,
        "user_dropped": flags & UInt32(kFSEventStreamEventFlagUserDropped) != 0,
        "kernel_dropped": flags & UInt32(kFSEventStreamEventFlagKernelDropped) != 0,
        "rescans_after_flood": state.withLock { $0.scans } - scansBefore, "sentinel_recovered": state.withLock { $0.recovered }])
}
#endif
