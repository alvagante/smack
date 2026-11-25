import Foundation
import Testing
@testable import Smack
import SmackIPC

@Test func timelineParsesUnifiedLogRecordsWithTheirSourceAndFullMessage() throws {
    let text = #"{"timestamp":"2026-11-12 10:15:30.123456+0100","eventMessage":"Something failed\nwith details","messageType":"Error","process":"example","processID":42,"subsystem":"test.subsystem","category":"network"}"#
    let events = TimelineSources.parseLog(text)
    let event = try #require(events.first)
    #expect(event.kind == .systemLog)
    #expect(event.details["message"] == "Something failed\nwith details")
    #expect(event.details["subsystem"] == "test.subsystem")
    #expect(event.processName == "example")
    #expect(event.severity == .warning)
}

@Test func timelineLogArgumentsBoundTheRequestedWindow() {
    let window = DateInterval(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
    let arguments = TimelineSources.logArguments(window)
    #expect(arguments.contains("@100"))
    #expect(arguments.contains("@200"))
    #expect(arguments.contains("ndjson"))
    // The app and the Privileged Helper run the same query.
    #expect(arguments == UnifiedLogQuery.arguments(start: 100, end: 200))
}

@Test func unifiedLogWindowKeepsTheMostRecentPartWithinTheLimit() {
    let end = Date(timeIntervalSince1970: 100_000)
    let wide = DateInterval(start: end.addingTimeInterval(-48 * 3_600), end: end)
    let limited = TimelineSources.limitLogWindow(wide, hours: 6)
    #expect(limited.window == DateInterval(start: end.addingTimeInterval(-6 * 3_600), end: end))
    #expect(limited.message?.contains("6 hours") == true)
    let narrow = DateInterval(start: end.addingTimeInterval(-3_600), end: end)
    #expect(TimelineSources.limitLogWindow(narrow, hours: 6).window == narrow)
    #expect(TimelineSources.limitLogWindow(narrow, hours: 6).message == nil)
}

@Test func privilegedHelperRejectsInvalidOrTooWideLogRanges() {
    let now = 10_000_000.0
    let ceiling = UnifiedLogQuery.maximumRange
    #expect(UnifiedLogQuery.rejection(start: now - ceiling, end: now, now: now) == nil)
    #expect(UnifiedLogQuery.rejection(start: now - ceiling - 1, end: now, now: now) != nil)
    #expect(UnifiedLogQuery.rejection(start: 0, end: now, now: now) != nil)
    #expect(UnifiedLogQuery.rejection(start: now, end: now - 1, now: now) != nil)
    #expect(UnifiedLogQuery.rejection(start: now, end: now + 3_600, now: now) != nil)
    #expect(UnifiedLogQuery.rejection(start: .nan, end: now, now: now) != nil)
}

@MainActor @Test func timelineLoadLimitsTheUnifiedLogWindow() async {
    let model = TimelineViewModel()
    let end = Date()
    model.open(window: DateInterval(start: end.addingTimeInterval(-48 * 3_600), end: end))
    model.includeLogs = true
    model.useHelper = true
    var requested: DateInterval?
    await model.load(limit: 500, logRangeHours: 6, privilegedLogs: { window in
        requested = window
        return TimelineSources.Result()
    }) { _, _, _ in [] }
    #expect(abs((requested?.duration ?? 0) - 6 * 3_600) < 0.001)
    #expect(requested?.end == end)
    #expect(model.sourceMessage?.contains("6 hours") == true)
}
