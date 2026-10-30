import Foundation
import SQLite3

// Activity events and the metadata table.
extension HistoryRepository {
    func save(events: [ActivityEvent]) throws {
        guard !events.isEmpty else { return }
        try transaction {
            try withStatement("""
                INSERT OR IGNORE INTO events (id, timestamp, kind, subject, process_id, process_name, severity, details)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """) { statement in
                for event in events {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bind(event.id, at: 1, to: statement)
                    bind(event.timestamp.timeIntervalSince1970, at: 2, to: statement)
                    bind(event.kind.rawValue, at: 3, to: statement)
                    bind(event.subject, at: 4, to: statement)
                    bind(event.processID, at: 5, to: statement)
                    bind(event.processName, at: 6, to: statement)
                    bind(event.severity.rawValue, at: 7, to: statement)
                    bind(ActivityEvent.encodeDetails(event.details), at: 8, to: statement)
                    try step(statement)
                }
            }
        }
    }

    /// Newest first. `search` matches the subject, process name and the raw details text, which includes detail keys;
    /// the Timeline refines it in memory against detail values only.
    func events(from start: Date, to end: Date, kinds: Set<ActivityEventKind>?, search: String, limit: Int) throws -> [ActivityEvent] {
        guard limit > 0 else { return [] }
        var clauses = ["timestamp >= ?", "timestamp <= ?"]
        let orderedKinds = kinds.map { $0.map(\.rawValue).sorted() }
        if let orderedKinds {
            guard !orderedKinds.isEmpty else { return [] }
            clauses.append("kind IN (\(Array(repeating: "?", count: orderedKinds.count).joined(separator: ", ")))")
        }
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            clauses.append("(subject LIKE ? ESCAPE '\\' OR process_name LIKE ? ESCAPE '\\' OR details LIKE ? ESCAPE '\\')")
        }
        let sql = "SELECT id, timestamp, kind, subject, process_id, process_name, severity, details FROM events WHERE "
            + clauses.joined(separator: " AND ") + " ORDER BY timestamp DESC, id LIMIT ?"
        return try withStatement(sql) { statement in
            var index: Int32 = 1
            func next() -> Int32 { defer { index += 1 }; return index }
            bind(max(start.timeIntervalSince1970, -1e12), at: next(), to: statement)
            bind(min(end.timeIntervalSince1970, 1e12), at: next(), to: statement)
            for kind in orderedKinds ?? [] { bind(kind, at: next(), to: statement) }
            if !term.isEmpty {
                let escaped = term
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                let pattern = "%\(escaped)%"
                for _ in 0..<3 { bind(pattern, at: next(), to: statement) }
            }
            sqlite3_bind_int64(statement, next(), Int64(limit))
            var result: [ActivityEvent] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return result }
                guard code == SQLITE_ROW else { throw sqliteError(code: code) }
                // Rows with a kind or severity this build does not know are skipped, not fatal.
                guard let kind = ActivityEventKind(rawValue: stringColumn(statement, index: 2)),
                      let severity = ActivityEventSeverity(rawValue: stringColumn(statement, index: 6)) else { continue }
                result.append(ActivityEvent(
                    id: stringColumn(statement, index: 0),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    kind: kind,
                    subject: stringColumn(statement, index: 3),
                    processID: optionalStringColumn(statement, index: 4),
                    processName: optionalStringColumn(statement, index: 5),
                    severity: severity,
                    details: ActivityEvent.decodeDetails(stringColumn(statement, index: 7))
                ))
            }
        }
    }

    func eventCount() throws -> Int {
        try integerQuery("SELECT COUNT(*) FROM events")
    }

    /// Deletes in batches so a large backlog never holds the write lock for long.
    func deleteEvents(before cutoff: Date) throws {
        let batch = Self.eventPruneBatch
        while true {
            var deleted = 0
            try transaction {
                try execute("DELETE FROM events WHERE id IN (SELECT id FROM events WHERE timestamp < \(cutoff.timeIntervalSince1970) LIMIT \(batch))")
                deleted = Int(sqlite3_changes(database))
            }
            if deleted < batch { return }
        }
    }

    /// Applies the retention window (clamped to the valid range), then keeps the newest `rowCap` rows.
    func pruneEvents(settings: CollectionSettings, now: Date = Date(), rowCap: Int = HistoryRepository.eventRowCap) throws {
        let range = CollectionSettings.eventRetentionRange
        let days = min(max(settings.eventRetentionDays, range.lowerBound), range.upperBound)
        try deleteEvents(before: now.addingTimeInterval(-TimeInterval(days) * 86_400))
        var excess = try eventCount() - max(0, rowCap)
        while excess > 0 {
            let batch = min(excess, Self.eventPruneBatch)
            try transaction {
                try execute("DELETE FROM events WHERE id IN (SELECT id FROM events ORDER BY timestamp, id LIMIT \(batch))")
            }
            excess -= batch
        }
    }

    func metadata(_ key: String) throws -> String? {
        try withStatement("SELECT value FROM metadata WHERE key = ?") { statement in
            bind(key, at: 1, to: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw sqliteError(code: result) }
            return stringColumn(statement, index: 0)
        }
    }

    func setMetadata(_ key: String, value: String) throws {
        try withStatement("INSERT INTO metadata (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value") { statement in
            bind(key, at: 1, to: statement)
            bind(value, at: 2, to: statement)
            try step(statement)
        }
    }
}
