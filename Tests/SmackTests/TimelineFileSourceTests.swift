import Foundation
import Synchronization
import Testing
@testable import Smack

/// An in-memory tree of log files that records every read.
final class MemoryLogFiles: LogFileAccess, Sendable {
    struct State: Sendable {
        var files: [String: (data: Data, modified: Date)] = [:]
        var folders: Set<String> = []
        var unreadable: Set<String> = []
        var reads: [(path: String, offset: UInt64, length: Int)] = []
    }
    let state = Mutex(State())

    func set(_ path: String, _ data: Data, modified: Date = Date(timeIntervalSince1970: 0)) {
        state.withLock { $0.files[path] = (data, modified) }
    }
    func folder(_ path: String) { _ = state.withLock { $0.folders.insert(path) } }
    func deny(_ path: String) { _ = state.withLock { $0.unreadable.insert(path) } }
    var reads: [(path: String, offset: UInt64, length: Int)] { state.withLock { $0.reads } }

    func size(of path: String) -> UInt64? {
        state.withLock { state in state.unreadable.contains(path) ? nil : state.files[path].map { UInt64($0.data.count) } }
    }

    func read(_ path: String, offset: UInt64, length: Int) -> Data? {
        state.withLock { state in
            guard length > 0, !state.unreadable.contains(path), let data = state.files[path]?.data,
                  offset < UInt64(data.count) else { return nil }
            state.reads.append((path, offset, length))
            return data.subdata(in: Int(offset)..<min(Int(offset) + length, data.count))
        }
    }

    func exists(_ path: String) -> Bool { state.withLock { $0.files[path] != nil || $0.folders.contains(path) } }
    func isReadable(_ path: String) -> Bool { state.withLock { !$0.unreadable.contains(path) } }
    func modified(_ path: String) -> Date? { state.withLock { $0.files[path]?.modified } }
    func resolveBookmark(_ data: Data) -> URL? { URL(fileURLWithPath: String(decoding: data, as: UTF8.self)) }
    func withAccess<T>(to url: URL, scoped: Bool, _ body: () -> T) -> T { body() }

    func walk(_ root: URL, levels: Int, visit: (_ url: URL, _ isFile: Bool) -> Bool) -> Bool {
        let (readable, entries) = state.withLock { state -> (Bool, [(String, Bool)]) in
            let prefix = root.path + "/"
            let entries = (state.files.keys.map { ($0, true) } + state.folders.map { ($0, false) })
                .filter { $0.0.hasPrefix(prefix) && $0.0.dropFirst(prefix.count).split(separator: "/").count <= levels }
                .sorted { $0.0 < $1.0 }
            return (state.folders.contains(root.path) && !state.unreadable.contains(root.path), entries)
        }
        guard readable else { return false }
        for (path, isFile) in entries where !visit(URL(fileURLWithPath: path), isFile) { break }
        return true
    }
}

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
    let files = MemoryLogFiles()
    files.folder("/logs")
    let text = "2020-01-01T00:00:00Z first\n" + String(repeating: "x", count: 200_000)
        + "\n2020-01-02T00:00:00Z last\n"
    files.set("/logs/example.log", Data(text.utf8))
    files.set("/logs/notes.txt", Data("2020-01-01T00:00:00Z ignored".utf8))
    let sources = TimelineFileSources.scan(custom: [], roots: [URL(fileURLWithPath: "/logs")], systemPaths: [], files: files)
    let source = try #require(sources.first)
    #expect(sources.count == 1)
    #expect(source.sampled)
    #expect(source.events.count == 2)
    #expect(source.start == ISO8601DateFormatter().date(from: "2020-01-01T00:00:00Z"))
    #expect(source.end == ISO8601DateFormatter().date(from: "2020-01-02T00:00:00Z"))
    let size = UInt64(text.utf8.count), sample = TimelineFileSources.sampleBytes
    #expect(files.reads.map(\.offset) == [0, size - UInt64(sample)])
    #expect(files.reads.allSatisfy { $0.length == sample })
}

@Test func fileScanMarksUnreadableRootsAndFilesUnavailable() {
    let files = MemoryLogFiles()
    files.folder("/denied")
    files.deny("/denied")
    files.set("/var/system.log", Data("x".utf8))
    files.deny("/var/system.log")
    files.set("/var/empty.log", Data())
    let sources = TimelineFileSources.scan(custom: [], roots: [URL(fileURLWithPath: "/denied")],
                                           systemPaths: ["/var/system.log", "/var/empty.log", "/var/missing.log"], files: files)
    #expect(sources.map(\.path) == ["/denied", "/var/system.log", "/var/empty.log"])
    #expect(sources.map(\.error) == ["Unavailable", "Unavailable", nil])
}

@Test func fileScanStopsAfterFiveThousandEntries() {
    let files = MemoryLogFiles()
    files.folder("/logs")
    for index in 0..<6_000 { files.folder(String(format: "/logs/%05d", index)) }
    files.set("/logs/zzz.log", Data("2020-01-01T00:00:00Z late".utf8))
    let sources = TimelineFileSources.scan(custom: [], roots: [URL(fileURLWithPath: "/logs")], systemPaths: [], files: files)
    #expect(sources.isEmpty)
    #expect(files.reads.isEmpty)
}

@Test func syslogYearIsInferredFromFileModificationDate() {
    let reference = ISO8601DateFormatter().date(from: "2026-01-02T12:00:00Z")!
    let source = TimelineFileSources.parse(path: "/tmp/system.log", head: "Dec 31 10:00:00 host service: done",
                                           tail: "", sampled: false, reference: reference)
    #expect(source.inferredYear)
    #expect(source.start != nil)
    #expect(Calendar.current.component(.year, from: source.start!) == 2025)
}

@Test func diagnosticReportsInWindowBecomeEvents() {
    let files = MemoryLogFiles()
    let inside = Date(timeIntervalSince1970: 1_000), outside = Date(timeIntervalSince1970: 10)
    files.folder("/reports")
    files.set("/reports/App.ips", Data("{}".utf8), modified: inside)
    files.set("/reports/Old.crash", Data("{}".utf8), modified: outside)
    files.set("/reports/readme.txt", Data("{}".utf8), modified: inside)
    files.folder("/denied")
    files.deny("/denied")
    let result = TimelineSources.reports(in: DateInterval(start: Date(timeIntervalSince1970: 500), duration: 1_000),
                                         folders: [URL(fileURLWithPath: "/reports"), URL(fileURLWithPath: "/denied")], files: files)
    #expect(result.events.map(\.subject) == ["App.ips"])
    #expect(result.events.first?.kind == .diagnosticReport)
    #expect(result.message != nil)
    #expect(files.reads.isEmpty)
}

@Test func unifiedLogQueryIsBoundedAndReportsTimeouts() async {
    let calls = Mutex<[(String, [String])]>([])
    let window = DateInterval(start: Date(timeIntervalSince1970: 100), duration: 50)
    let result = await TimelineSources.logs(in: window) { executable, arguments in
        calls.withLock { $0.append((executable, arguments)) }
        return .init(status: 0, output: "", error: "", timedOut: true)
    }
    #expect(calls.withLock { $0.map(\.0) } == ["/usr/bin/log"])
    #expect(calls.withLock { $0.first?.1 } == TimelineSources.logArguments(window))
    #expect(result.message == "Unified log query timed out; narrow the range.")
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
