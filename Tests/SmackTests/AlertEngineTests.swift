import Foundation
import Testing
@testable import Smack

private func cpuRule(sustain: Double = 20, clear: Double? = nil) -> AlertRule {
    AlertRule(name: "CPU", enabled: true, kind: .systemThreshold(metric: .cpuTotal, comparison: .greaterThan,
                                                                value: 90, sustain: sustain, clear: clear))
}

@Test(arguments: [1.0, 5.0, 10.0]) func alertSustainUsesSampleTime(interval: Double) async {
    let engine = AlertEngine()
    await engine.update(rules: [cpuRule(sustain: 120)])
    for time in stride(from: 1000.0, to: 1120, by: interval) {
        #expect(await engine.evaluate(system: obsSystem(at: time, cpu: 95), expectedInterval: interval).isEmpty)
    }
    #expect(await engine.evaluate(system: obsSystem(at: 1120, cpu: 95), expectedInterval: interval).count == 1)
    #expect(await engine.evaluate(system: obsSystem(at: 1120 + interval, cpu: 95), expectedInterval: interval).isEmpty)
}

@Test func alertResetsClearsAndRearms() async {
    let engine = AlertEngine()
    await engine.update(rules: [cpuRule(sustain: 10, clear: 5)])
    for (time, cpu, count) in [(1000.0, 95.0, 0), (1005, 50, 0), (1010, 95, 0), (1015, 95, 0),
                               (1020, 95, 1), (1025, 50, 0), (1030, 50, 0), (1035, 95, 0), (1040, 95, 0), (1045, 95, 1)] {
        #expect(await engine.evaluate(system: obsSystem(at: time, cpu: cpu), expectedInterval: 5).count == count)
    }
}

@Test func alertGapUnavailableAndEditsResetSustain() async {
    let engine = AlertEngine()
    var rule = cpuRule(sustain: 10)
    await engine.update(rules: [rule])
    _ = await engine.evaluate(system: obsSystem(at: 1000, cpu: 95), expectedInterval: 5)
    #expect(await engine.evaluate(system: obsSystem(at: 1020, cpu: 95), expectedInterval: 5).isEmpty)
    rule.name = "Changed"
    await engine.update(rules: [rule])
    #expect(await engine.evaluate(system: obsSystem(at: 1025, cpu: 95), expectedInterval: 5).isEmpty)
    await engine.noteGap(at: Date())
    #expect(await engine.evaluate(system: obsSystem(at: 1030, cpu: 95), expectedInterval: 5).isEmpty)
    rule.kind = .systemThreshold(metric: .gpuUtilization, comparison: .greaterThan, value: 10, sustain: 0, clear: nil)
    await engine.update(rules: [rule])
    #expect(await engine.evaluate(system: obsSystem(at: 1035), expectedInterval: 5).isEmpty)
    #expect(await engine.runtime[rule.id]?.state == "Metric unavailable")
}

@Test func zeroSustainNeedsTwoDistinctSamples() async {
    let engine = AlertEngine()
    await engine.update(rules: [cpuRule(sustain: 0)])
    #expect(await engine.evaluate(system: obsSystem(at: 1000, cpu: 95), expectedInterval: 5).isEmpty)
    #expect(await engine.evaluate(system: obsSystem(at: 1005, cpu: 95), expectedInterval: 5).count == 1)
}

@Test func processIdentityReuseCapAndDisappearance() async {
    let engine = AlertEngine()
    let rule = AlertRule(name: "Process", enabled: true, kind: .processThreshold(metric: .cpu,
        matcher: ProcessMatcher(anyProcess: true), comparison: .greaterThan, value: 80, sustain: 5, clear: 0))
    await engine.update(rules: [rule])
    let processes = (1...600).map { obsProcess(Int32($0), cpu: Double($0) + 100) }
    #expect(await engine.evaluate(processes: obsSnapshot(processes), expectedInterval: 5).isEmpty)
    #expect(await engine.evaluate(processes: obsSnapshot(processes, at: 1005), expectedInterval: 5).count == 500)
    #expect(await engine.evaluate(processes: obsSnapshot([obsProcess(600, start: 2, cpu: 100)], at: 1010), expectedInterval: 5).isEmpty)
    #expect(await engine.evaluate(processes: obsSnapshot([obsProcess(600, start: 2, cpu: 100)], at: 1015), expectedInterval: 5).count == 1)
    _ = await engine.evaluate(processes: obsSnapshot([], at: 1020), expectedInterval: 5)
    #expect(await engine.runtime[rule.id]?.state == "No matching process now")
}

@Test func eventPredicatesSeverityAndGrouping() async {
    let engine = AlertEngine()
    let rule = AlertRule(name: "External", enabled: true, kind: .event(kinds: [.listenerOpened], minimumSeverity: .notice,
        predicates: [.init(field: "scope", op: .equals, value: "external")]))
    await engine.update(rules: [rule])
    var events = (1...5).map { i in
        ActivityEvent.make(kind: .listenerOpened, timestamp: Date(timeIntervalSince1970: 1000), subject: "port \(i)", severity: .notice, details: ["scope": "external"])
    }
    var local = events[0]; local.details["scope"] = "loopback"; events.append(local)
    var quiet = events[0]; quiet.severity = .info; events.append(quiet)
    let fired = await engine.evaluate(events: events)
    #expect(fired.count == 1)
    #expect(fired.first?.count == 5)
    #expect(fired.first?.subjects.count == 3)
    #expect(fired.first?.body.contains("+2 more") == true)
    #expect(!EventPredicate(field: "missing", op: .notEquals, value: "x").matches(local))
}

@Test func unchangedRulesKeepSustain() async {
    let engine = AlertEngine(); let rule = cpuRule(sustain: 5)
    await engine.update(rules: [rule])
    _ = await engine.evaluate(system: obsSystem(at: 1000, cpu: 95), expectedInterval: 5)
    await engine.update(rules: [rule])
    #expect(await engine.evaluate(system: obsSystem(at: 1005, cpu: 95), expectedInterval: 5).count == 1)
}

actor RecordingAlertNotifier: UserNotifying {
    var status: AlertAuthorization
    var notifications: [AlertNotification] = []
    var requests = 0
    init(_ status: AlertAuthorization = .authorized) { self.status = status }
    func authorizationStatus() -> AlertAuthorization { status }
    func requestAuthorization() -> Bool { requests += 1; status = .authorized; return true }
    func post(_ notification: AlertNotification) { notifications.append(notification) }
}

@MainActor @Test func disablingAlertsCancelsQueuedDeliveryAndAuthorization() async {
    let notifier = RecordingAlertNotifier(.notDetermined)
    let dispatcher = AlertDispatcher(notifier: notifier)
    let rule = AlertRule(name: "Event", enabled: true, kind: .event(kinds: [.volumeMounted], minimumSeverity: .info, predicates: []))
    dispatcher.enabled = false
    await dispatcher.prepare(rules: [rule])
    await dispatcher.test(rule)
    #expect(await notifier.requests == 0)
    #expect(await notifier.notifications.isEmpty)
    dispatcher.enabled = true
    await dispatcher.prepare(rules: [rule])
    #expect(await notifier.requests == 1)
    let now = Date()
    dispatcher.noteWake(at: now)
    _ = await dispatcher.dispatch(FiredAlert(rule: rule, timestamp: now, subjects: ["fixture"]))
    dispatcher.enabled = false
    await dispatcher.flush(at: now.addingTimeInterval(31))
    dispatcher.enabled = true
    await dispatcher.flush(at: now.addingTimeInterval(32))
    #expect(await notifier.notifications.isEmpty)
}

@Test func alertMasterSwitchStopsEvaluationWithoutStartingCollectorsOrEditingRules() async throws {
    let directory = try obsTemporaryDirectory()
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    var settings = CollectionSettings()
    settings.postureCheckInterval = nil; settings.recordSystemEvents = false
    let scheduler = CollectionScheduler(systemCollector: SystemCollector(),
        processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: PrivilegedSamplingClient()),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(),
        history: repository, settings: settings,
        onSystem: { _ in Issue.record("Feature settings must not start system collection") },
        onProcesses: { _ in Issue.record("Feature settings must not start process collection") })
    let rule = AlertRule(name: "Mount", enabled: true, kind: .event(kinds: [.volumeMounted], minimumSeverity: .info, predicates: []))
    await scheduler.update(rules: [rule])
    settings.alertsEnabled = false
    await scheduler.updateFeatureSettings(settings)
    await scheduler.recordVolumeMounted(path: "/disabled", name: "Disabled")
    #expect(try await repository.events(from: .distantPast, to: .distantFuture, kinds: [.alertFired], search: "", limit: 10).isEmpty)
    settings.alertsEnabled = true
    await scheduler.updateFeatureSettings(settings)
    await scheduler.recordVolumeMounted(path: "/enabled", name: "Enabled")
    #expect(try await repository.events(from: .distantPast, to: .distantFuture, kinds: [.alertFired], search: "", limit: 10).count == 1)
    await scheduler.stop()
}

@MainActor @Test func dispatcherSuppressionAndAuthorization() async {
    let notifier = RecordingAlertNotifier()
    let dispatcher = AlertDispatcher(notifier: notifier)
    var rule = cpuRule()
    await dispatcher.prepare(rules: [rule])
    func alert(_ time: Double) -> FiredAlert { FiredAlert(rule: rule, timestamp: Date(timeIntervalSince1970: time), subjects: ["CPU"]) }
    #expect(await dispatcher.dispatch(alert(1000)).details["suppressed"] == nil)
    #expect(await dispatcher.dispatch(alert(1001)).details["suppressed"] == "cooldown")
    dispatcher.pausedUntil = Date(timeIntervalSince1970: 3000)
    #expect(await dispatcher.dispatch(alert(1002)).details["suppressed"] == "paused")
    dispatcher.pausedUntil = nil
    rule.snoozedUntil = Date(timeIntervalSince1970: 3000)
    #expect(await dispatcher.dispatch(alert(1003)).details["suppressed"] == "snoozed")
    rule.snoozedUntil = nil
    rule.cooldown = 0
    dispatcher.isTargetVisible = { _ in true }
    #expect(await dispatcher.dispatch(alert(1004)).details["suppressed"] == "visible")
    #expect(await notifier.notifications.count == 1)
    let denied = RecordingAlertNotifier(.denied)
    let deniedDispatcher = AlertDispatcher(notifier: denied)
    await deniedDispatcher.prepare(rules: [rule])
    #expect(await deniedDispatcher.dispatch(alert(1005)).details["suppressed"] == "authorization")
    #expect(await denied.notifications.isEmpty)
    let fresh = RecordingAlertNotifier(.notDetermined)
    let freshDispatcher = AlertDispatcher(notifier: fresh)
    var disabled = rule; disabled.enabled = false
    await freshDispatcher.prepare(rules: [disabled])
    #expect(await fresh.requests == 0)
    await freshDispatcher.prepare(rules: [rule])
    await freshDispatcher.prepare(rules: [rule])
    #expect(await fresh.requests == 1)
}

@MainActor @Test func dispatcherRateLimitAndSummary() async {
    let notifier = RecordingAlertNotifier()
    let dispatcher = AlertDispatcher(notifier: notifier)
    var rule = cpuRule(); rule.cooldown = 0
    await dispatcher.prepare(rules: [rule])
    for i in 0..<14 {
        let event = await dispatcher.dispatch(FiredAlert(rule: rule, timestamp: Date(timeIntervalSince1970: 1000 + Double(i)), subjects: ["CPU"]))
        #expect(event.details["suppressed"] == (i < 10 ? nil : "rateLimit"))
    }
    #expect(await notifier.notifications.count == 10)
    await dispatcher.flush(at: Date(timeIntervalSince1970: 1600))
    #expect(await notifier.notifications.last?.title == "4 more alerts")
    await dispatcher.flush(at: Date(timeIntervalSince1970: 1601))
    #expect(await notifier.notifications.count == 11)
}

@MainActor @Test func dispatcherWakeCoalescingAndTestDelivery() async {
    let notifier = RecordingAlertNotifier()
    let dispatcher = AlertDispatcher(notifier: notifier)
    let rule = AlertRule(name: "CPU", enabled: true, kind: .event(kinds: [.listenerOpened], minimumSeverity: .info, predicates: []))
    await dispatcher.prepare(rules: [rule])
    dispatcher.noteWake(at: Date(timeIntervalSince1970: 1000))
    for i in 1...5 {
        #expect(await dispatcher.dispatch(FiredAlert(rule: rule, timestamp: Date(timeIntervalSince1970: 1000 + Double(i)), subjects: ["subject \(i)"])).details["suppressed"] == "wakeCoalesced")
    }
    #expect(await notifier.notifications.isEmpty)
    await dispatcher.flush(at: Date(timeIntervalSince1970: 1030))
    #expect(await notifier.notifications.count == 1)
    #expect(await notifier.notifications.first?.title == "Since wake: CPU")
    #expect(await notifier.notifications.first?.body.contains("+2 more") == true)
    await dispatcher.test(rule)
    #expect(await notifier.notifications.count == 2)
}

@Test func schedulerEvaluatesEventsBeforePersistenceFiltersWithoutStartingLoops() async throws {
    let directory = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    var settings = CollectionSettings()
    settings.recordSystemEvents = false
    let client = PrivilegedSamplingClient()
    let scheduler = CollectionScheduler(
        systemCollector: SystemCollector(),
        processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: client),
        inventoryCollector: InventoryCollector(privileged: client),
        networkPortCollector: NetworkPortCollector(privileged: client), history: repository, settings: settings,
        onSystem: { _ in Issue.record("Rule updates must not start system collection") },
        onProcesses: { _ in Issue.record("Rule updates must not start process collection") })
    let rule = AlertRule(name: "Mount", enabled: true, kind: .event(kinds: [.volumeMounted], minimumSeverity: .info, predicates: []))
    await scheduler.update(rules: [rule])
    await scheduler.recordVolumeMounted(path: "/test", name: "Test")
    let events = try await repository.events(from: .distantPast, to: .distantFuture, kinds: nil, search: "", limit: 20)
    #expect(events.count == 1)
    #expect(events.first?.kind == .alertFired)
    await scheduler.update(rules: [])
    await scheduler.recordVolumeMounted(path: "/other", name: "Other")
    #expect(try await repository.events(from: .distantPast, to: .distantFuture, kinds: nil, search: "", limit: 20).count == 1)
}

@Test func batteryAlertRequiresBatteryPowerAndMetricMappingsAreExplicit() {
    var sample = obsSystem()
    sample.battery = BatterySample(chargePercent: 10, isCharging: false, isPresent: true,
                                   timeRemaining: nil, health: nil, cycleCount: nil, isOnBattery: false)
    #expect(sample.value(for: .batteryChargeOnBattery) == nil)
    sample.battery?.isOnBattery = true
    #expect(sample.value(for: .batteryChargeOnBattery) == 10)
    #expect(sample.value(for: .memoryUsedRatio) == 0.5)
    #expect(sample.value(for: .memoryPressure) == 0)
    #expect(sample.value(for: .gpuUtilization) == nil)
    sample.volumes = [.init(name: "root", mountPath: "/", totalBytes: 100, availableBytes: 10)]
    #expect(sample.value(for: .startupDiskFreeRatio) == 0.1)
}

@Test func cadenceChangeResetsSustainEvenWithoutLargeGap() async {
    let engine = AlertEngine()
    await engine.update(rules: [cpuRule(sustain: 10)])
    _ = await engine.evaluate(system: obsSystem(at: 1000, cpu: 95), expectedInterval: 5)
    #expect(await engine.evaluate(system: obsSystem(at: 1010, cpu: 95), expectedInterval: 10).isEmpty)
    #expect(await engine.evaluate(system: obsSystem(at: 1020, cpu: 95), expectedInterval: 10).count == 1)
}

@MainActor @Test func rateSummarySurvivesPauseAtWindowEnd() async {
    let notifier = RecordingAlertNotifier()
    let dispatcher = AlertDispatcher(notifier: notifier)
    var rule = cpuRule(); rule.cooldown = 0
    await dispatcher.prepare(rules: [rule])
    for i in 0..<11 {
        _ = await dispatcher.dispatch(FiredAlert(rule: rule, timestamp: Date(timeIntervalSince1970: 1000 + Double(i)), subjects: ["CPU"]))
    }
    dispatcher.pausedUntil = .distantFuture
    await dispatcher.flush(at: Date(timeIntervalSince1970: 1600))
    #expect(await notifier.notifications.count == 10)
    dispatcher.pausedUntil = nil
    await dispatcher.flush(at: Date(timeIntervalSince1970: 1601))
    #expect(await notifier.notifications.last?.title == "1 more alerts")
}

@Test func baselineCPUSampleIsUnavailableToRules() async {
    let rule = AlertRule(name: "low cpu", enabled: true, kind: .systemThreshold(metric: .cpuTotal,
        comparison: .lessThan, value: 5, sustain: 0, clear: nil))
    let engine = AlertEngine()
    await engine.update(rules: [rule])
    var baseline = obsSystem(at: 1_000, cpu: 0)
    baseline.cpu.hasUsage = false
    #expect(await engine.evaluate(system: baseline, expectedInterval: 1).isEmpty)
    #expect(await engine.runtime[rule.id]?.state == "Metric unavailable")
    // The placeholder must not start the sustain window: a real sample is the first of two.
    #expect(await engine.evaluate(system: obsSystem(at: 1_001, cpu: 1), expectedInterval: 1).isEmpty)
    #expect(await engine.evaluate(system: obsSystem(at: 1_002, cpu: 1), expectedInterval: 1).count == 1)
}

/// Characterization of the system-rule path: firing, clearing, sustain text, unavailable metrics (no
/// interfaces, disks, GPU or thermal reading, no volume), a disabled rule, a rule edit that keeps
/// unchanged tracks, a sample gap and a cadence change. Any change in the log is a behavior change.
@Test func systemEvaluationCharacterization() async {
    func system(_ metric: SystemAlertMetric, _ comparison: Comparison, _ value: Double, sustain: TimeInterval,
                clear: TimeInterval?, name: String, enabled: Bool = true) -> AlertRule {
        AlertRule(name: name, enabled: enabled, kind: .systemThreshold(metric: metric, comparison: comparison,
            value: value, sustain: sustain, clear: clear))
    }
    let rules = [
        system(.cpuTotal, .greaterThan, 50, sustain: 3, clear: 2, name: "cpu"),
        system(.cpuTotal, .greaterThanOrEqual, 80, sustain: 0, clear: nil, name: "cpu zero sustain"),
        system(.cpuTotal, .greaterThan, 0, sustain: 4000, clear: nil, name: "long sustain"),
        system(.memoryPressure, .greaterThanOrEqual, 1, sustain: 2, clear: nil, name: "pressure"),
        system(.volumeFreeRatio, .lessThan, 0.2, sustain: 2, clear: 1, name: "volume"),
        system(.startupDiskFreeRatio, .lessThan, 0.3, sustain: 1, clear: 1, name: "startup"),
        system(.networkReceiveRate, .greaterThan, 1000, sustain: 1, clear: nil, name: "network"),
        system(.thermalState, .greaterThanOrEqual, 2, sustain: 1, clear: 1, name: "thermal"),
        system(.diskWriteRate, .greaterThan, 5, sustain: 2, clear: nil, name: "disk"),
        system(.gpuUtilization, .greaterThan, 60, sustain: 1, clear: nil, name: "gpu"),
        system(.cpuTotal, .greaterThan, 0, sustain: 0, clear: nil, name: "disabled", enabled: false)
    ]
    let engine = AlertEngine()
    await engine.update(rules: rules)
    var log: [String] = []
    for step in 0..<90 {
        let time = 1_000 + Double(step) + (step >= 50 ? 60 : 0)
        var sample = obsSystem(at: time,
            pressure: [.normal, .warning, .critical, .unavailable][(step / 7) % 4],
            thermal: [.nominal, .fair, .serious, .critical, .unavailable][(step / 5) % 5],
            interfaces: step % 11 < 3 ? [] : [InterfaceSample(name: "en0", bytesReceived: 0, bytesSent: 0,
                receiveRate: Double((step * 311) % 2500), sendRate: 0)],
            cpu: Double((step * 17) % 100))
        sample.disks = step % 13 < 2 ? [] : [DiskSample(name: "disk0", bytesRead: 0, bytesWritten: 0, readRate: 0, writeRate: Double((step * 3) % 11))]
        sample.volumes = step % 17 < 2 ? [] : [
            VolumeSample(name: "Macintosh HD", mountPath: "/", totalBytes: 1_000, availableBytes: UInt64(100 + (step * 37) % 500)),
            VolumeSample(name: "Data", mountPath: "/Volumes/Data", totalBytes: 2_000, availableBytes: UInt64(100 + (step * 53) % 1_200))]
        sample.gpu.utilizationPercent = step % 9 == 0 ? nil : Double((step * 29) % 100)
        if step == 30 { await engine.update(rules: Array(rules.dropFirst(2)) + [rules[0]]) }
        if step == 60 { await engine.update(rules: rules) }
        let fired = await engine.evaluate(system: sample, expectedInterval: step < 70 ? 1 : 2)
        log += fired.map { "\(step) \($0.rule.name) \($0.subjects.joined()) \($0.details["identity"] ?? "") \($0.details["value"] ?? "")" }
        let runtime = await engine.runtime
        log.append("\(step): " + rules.map { "\(runtime[$0.id]?.state ?? "-")" }.joined(separator: "|"))
    }
    let runtime = await engine.runtime
    log += rules.map { "\($0.name): \(runtime[$0.id]?.state ?? "-") \(runtime[$0.id]?.lastFired?.timeIntervalSince1970 ?? 0)" }
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in log.joined(separator: "\n").utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    // Recorded from the engine before the allocation-free runtime phase and volume loop; identical after.
    #expect(log.count == 137)
    #expect(hash == 7_272_896_085_814_175_147)
}

/// Characterization of fired alerts and runtime states over a varied workload: firing, clearing,
/// process exits and restarts, a sample gap, an unavailable metric and a disabled rule.
@Test func processEvaluationCharacterization() async {
    func rule(_ name: String, _ kind: AlertRule.Kind, enabled: Bool = true) -> AlertRule {
        AlertRule(name: name, enabled: enabled, kind: kind)
    }
    let rules = [
        rule("any cpu", .processThreshold(metric: .cpu, matcher: ProcessMatcher(anyProcess: true),
            comparison: .greaterThan, value: 70, sustain: 2, clear: 2)),
        rule("any cpu clone", .processThreshold(metric: .cpu, matcher: ProcessMatcher(anyProcess: true),
            comparison: .greaterThanOrEqual, value: 85, sustain: 0, clear: nil)),
        rule("named", .processThreshold(metric: .cpu, matcher: ProcessMatcher(name: "P7"),
            comparison: .greaterThan, value: 40, sustain: 2, clear: 1)),
        rule("low wakeups", .processThreshold(metric: .wakeupsPerSecond, matcher: ProcessMatcher(anyProcess: true),
            comparison: .lessThan, value: 5, sustain: 4, clear: 1)),
        rule("network", .processThreshold(metric: .networkSendRate, matcher: ProcessMatcher(anyProcess: true),
            comparison: .greaterThan, value: 0, sustain: 1, clear: nil)),
        rule("disabled", .processThreshold(metric: .cpu, matcher: ProcessMatcher(anyProcess: true),
            comparison: .greaterThan, value: 0, sustain: 0, clear: nil), enabled: false),
        rule("nothing", .processThreshold(metric: .cpu, matcher: ProcessMatcher(name: "absent"),
            comparison: .greaterThan, value: 0, sustain: 0, clear: nil))
    ]
    let engine = AlertEngine()
    await engine.update(rules: rules)
    var log: [String] = []
    for step in 0..<60 {
        let time = 1_000 + Double(step) + (step >= 40 ? 30 : 0)
        let processes = (1...120).compactMap { pid -> ProcessMetrics? in
            if pid % 9 == step % 9 { return nil }
            let restarted = pid % 11 == 0 && step >= 25
            return obsProcess(Int32(pid), start: restarted ? 2 : 1, cpu: Double((pid * 7 + step * 13) % 100),
                              wakeups: Double((pid + step) % 12))
        }
        let snapshot = obsSnapshot(Array(processes.dropFirst(5)), at: time, apps: Array(processes.prefix(5)))
        let fired = await engine.evaluate(processes: snapshot, expectedInterval: 1, networkAvailable: step % 7 != 0)
        log += fired.map { "\(step) \($0.rule.name) \($0.subjects.joined()) \($0.details["identity"] ?? "") \($0.details["value"] ?? "")" }
    }
    let runtime = await engine.runtime
    log += rules.map { "\($0.name): \(runtime[$0.id]?.state ?? "-") \(runtime[$0.id]?.lastFired?.timeIntervalSince1970 ?? 0)" }
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in log.joined(separator: "\n").utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    // Recorded from the engine before the idle-track optimization; any change here is a behavior change.
    #expect(log.count == 491)
    #expect(hash == 16_698_215_640_196_081_790)
}
