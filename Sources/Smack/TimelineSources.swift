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

    typealias Run = @Sendable (_ executable: String, _ arguments: [String]) async -> CommandRunner.Result

    static func logs(in window: DateInterval,
                     run: Run = { await CommandRunner.run($0, $1, timeout: 10, outputLimit: 1_048_576) }) async -> Result {
        let result = await run("/usr/bin/log", logArguments(window))
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

    static func reports(in window: DateInterval,
                        folders: [URL] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
                                          URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")],
                        files: any LogFileAccess = LocalLogFileAccess()) -> Result {
        var events: [ActivityEvent] = []
        var unavailable = false
        for folder in folders {
            var scanned = 0
            let readable = files.walk(folder, levels: 1) { url, _ in
                scanned += 1
                if scanned > 5_000 { unavailable = true; return false }
                guard ["ips", "crash", "hang", "spin", "diag"].contains(url.pathExtension.lowercased()),
                      let date = files.modified(url.path), window.contains(date) else { return true }
                events.append(.make(kind: .diagnosticReport, timestamp: date, subject: url.lastPathComponent,
                                    severity: .notice, details: ["path": url.path, "timestamp": "File modification time"],
                                    dedupe: url.path))
                return true
            }
            if !readable { unavailable = true }
        }
        return Result(events: events, message: unavailable ? "Some diagnostic reports were inaccessible or the scan limit was reached." : nil)
    }
}
