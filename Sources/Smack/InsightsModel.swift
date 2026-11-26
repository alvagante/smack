import Foundation

/// State for the Insights page and the Summary digest. Everything is read on demand from the history actor;
/// nothing loads while the panel is hidden, and the digest is reused for `InsightsDigest.cacheLifetime`.
@MainActor
final class InsightsModel: ObservableObject {
    @Published var range = InsightsRange.day
    @Published private(set) var ledger: DiskWriteLedger?
    @Published private(set) var churn: [ProcessChurnRow] = []
    @Published private(set) var destinations: DestinationReport?
    @Published private(set) var digest: InsightsDigest?
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?

    private let history: HistoryRepository
    private var digestLoadedAt: Date?
    private var digestSources: InsightsSources?

    init(history: HistoryRepository) {
        self.history = history
    }

    /// Destinations come from connection events, which only the direct build records.
    static var supportsDestinations: Bool { Capabilities.supportsNetworkPortInspection }

    /// Results are published together and only if the range is unchanged, so a slow 7-day read finishing after
    /// a switch back to 24 hours cannot overwrite the newer page.
    func load(now: Date = Date()) async {
        loading = true
        defer { loading = false }
        let range = range
        let window = range.window(endingAt: now)
        do {
            let ledger = try await Self.ledger(history: history, window: window, bucket: range.bucket)
            let churn = ProcessChurn.classify(try await history.processChurn(from: window.start, to: window.end), hours: range.rawValue)
            // Retention defaults to seven days, so "new" is only meaningful over the last day.
            let destinations = Self.supportsDestinations
                ? try await Self.destinations(history: history, window: InsightsRange.day.window(endingAt: now)) : nil
            guard !Task.isCancelled, range == self.range else { return }
            self.ledger = ledger
            self.churn = churn
            self.destinations = destinations
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "History could not be read: \(error.localizedDescription)"
        }
    }

    /// Reuses the digest for `cacheLifetime` unless the recordings feeding it changed. Without connection events
    /// the destination read is skipped, since nothing new can appear.
    func refreshDigestIfStale(sources: InsightsSources, now: Date = Date()) async {
        if let digestLoadedAt, digestSources == sources, now.timeIntervalSince(digestLoadedAt) < InsightsDigest.cacheLifetime, digest != nil { return }
        digestLoadedAt = now
        digestSources = sources
        let window = DateInterval(start: now.addingTimeInterval(-InsightsDigest.window), end: now)
        do {
            async let cpu = history.peak(.cpu, from: window.start)
            async let pressure = history.peak(.memoryPressure, from: window.start)
            async let programs = history.programs(from: window.start, to: window.end)
            async let counts = history.eventCounts(from: window.start, to: window.end)
            async let churn = history.processChurn(from: window.start, to: window.end)
            let ledger = try await Self.ledger(history: history, window: window, bucket: InsightsRange.day.bucket)
            let destinations = sources.connectionEvents ? try await Self.destinations(history: history, window: window) : nil
            digest = InsightsDigest.make(
                window: window, peakCPU: try await cpu, peakPressure: try await pressure, programs: try await programs,
                ledger: ledger, eventCounts: try await counts, destinations: destinations,
                churn: ProcessChurn.classify(try await churn, hours: InsightsDigest.window / 3_600)
            )
        } catch {
            digestLoadedAt = nil
            digest = nil
        }
    }

    private static func ledger(history: HistoryRepository, window: DateInterval, bucket: TimeInterval) async throws -> DiskWriteLedger {
        let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: window.end))
        let cells = try await history.diskWriteCells(from: window.start, to: window.end, bucket: bucket, utcOffset: offset)
        let system = try await history.systemBytesWritten(from: window.start, to: window.end)
        return DiskWriteLedger.make(cells: cells, window: window, bucket: bucket, utcOffset: offset, systemTotal: system)
    }

    private static func destinations(history: HistoryRepository, window: DateInterval) async throws -> DestinationReport {
        let raw = try await history.connectionEndpoints()
        return DestinationReport.make(endpoints: raw.endpoints, coverageStart: raw.coverageStart, window: window)
    }
}
