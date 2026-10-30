import AppKit
import Foundation
import SmackIPC
import Testing
@testable import Smack

// MARK: Timeline view model

@MainActor
@Test func timelineGroupsByMinuteNewestFirst() {
    let events = [
        obsEvent(at: 3_660, subject: "c"), obsEvent(at: 3_630, subject: "b"), obsEvent(at: 3_610, subject: "a"),
    ]
    let groups = TimelineViewModel.groups(of: events)
    #expect(groups.count == 2)
    #expect(groups[0].events.map(\.subject) == ["c"])
    #expect(groups[1].events.map(\.subject) == ["b", "a"])
    #expect(groups.flatMap(\.events).map(\.subject) == ["c", "b", "a"])
    #expect(groups[0].minute.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0)
}

@MainActor
@Test func kindFiltersAndSearchRunInMemory() async {
    let model = TimelineViewModel()
    let events = [
        obsEvent(.processStarted, at: 100, subject: "alpha"),
        obsEvent(.listenerOpened, at: 101, subject: "TCP :80", processName: "nginx"),
        obsEvent(.systemWake, at: 102, subject: "wake"),
    ]
    await model.load { _, _, _ in events }
    #expect(model.filtered.count == 3)
    model.toggle(.listenerOpened)
    #expect(model.filtered.map(\.subject) == ["TCP :80"])
    model.selectedKinds = []
    model.toggle(group: .system)
    #expect(model.isSelected(group: .system))
    #expect(model.filtered.map(\.subject) == ["wake"])
    model.toggle(group: .system)
    #expect(model.selectedKinds.isEmpty)
    model.query = "nginx"
    #expect(model.filtered.count == 1)
}

@MainActor
@Test func visibleEventsAreCappedAt500() async {
    let model = TimelineViewModel()
    let events = (0..<650).map { obsEvent(at: 10_000 - Double($0), subject: "e\($0)") }
    await model.load { _, _, _ in events }
    #expect(model.visibleEvents.count == TimelineViewModel.visibleLimit)
    #expect(model.isCapped)
}

@MainActor
@Test func customWindowOverridesTheRangeUntilARangeIsChosen() {
    let model = TimelineViewModel()
    let window = DateInterval(start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 2_000))
    model.open(window: window)
    #expect(model.window() == window)
    #expect(model.requestID.hasPrefix("custom"))
    model.select(range: .hours6)
    #expect(model.customWindow == nil)
    #expect(model.requestID == "6h")
    let now = Date(timeIntervalSince1970: 100_000)
    #expect(model.window(now: now).duration == TimelineRange.hours6.interval)
}

@MainActor
@Test func loadFailureIsReportedAndRecovers() async {
    struct Failure: Error {}
    let model = TimelineViewModel()
    await model.load { _, _, _ in throw Failure() }
    #expect(model.loadFailed)
    #expect(model.loaded.isEmpty)
    await model.load { _, _, _ in [obsEvent(at: 1)] }
    #expect(!model.loadFailed)
    #expect(model.loaded.count == 1)
}

// MARK: Wakeups

@Test func wakeupRatesNeedTwoSamplesAndNeverSpikeOnReset() {
    let builder = ProcessSnapshotBuilder()
    func record(_ interrupt: UInt64?, idle: UInt64?, pid: Int32 = 5, start: Double = 1) -> ProcessRecord {
        ProcessRecord(
            pid: pid, parentPID: 1, startTime: Date(timeIntervalSince1970: start), userID: 0, name: "w", executablePath: nil,
            cpuTimeNanoseconds: 0, physicalFootprint: 0, bytesRead: 0, bytesWritten: 0, energyNanojoules: nil, threadCount: 1,
            interruptWakeups: interrupt, packageIdleWakeups: idle
        )
    }
    func first(_ snapshot: ProcessSnapshot) -> ProcessMetrics? {
        (snapshot.applications.flatMap(\.processes) + snapshot.backgroundProcesses).first
    }
    let t0 = Date(timeIntervalSince1970: 1_000)
    #expect(first(builder.build(records: [record(100, idle: 50)], timestamp: t0))?.wakeupsPerSecond == 0)
    let second = first(builder.build(records: [record(120, idle: 70)], timestamp: t0.addingTimeInterval(2)))
    #expect(second?.interruptWakeupsPerSecond == 10)
    #expect(second?.packageIdleWakeupsPerSecond == 10)
    // Counter reset.
    let reset = first(builder.build(records: [record(5, idle: 3)], timestamp: t0.addingTimeInterval(4)))
    #expect(reset?.wakeupsPerSecond == 0)
    // Unavailable counters.
    let missing = first(builder.build(records: [record(nil, idle: nil)], timestamp: t0.addingTimeInterval(6)))
    #expect(missing?.wakeupsPerSecond == 0)
    // Zero elapsed time.
    let same = first(builder.build(records: [record(50, idle: 50)], timestamp: t0.addingTimeInterval(6)))
    #expect(same?.wakeupsPerSecond == 0)
    // New process with the same PID is a new identity.
    let reused = first(builder.build(records: [record(1_000, idle: 1_000, start: 99)], timestamp: t0.addingTimeInterval(8)))
    #expect(reused?.wakeupsPerSecond == 0)
}

@Test func wakeupRecordsDecodeFromAnOlderHelperPayload() throws {
    let record = ProcessRecord(
        pid: 1, parentPID: 0, startTime: Date(timeIntervalSince1970: 1), userID: 0, name: "x", executablePath: nil,
        cpuTimeNanoseconds: 0, physicalFootprint: 0, bytesRead: 0, bytesWritten: 0, energyNanojoules: nil, threadCount: 1
    )
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    object.removeValue(forKey: "interruptWakeups")
    object.removeValue(forKey: "packageIdleWakeups")
    let decoded = try JSONDecoder().decode(ProcessRecord.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.interruptWakeups == nil)
}

// MARK: Formatting and system information

@Test func wakeupAndPressureFormatting() {
    // The decimal separator follows the locale.
    let tenth = 12.4.formatted(.number.precision(.fractionLength(1)))
    #expect(Formatting.wakeups(12.44) == "\(tenth)/s")
    #expect(Formatting.wakeups(-3) == "\(0.0.formatted(.number.precision(.fractionLength(1))))/s")
    #expect(Formatting.pressure(.unavailable) == "Unavailable")
    #expect(Formatting.pressure(.critical) == "Critical")
    #expect(Formatting.pressure(historyValue: 0.4) == "Normal")
    #expect(Formatting.pressure(historyValue: 1.2) == "Warning")
    #expect(Formatting.pressure(historyValue: 1.9) == "Critical")
}

@Test func unavailableGPUAndPressureNeverReadAsZero() {
    let sample = obsSystem(pressure: .unavailable)
    let sections = SystemInformation.advancedSections(gpuName: "GPU", volumes: [], system: sample)
    let rows = sections.flatMap(\.rows)
    #expect(rows.first { $0.key == "GPU Utilization" }?.value == "Unavailable")
    #expect(rows.first { $0.key == "Memory Pressure" }?.value == "Unavailable")
}

// MARK: Observers

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}

@MainActor
@Test func observersForwardNotificationsAndStopAfterRemoval() async throws {
    let box = EventBox()
    let center = NotificationCenter()
    let observers = ActivitySystemObservers(
        handlers: .init(
            volumeMounted: { path, name in box.add("mount:\(path):\(name)") },
            volumeUnmounted: { path in box.add("unmount:\(path)") },
            sleep: { box.add("sleep") },
            wake: { box.add("wake") },
            powerSource: { charging, _ in box.add("power:\(charging)") }
        ),
        notificationCenter: center,
        readPowerState: { nil }
    )
    observers.install()
    center.post(name: NSWorkspace.willSleepNotification, object: nil)
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    center.post(name: NSWorkspace.didMountNotification, object: nil, userInfo: [
        NSWorkspace.volumeURLUserInfoKey: URL(fileURLWithPath: "/Volumes/USB"),
        NSWorkspace.localizedVolumeNameUserInfoKey: "USB",
    ])
    center.post(name: NSWorkspace.didUnmountNotification, object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: URL(fileURLWithPath: "/Volumes/USB")])
    for _ in 0..<50 where box.all.count < 4 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(Set(box.all) == ["sleep", "wake", "mount:/Volumes/USB:USB", "unmount:/Volumes/USB"])

    observers.remove()
    center.post(name: NSWorkspace.willSleepNotification, object: nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(box.all.count == 4)
}

@MainActor
@Test func onlyAPowerSourceChangeIsReported() {
    var state = ActivitySystemObservers.PowerState(onExternalPower: true, chargePercent: 50)
    let reported = EventBox()
    let observers = ActivitySystemObservers(
        handlers: .init(volumeMounted: { _, _ in }, volumeUnmounted: { _ in }, sleep: {}, wake: {}, powerSource: { charging, _ in reported.add(String(charging)) }),
        notificationCenter: NotificationCenter(),
        readPowerState: { state }
    )
    observers.install()
    defer { observers.remove() }
    observers.powerSourceChanged()
    state.chargePercent = 51
    observers.powerSourceChanged()
    #expect(reported.all.isEmpty)
    state.onExternalPower = false
    observers.powerSourceChanged()
    #expect(reported.all == ["false"])
}

// MARK: Settings

@Test func activitySettingsClampAndDefault() throws {
    var settings = CollectionSettings()
    #expect(settings.eventRetentionDays == 7)
    #expect(!settings.recordConnectionEvents)
    #expect(settings.showEventsOnCharts)
    settings.eventRetentionDays = 999
    settings.validate()
    #expect(settings.eventRetentionDays == 30)
    settings.eventRetentionDays = 0
    settings.validate()
    #expect(settings.eventRetentionDays == 1)
    let legacy = try JSONDecoder().decode(CollectionSettings.self, from: Data("{}".utf8))
    #expect(legacy.eventRetentionDays == 7)
}
