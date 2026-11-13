import Foundation

enum TimelineSources {
    struct Result: Sendable {
        var events: [ActivityEvent] = []
        var message: String?
    }

    static func logArguments(_ window: DateInterval) -> [String] {
        ["show", "--style", "ndjson", "--start", "@\(Int64(window.start.timeIntervalSince1970))",
         "--end", "@\(Int64(window.end.timeIntervalSince1970))"]
    }

    static func logs(in window: DateInterval) async -> Result {
        let result = await CommandRunner.run("/usr/bin/log", logArguments(window), timeout: 10, outputLimit: 1_048_576)
        let message: String?
        if result.timedOut { message = "Unified log query timed out; narrow the range." }
        else if result.status != 0 { message = result.error.isEmpty ? "Unified logs unavailable." : String(result.error.prefix(500)) }
        else if result.truncated { message = "Unified log output reached 1 MB; narrow the range to see all entries." }
        else { message = nil }
        return Result(events: parseLog(result.output), message: message)
    }

    static func parseLog(_ output: String) -> [ActivityEvent] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return output.split(separator: "\n").enumerated().compactMap { index, line in
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let message = object["eventMessage"] as? String,
                  let timestamp = object["timestamp"] as? String,
                  let date = formatter.date(from: timestamp) else { return nil }
            let process = object["process"] as? String
            let level = object["messageType"] as? String ?? "Default"
            var details: [String: String] = ["message": message, "level": level, "raw record": String(line)]
            for key in ["subsystem", "category", "processID", "threadID", "activityIdentifier"] {
                if let value = object[key] { details[key] = String(describing: value) }
            }
            let severity: ActivityEventSeverity = ["error", "fault"].contains(level.lowercased()) ? .warning : .info
            return ActivityEvent.make(kind: .systemLog, timestamp: date, subject: process ?? "System",
                                      processName: process, severity: severity, details: details,
                                      dedupe: "\(index)|\(message)")
        }
    }

    static func reports(in window: DateInterval) -> Result {
        let folders = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
                       URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")]
        var events: [ActivityEvent] = []
        var unavailable = false
        for folder in folders {
            guard FileManager.default.isReadableFile(atPath: folder.path) else {
                unavailable = true
                continue
            }
            guard let urls = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                            options: [.skipsSubdirectoryDescendants]) else {
                unavailable = true
                continue
            }
            var scanned = 0
            for case let url as URL in urls {
                scanned += 1
                if scanned > 5_000 { unavailable = true; break }
                guard ["ips", "crash", "hang", "spin", "diag"].contains(url.pathExtension.lowercased()) else { continue }
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      window.contains(date) else { continue }
                events.append(.make(kind: .diagnosticReport, timestamp: date, subject: url.lastPathComponent,
                                    severity: .notice, details: ["path": url.path, "timestamp": "File modification time"],
                                    dedupe: url.path))
            }
        }
        return Result(events: events, message: unavailable ? "Some diagnostic reports were inaccessible or the scan limit was reached." : nil)
    }
}
