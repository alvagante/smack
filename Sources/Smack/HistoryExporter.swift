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

    static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
