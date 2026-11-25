import Foundation

@MainActor
final class HistoricalDataQueries {
    private let history: HistoryRepository
    var onError: ((String) -> Void)?

    init(history: HistoryRepository) {
        self.history = history
    }

    func systemHistory(_ metric: SystemMetric, hours: Double = 1) async -> [HistoricalPoint] {
        await systemHistory(metric, from: Date().addingTimeInterval(-hours * 3600))
    }

    func systemHistory(_ metric: SystemMetric, from start: Date, to end: Date = .distantFuture) async -> [HistoricalPoint] {
        await query([]) { try await history.systemSeries(metric, from: start, to: end) }
    }

    /// Every metric for one instance (`processID`), or summed over all instances of `program`.
    func processHistory(program: String, processID: String?, hours: Double, limit: Int) async -> [ProcessMetric: [HistoricalPoint]] {
        await processHistory(program: program, processID: processID, from: Date().addingTimeInterval(-hours * 3600), limit: limit)
    }

    func processHistory(program: String, processID: String?, from start: Date, to end: Date = .distantFuture, limit: Int) async -> [ProcessMetric: [HistoricalPoint]] {
        await query([:]) { try await history.processHistory(program: program, processID: processID, from: start, to: end, limit: limit) }
    }

    func historicalPrograms(hours: Double) async -> [HistoricalProgram] {
        await query([]) { try await history.programs(from: Date().addingTimeInterval(-hours * 3600)) }
    }

    func historicalPrograms(from start: Date, to end: Date) async -> [HistoricalProgram] {
        await query([]) { try await history.programs(from: start, to: end) }
    }

    func eventCounts(from start: Date, to end: Date) async -> [ActivityEventKind: Int] {
        (try? await history.eventCounts(from: start, to: end)) ?? [:]
    }

    func controlSeries(
        _ metric: SystemMetric,
        from start: Date,
        to end: Date,
        resolution: TimeInterval,
        limit: Int
    ) async throws -> [HistoricalPoint] {
        try await history.controlSeries(metric, from: start, to: end, resolution: resolution, limit: limit)
    }

    func deleteAll() async throws {
        try await history.deleteAll()
    }

    func lastCompacted() async throws -> Date? {
        try await history.lastCompacted()
    }

    func storageUsage() async throws -> StorageUsage {
        try await history.storageUsage()
    }

    func compactNow() async throws -> Date {
        try await history.compactNow()
    }

    func export(to url: URL, format: HistoryExportFormat, includeEvents: Bool) async throws {
        try await history.export(to: url, format: format, includeEvents: includeEvents)
    }

    func historicalInstances(of program: String, hours: Double) async -> [HistoricalProcess] {
        await query([]) { try await history.instances(named: program, from: Date().addingTimeInterval(-hours * 3600)) }
    }

    private func query<T>(_ fallback: T, _ body: @MainActor () async throws -> T) async -> T {
        do {
            return try await body()
        } catch {
            onError?("History could not be read: \(error.localizedDescription)")
            return fallback
        }
    }
}
