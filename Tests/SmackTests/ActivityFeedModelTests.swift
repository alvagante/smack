import Foundation
import Testing
@testable import Smack

private struct FixedEvents: ActivityEventQuerying {
    var stored: [ActivityEvent] = []
    var fails = false
    struct Failure: Error {}

    func events(from start: Date, to end: Date, kinds: Set<ActivityEventKind>?, search: String, limit: Int) async throws -> [ActivityEvent] {
        if fails { throw Failure() }
        return stored
    }

    func peak(_ metric: SystemMetric, from start: Date) async throws -> Double? {
        if fails { throw Failure() }
        return nil
    }
}

@MainActor
private func feed(_ events: FixedEvents) -> ActivityFeedModel {
    ActivityFeedModel(events: events, metadata: MemoryMetadata(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
}

@MainActor
@Test func activityFeedReturnsOnlyFreshEventsNewestFirst() {
    let model = feed(FixedEvents())
    let old = ActivityEvent.make(kind: .systemSleep, timestamp: Date(timeIntervalSince1970: 100), subject: "old", severity: .info)
    let new = ActivityEvent.make(kind: .systemWake, timestamp: Date(timeIntervalSince1970: 200), subject: "new", severity: .info)
    #expect(model.receive([old]).map(\.id) == [old.id])
    #expect(model.receive([old, new]).map(\.id) == [new.id])
    #expect(model.receive([old]).isEmpty)
    #expect(model.recentEvents.map(\.id) == [new.id, old.id])
}

@MainActor
@Test func activityFeedMergesUnsavedSessionEventsIntoStoredOnes() async throws {
    let now = Date()
    let stored = ActivityEvent.make(kind: .systemSleep, timestamp: now.addingTimeInterval(-20), subject: "stored", severity: .info)
    let pending = ActivityEvent.make(kind: .systemWake, timestamp: now.addingTimeInterval(-10), subject: "pending", severity: .info)
    let outside = ActivityEvent.make(kind: .systemWake, timestamp: now.addingTimeInterval(-3_600), subject: "outside", severity: .info)
    let model = feed(FixedEvents(stored: [stored]))
    model.receive([stored, pending, outside])
    let events = try await model.loadEvents(from: now.addingTimeInterval(-60), to: now, kinds: nil, search: "", limit: 10)
    #expect(events.map(\.id) == [pending.id, stored.id])
}

@MainActor
@Test func activityFeedReportsUnavailableDiffWhenHistoryFails() async {
    let model = feed(FixedEvents(fails: true))
    await model.refreshActivityDiff(current: { nil })
    #expect(model.activityDiff == nil)
    #expect(model.activityDiffUnavailable)
    #expect(await model.events(from: .distantPast, to: .distantFuture, kinds: nil, search: "", limit: 10).isEmpty)
}
