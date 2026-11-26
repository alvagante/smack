import Foundation
import SmackIPC

enum CLIOutputFormat: String {
    case table, json, csv, tsv

    var lineEnding: String { self == .csv ? "\r\n" : "\n" }
    private var separator: String { self == .csv ? "," : "\t" }

    // Fixed per-operation columns keep empty results and follow heartbeats schema-stable.
    private func fields(op: String) -> [String] {
        let names: String
        switch op {
        case "status": names = "timestamp flavor appVersion appUptimeSeconds systemUptimeSeconds cpuPercent memoryUsedBytes memoryTotalBytes pressure swapUsedBytes thermal batteryPercent onBattery startupDiskFreeBytes helper alertsPausedUntil notificationAuthorization"
        case "ps": names = "pid cpuPercent memoryBytes timestamp startTime user bundleIdentifier diskReadRate diskWriteRate wakeupsPerSecond"
        case "agents": names = "agentID pid startTime project directory parentSession cpuPercent memoryBytes mcpServers listeners remoteHosts log session"
        case "apps": names = "cpuPercent memoryBytes bundleIdentifier"
        case "devservers", "who": names = "pid startTime process directory root kind branch commit ports containerID container composeProject composeWorkingDirectory"
        case "ports": names = "port pid address scope protocol timestamp clientCount clients"
        case "events": names = "kind timestamp severity"
        case "history": names = "timestamp average peak resolutionSeconds"
        case "startup": names = "timestamp category enabled path program includedCategories includesBackgroundTasks"
        case "alerts": names = "enabled evaluationEnabled state lastFired deliverySnoozedUntil pausedUntil"
        case "posture": names = "status area reason timestamp"
        default: names = ""
        }
        return names.split(separator: " ").map(String.init).sorted()
    }

    func header(op: String) -> String? {
        switch self {
        case .json: return nil
        case .table: return "ID\tNAME\tFIELDS"
        case .csv, .tsv: return (["id", "title"] + fields(op: op)).map(quoted).joined(separator: separator)
        }
    }

    func row(_ record: ControlRecord, op: String) throws -> String {
        switch self {
        case .json:
            return String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        case .csv, .tsv:
            return ([record.id, record.title] + fields(op: op).map { record.fields[$0] ?? "" })
                .map(quoted).joined(separator: separator)
        case .table:
            let values = try record.fields.keys.sorted().map { key in
                key + "=" + (try Self.escaped(record.fields[key]!))
            }.joined(separator: " ")
            return "\(try Self.escaped(record.id))\t\(try Self.escaped(record.title))\t\(values)"
        }
    }

    static func escaped(_ text: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = String(decoding: try encoder.encode(text), as: UTF8.self)
        return encoded.dropFirst().dropLast().unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? String(format: "\\u%04x", scalar.value) : String(scalar)
        }.joined()
    }

    static func terminalMarkdown(_ text: String) throws -> String {
        try text.components(separatedBy: "\n").map { line in
            try line.components(separatedBy: "\t").map(escaped).joined(separator: "\t")
        }.joined(separator: "\n")
    }

    private func quoted(_ value: String) -> String {
        guard value.contains(separator) || value.contains("\"") || value.contains("\r") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
