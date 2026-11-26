import Foundation
import SQLite3

// JSON and CSV export.
extension HistoryRepository {
    func export(to url: URL, format: HistoryExportFormat, includeEvents: Bool = false) throws {
        var records: [HistoryExportRecord] = []
        for metric in SystemMetric.allCases {
            for point in try systemSeries(metric, from: .distantPast) {
                records.append(HistoryExportRecord(
                    kind: "system",
                    processID: nil,
                    processName: nil,
                    metric: metric.rawValue,
                    timestamp: point.timestamp.timeIntervalSince1970,
                    average: point.average,
                    peak: point.peak
                ))
            }
        }
        try appendProcessExportRecords(into: &records)
        records.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            if $0.processID != $1.processID { return ($0.processID ?? "") < ($1.processID ?? "") }
            return $0.metric < $1.metric
        }

        let exportedEvents = includeEvents
            ? try events(from: .distantPast, to: .distantFuture, kinds: nil, search: "", limit: CollectionSettings.maximumEventRowsRange.upperBound).reversed()
            : []

        let data: Data
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if includeEvents {
                data = try encoder.encode(HistoryExportDocument(metrics: records, events: exportedEvents.map(HistoryEventRecord.init)))
            } else {
                // Without events the export stays the plain array earlier versions wrote.
                data = try encoder.encode(records)
            }
        case .csv:
            data = Data(csv(records: records).utf8)
        }
        try data.write(to: url, options: .atomic)
        if includeEvents, format == .csv {
            let eventsURL = url.deletingLastPathComponent()
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-events.csv")
            try Data(csv(events: exportedEvents).utf8).write(to: eventsURL, options: .atomic)
        }
    }

    private func appendProcessExportRecords(into records: inout [HistoryExportRecord]) throws {
        try withStatement("""
            SELECT p.id, p.name, s.timestamp,
                s.cpu, s.memory, s.disk_read, s.disk_write, s.wakeups,
                s.cpu, s.memory, s.disk_read, s.disk_write, s.wakeups
            FROM process_samples s
            JOIN processes p ON p.key = s.process_key
            UNION ALL
            SELECT p.id, p.name, m.timestamp,
                m.cpu_total / m.sample_count, m.memory_total / m.sample_count, m.disk_read_total / m.sample_count, m.disk_write_total / m.sample_count, m.wakeups_total / m.sample_count,
                m.cpu_peak, m.memory_peak, m.disk_read_peak, m.disk_write_peak, m.wakeups_peak
            FROM process_minutes m
            JOIN processes p ON p.key = m.process_key
            """) { statement in
            let metrics = ProcessMetric.allCases
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return }
                guard code == SQLITE_ROW else { throw sqliteError(code: code) }
                let processID = stringColumn(statement, index: 0)
                let processName = stringColumn(statement, index: 1)
                let timestamp = sqlite3_column_double(statement, 2)
                for (offset, metric) in metrics.enumerated() {
                    records.append(HistoryExportRecord(
                        kind: "process",
                        processID: processID,
                        processName: processName,
                        metric: metric.rawValue,
                        timestamp: timestamp,
                        average: sqlite3_column_double(statement, Int32(3 + offset)),
                        peak: sqlite3_column_double(statement, Int32(8 + offset))
                    ))
                }
            }
        }
    }
}

private struct HistoryExportRecord: Codable {
    var kind: String
    var processID: String?
    var processName: String?
    var metric: String
    var timestamp: Double
    var average: Double
    var peak: Double
}

private struct HistoryEventRecord: Codable {
    var timestamp: Double
    var kind: String
    var severity: String
    var subject: String
    var processName: String?
    var processID: String?
    var details: [String: String]

    init(_ event: ActivityEvent) {
        timestamp = event.timestamp.timeIntervalSince1970
        kind = event.kind.rawValue
        severity = event.severity.rawValue
        subject = event.subject
        processName = event.processName
        processID = event.processID
        details = event.details
    }
}

private struct HistoryExportDocument: Codable {
    var metrics: [HistoryExportRecord]
    var events: [HistoryEventRecord]
}

private func csv(events: [ActivityEvent]) -> String {
    var output = "timestamp,kind,severity,subject,process_name,process_id,details\n"
    for event in events {
        let fields = [
            String(event.timestamp.timeIntervalSince1970),
            event.kind.rawValue,
            event.severity.rawValue,
            event.subject,
            event.processName ?? "",
            event.processID ?? "",
            event.detailSummary
        ]
        output += fields.map(csvField).joined(separator: ",") + "\n"
    }
    return output
}

private func csv(records: [HistoryExportRecord]) -> String {
    var output = "kind,process_id,process_name,metric,timestamp,average,peak\n"
    for record in records {
        let fields = [
            record.kind,
            record.processID ?? "",
            record.processName ?? "",
            record.metric,
            String(record.timestamp),
            String(record.average),
            String(record.peak)
        ]
        output += fields.map(csvField).joined(separator: ",") + "\n"
    }
    return output
}

private func csvField(_ value: String) -> String {
    // CSV quoting alone does not stop spreadsheet formula evaluation.
    let candidate = value.drop(while: { $0.isWhitespace })
    let formula = candidate.first.map { "=+-@".contains($0) } ?? false
    let controlPrefix = value.first.map { "\t\r\n".contains($0) } ?? false
    let value = formula || controlPrefix ? "'" + value : value
    guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
        return value
    }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}
