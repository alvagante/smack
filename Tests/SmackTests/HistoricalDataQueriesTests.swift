import Foundation
import Testing
@testable import Smack

@MainActor
@Test func historicalDataQueriesReadRepositorySeries() async throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    try await history.save(system: obsSystem(at: 1_000))
    let queries = HistoricalDataQueries(history: history)

    let points = await queries.systemHistory(.cpu, from: Date(timeIntervalSince1970: 900), to: Date(timeIntervalSince1970: 1_100))

    #expect(points.count == 1)
    #expect(points.first?.timestamp == Date(timeIntervalSince1970: 1_000))
}
