import Foundation
import SQLite3
import Testing
@testable import Smack

@Test func eventsInsertIgnoreDuplicatesAndQueryNewestFirst() async throws {
    let directory = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("h.sqlite"))
    let events = [
        obsEvent(.processStarted, at: 100, subject: "alpha"),
        obsEvent(.listenerOpened, at: 200, subject: "TCP :80", processName: "nginx"),
        obsEvent(.systemWake, at: 300, subject: "wake"),
    ]
    try await repository.save(events: events)
    try await repository.save(events: events)
    #expect(try await repository.eventCount() == 3)

    let all = try await repository.events(from: .distantPast, to: .distantFuture, kinds: nil, search: "", limit: 10)
    #expect(all.map(\.subject) == ["wake", "TCP :80", "alpha"])
    #expect(try await repository.events(from: .distantPast, to: .distantFuture, kinds: [.listenerOpened], search: "", limit: 10).count == 1)
    #expect(try await repository.events(from: .distantPast, to: .distantFuture, kinds: [], search: "", limit: 10).isEmpty)
    #expect(try await repository.events(from: .distantPast, to: .distantFuture, kinds: nil, search: "nginx", limit: 10).count == 1)
    #expect(try await repository.events(from: .distantPast, to: .distantFuture, kinds: nil, search: "%", limit: 10).isEmpty)
    #expect(try await repository.events(from: Date(timeIntervalSince1970: 150), to: Date(timeIntervalSince1970: 250), kinds: nil, search: "", limit: 10).count == 1)
    #expect(try await repository.events(from: .distantPast, to: .distantFuture, kinds: nil, search: "", limit: 2).count == 2)
}

@Test func pruningAppliesRetentionAndRowCap() async throws {
    let directory = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("h.sqlite"))
    let now = Date(timeIntervalSince1970: 10_000_000)
    var events = [obsEvent(.processStarted, at: now.timeIntervalSince1970 - 9 * 86_400, subject: "old")]
    for index in 0..<10 { events.append(obsEvent(.processStarted, at: now.timeIntervalSince1970 - Double(index), subject: "n\(index)")) }
    try await repository.save(events: events)
    var settings = CollectionSettings()
    settings.eventRetentionDays = 7
    try await repository.pruneEvents(settings: settings, now: now, rowCap: 100)
    #expect(try await repository.eventCount() == 10)
    try await repository.pruneEvents(settings: settings, now: now, rowCap: 4)
    let remaining = try await repository.events(from: .distantPast, to: .distantFuture, kinds: nil, search: "", limit: 10)
    #expect(remaining.map(\.subject) == ["n0", "n1", "n2", "n3"])
}

@Test func metadataRoundTrips() async throws {
    let directory = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("h.sqlite"))
    #expect(try await repository.metadata("k") == nil)
    try await repository.setMetadata("k", value: "v1")
    try await repository.setMetadata("k", value: "v2")
    #expect(try await repository.metadata("k") == "v2")
}

@Test func freshDatabaseIsVersionFourWithEventsTable() async throws {
    let directory = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("h.sqlite")
    _ = try HistoryRepository(databaseURL: url)
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(sqlite3_column_int(statement, 0) == 4)
    sqlite3_finalize(statement)
    #expect(sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('events', 'metadata')", -1, &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(sqlite3_column_int(statement, 0) == 2)
    sqlite3_finalize(statement)
}

@Test func reopeningAV4DatabaseIsIdempotent() async throws {
    let directory = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("h.sqlite")
    let first = try HistoryRepository(databaseURL: url)
    try await first.save(events: [obsEvent(at: 5)])
    let second = try HistoryRepository(databaseURL: url)
    #expect(try await second.eventCount() == 1)
}

@Test func gpuPressureSwapAndWakeupsAreStoredAndReadBack() async throws {
    let directory = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("h.sqlite"))
    let time = Date(timeIntervalSince1970: 1_760_000_000)
    var sample = obsSystem(at: 1_760_000_000, pressure: .warning)
    sample.gpu = GPUSample(utilizationPercent: 42, rendererUtilizationPercent: 30, tilerUtilizationPercent: 10, inUseMemoryBytes: 1_024)
    sample.memory.swapTotalBytes = 4_096
    sample.memory.swapUsedBytes = 2_048
    try await repository.save(system: sample)
    #expect(try await repository.systemSeries(.gpuUtilization, from: time.addingTimeInterval(-1)).first?.average == 42)
    #expect(try await repository.systemSeries(.memoryPressure, from: time.addingTimeInterval(-1)).first?.average == 1)
    #expect(try await repository.systemSeries(.swapUsedBytes, from: time.addingTimeInterval(-1)).first?.average == 2_048)

    let busy = obsProcess(9, name: "busy", cpu: 1, wakeups: 25)
    try await repository.save(processes: obsSnapshot([busy], at: 1_760_000_000))
    let series = try await repository.processSeries(processID: busy.id, metric: .wakeups, from: time.addingTimeInterval(-1))
    #expect(series.first?.average == 25)
}

@Test func wakeupsKeepAnOtherwiseIdleProcessInHistory() async throws {
    let directory = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("h.sqlite"))
    let quiet = obsProcess(9, name: "quiet", cpu: 0, wakeups: 0)
    let waking = obsProcess(9, name: "quiet", cpu: 0, wakeups: 12)
    for (offset, process) in [quiet, quiet, quiet, waking].enumerated() {
        try await repository.save(processes: obsSnapshot([process], at: 1_760_000_000 + Double(offset) * 2))
    }
    let series = try await repository.processSeries(processID: quiet.id, metric: .wakeups, from: .distantPast)
    #expect(series.contains { $0.average == 12 })
}

@Test func exportAddsEventsOnlyWhenAsked() async throws {
    let directory = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("h.sqlite"))
    try await repository.save(system: obsSystem(at: 1_760_000_000))
    try await repository.save(events: [obsEvent(.processStarted, at: 1_760_000_001, subject: "=cmd()")])

    let plain = directory.appendingPathComponent("plain.json")
    try await repository.export(to: plain, format: .json)
    #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: plain)) is [Any])

    let withEvents = directory.appendingPathComponent("events.json")
    try await repository.export(to: withEvents, format: .json, includeEvents: true)
    let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: withEvents)) as? [String: Any])
    #expect((document["events"] as? [Any])?.count == 1)
    #expect(document["metrics"] != nil)

    let csv = directory.appendingPathComponent("metrics.csv")
    try await repository.export(to: csv, format: .csv, includeEvents: true)
    let eventsCSV = try String(contentsOf: directory.appendingPathComponent("metrics-events.csv"), encoding: .utf8)
    #expect(eventsCSV.hasPrefix("timestamp,kind,severity,subject,process_name,process_id,details\n"))
    #expect(eventsCSV.contains("'=cmd()"))
}

@Test func peakReadsTheLargestStoredValue() async throws {
    let directory = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("h.sqlite"))
    #expect(try await repository.peak(.cpu, from: .distantPast) == nil)
    try await repository.save(system: obsSystem(at: 1_760_000_000, cpu: 20))
    try await repository.save(system: obsSystem(at: 1_760_000_002, cpu: 70))
    #expect(try await repository.peak(.cpu, from: .distantPast) == 70)
}
