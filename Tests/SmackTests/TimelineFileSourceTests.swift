import Foundation
import Testing
@testable import Smack

@Test func fileLogCoverageUsesParsedEventTimes() {
    let content = "2026-11-01T10:00:00Z started\n2026-11-03T11:00:00Z stopped\n"
    let source = TimelineFileSources.parse(path: "/tmp/test.log", head: content, tail: "", sampled: false)
    #expect(source.events.count == 2)
    #expect(source.start == ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z"))
    #expect(source.end == ISO8601DateFormatter().date(from: "2026-11-03T11:00:00Z"))
    #expect(!source.sampled)
}

@Test func fileLogWithoutTimestampsHasUnavailableCoverage() {
    let source = TimelineFileSources.parse(path: "/tmp/test.log", head: "no timestamp", tail: "", sampled: false)
    #expect(source.start == nil)
    #expect(source.end == nil)
    #expect(source.events.isEmpty)
}

@Test func fileScanReadsBoundedEndsOfLargeFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("example.log")
    let text = "2020-01-01T00:00:00Z first\n" + String(repeating: "x", count: 200_000)
        + "\n2020-01-02T00:00:00Z last\n"
    try Data(text.utf8).write(to: file)
    let sources = TimelineFileSources.scan(custom: [], roots: [root], systemPaths: [])
    let source = try #require(sources.first)
    #expect(source.sampled)
    #expect(source.events.count == 2)
    #expect(source.start == ISO8601DateFormatter().date(from: "2020-01-01T00:00:00Z"))
    #expect(source.end == ISO8601DateFormatter().date(from: "2020-01-02T00:00:00Z"))
}

@Test func syslogYearIsInferredFromFileModificationDate() {
    let reference = ISO8601DateFormatter().date(from: "2026-01-02T12:00:00Z")!
    let source = TimelineFileSources.parse(path: "/tmp/system.log", head: "Dec 31 10:00:00 host service: done",
                                           tail: "", sampled: false, reference: reference)
    #expect(source.inferredYear)
    #expect(source.start != nil)
    #expect(Calendar.current.component(.year, from: source.start!) == 2025)
}

@MainActor
@Test func checkedFileEventsAppearInTimelineAndSourceFilter() async {
    let model = TimelineViewModel()
    let source = TimelineFileSources.parse(path: "/tmp/test.log", head: "2020-11-01T10:00:00Z started", tail: "", sampled: false)
    await model.scanFiles(bookmarks: []) { _ in [source] }
    model.select(range: .full)
    #expect(model.filtered.isEmpty)
    model.checkedFiles.insert(source.path)
    #expect(model.filtered.map(\.kind) == [.fileLog])
    model.sourceFilter = "Smack"
    #expect(model.filtered.isEmpty)
    model.sourceFilter = "File logs"
    #expect(model.filtered.count == 1)
}
