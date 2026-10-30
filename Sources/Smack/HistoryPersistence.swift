import Foundation
import os

protocol HistoryWriting: Sendable {
    func save(system: SystemSample) async throws
    func save(processes: ProcessSnapshot) async throws
    func save(events: [ActivityEvent]) async throws
    func maintain(settings: CollectionSettings) async throws
}

extension HistoryRepository: HistoryWriting {}

/// Small key-value storage for state that must survive restarts, such as the startup item snapshot.
protocol ActivityMetadataStoring: Sendable {
    func metadata(_ key: String) async throws -> String?
    func setMetadata(_ key: String, value: String) async throws
}

extension HistoryRepository: ActivityMetadataStoring {}

enum HistoryOperation: String, CaseIterable, Sendable {
    case system = "System history"
    case processes = "Process history"
    case events = "Activity events"
    case maintenance = "History maintenance"
}

struct HistoryHealth: Equatable, Sendable {
    var revision: UInt64 = 0
    var failures: [HistoryOperation: String] = [:]

    var warning: String? {
        guard !failures.isEmpty else { return nil }
        let operations = HistoryOperation.allCases.filter { failures[$0] != nil }.map(\.rawValue)
        return operations.joined(separator: ", ") + " failed. Live monitoring continues; history may be incomplete. Retrying automatically."
    }

    var details: String {
        HistoryOperation.allCases.compactMap { operation in
            failures[operation].map { "\(operation.rawValue): \($0)" }
        }.joined(separator: "\n")
    }
}

/// Tracks each operation independently so a successful sample cannot hide failed maintenance.
actor HistoryPersistence {
    private let writer: any HistoryWriting
    private let onHealth: @Sendable (HistoryHealth) -> Void
    private let logger = Logger(subsystem: "it.lab42.smack", category: "history")
    private(set) var health = HistoryHealth()

    init(writer: any HistoryWriting, onHealth: @escaping @Sendable (HistoryHealth) -> Void = { _ in }) {
        self.writer = writer
        self.onHealth = onHealth
    }

    func save(system: SystemSample) async {
        do {
            try await writer.save(system: system)
            report(.system, error: nil)
        } catch { report(.system, error: error) }
    }

    func save(processes: ProcessSnapshot) async {
        do {
            try await writer.save(processes: processes)
            report(.processes, error: nil)
        } catch { report(.processes, error: error) }
    }

    /// Persistence is attempted first; callers still deliver the events to the UI when this fails, so the current
    /// session shows them and the health banner reports that history may be incomplete.
    func save(events: [ActivityEvent]) async {
        guard !events.isEmpty else { return }
        do {
            try await writer.save(events: events)
            report(.events, error: nil)
        } catch { report(.events, error: error) }
    }

    func maintain(settings: CollectionSettings) async {
        do {
            try await writer.maintain(settings: settings)
            report(.maintenance, error: nil)
        } catch { report(.maintenance, error: error) }
    }

    private func report(_ operation: HistoryOperation, error: Error?) {
        let message = error?.localizedDescription
        guard health.failures[operation] != message else { return }
        health.failures[operation] = message
        health.revision += 1
        if let message {
            logger.error("\(operation.rawValue, privacy: .public) failed: \(message, privacy: .private)")
        } else {
            logger.notice("\(operation.rawValue, privacy: .public) recovered")
        }
        onHealth(health)
    }
}
