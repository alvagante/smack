import Foundation
import Testing
@testable import Smack

@Test func sessionMetricFractionsHandleMissingAndOutOfRangeValues() {
    #expect(SessionMetricVisuals.fraction(25, total: 100) == 0.25)
    #expect(SessionMetricVisuals.fraction(200, total: 100) == 1)
    #expect(SessionMetricVisuals.fraction(-1, total: 100) == 0)
    #expect(SessionMetricVisuals.fraction(10, total: 0) == nil)
    #expect(SessionMetricVisuals.fraction(.infinity, total: 10) == nil)
}

@Test func sessionMetricSummaryUsesTranscriptTokensAndTime() {
    let start = Date(timeIntervalSince1970: 1_000)
    let index = TranscriptIndex(events: [
        TranscriptEvent(id: "a", kind: .prompt, start: start, title: "Prompt"),
        TranscriptEvent(id: "b", kind: .answer, start: start.addingTimeInterval(60), title: "Answer"),
    ], tokens: [TranscriptTokens(date: start, input: 80, output: 20)])
    let summary = SessionMetricSummary(index: index)
    #expect(summary.input == 80)
    #expect(summary.output == 20)
    #expect(summary.duration == 60)
    #expect(summary.activity.count == 24)
    #expect(summary.activity.first == 1)
    #expect(summary.activity.last == 1)
    let empty = SessionMetricSummary(index: TranscriptIndex())
    #expect(empty.input == nil)
    #expect(empty.duration == nil)
}
