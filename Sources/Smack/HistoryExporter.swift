import Foundation

struct HistoryExportRecord: Codable {
    var kind: String
    var processID: String?
    var processName: String?
    var metric: String
    var timestamp: Double
    var average: Double
    var peak: Double
}

enum HistoryExporter {
    static func sorted(_ records: [HistoryExportRecord]) -> [HistoryExportRecord] {
        guard records.count > 1, !isAlreadySorted(records) else { return records }
        return records.sorted(by: isBefore)
    }

    private static func isAlreadySorted(_ records: [HistoryExportRecord]) -> Bool {
        for index in 1..<records.count where isBefore(records[index], records[index - 1]) {
            return false
        }
        return true
    }

    private static func isBefore(_ lhs: HistoryExportRecord, _ rhs: HistoryExportRecord) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if lhs.processID != rhs.processID { return (lhs.processID ?? "") < (rhs.processID ?? "") }
        return lhs.metric < rhs.metric
    }

    static func write(_ records: [HistoryExportRecord], to url: URL, format: HistoryExportFormat) throws {
        let data: Data
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(records)
        case .csv:
            data = Data(csv(records: records).utf8)
        }
        try data.write(to: url, options: .atomic)
    }

    static func csv(records: [HistoryExportRecord]) -> String {
        let header = "kind,process_id,process_name,metric,timestamp,average,peak\n"
        var output = String()
        output.reserveCapacity(header.utf8.count + records.count * 72)
        output += header
        for record in records {
            appendCSVField(record.kind, to: &output)
            output.append(",")
            appendCSVField(record.processID ?? "", to: &output)
            output.append(",")
            appendCSVField(record.processName ?? "", to: &output)
            output.append(",")
            appendCSVField(record.metric, to: &output)
            output.append(",")
            output.append(String(record.timestamp))
            output.append(",")
            output.append(String(record.average))
            output.append(",")
            output.append(String(record.peak))
            output.append("\n")
        }
        return output
    }

    static func csvField(_ value: String) -> String {
        guard needsCSVQuoting(value) else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func needsCSVQuoting(_ value: String) -> Bool {
        for byte in value.utf8 {
            if byte == 0x2C || byte == 0x22 || byte == 0x0A || byte == 0x0D {
                return true
            }
        }
        return false
    }

    private static func appendCSVField(_ value: String, to output: inout String) {
        guard needsCSVQuoting(value) else {
            output.append(value)
            return
        }
        output.append("\"")
        output.append(value.replacingOccurrences(of: "\"", with: "\"\""))
        output.append("\"")
    }
}
