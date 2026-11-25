import Foundation

struct TimelineFileSource: Identifiable, Sendable {
    var id: String { path }
    var path: String
    var start: Date?
    var end: Date?
    var sampled: Bool
    var inferredYear = false
    var events: [ActivityEvent]
    var error: String?
}

enum TimelineFileSources {
    static let fileLimit = 200
    static let sampleBytes = 65_536
    static let eventLimit = 100

    // Built once, not per file: a scan parses up to `fileLimit` files. ISO8601DateFormatter is thread-safe
    // but not marked Sendable; none of these is mutated after initialization.
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:?\d\d)"#)
    private static let syslog = try! NSRegularExpression(pattern: #"^[A-Z][a-z]{2}\s+\d{1,2}\s+\d\d:\d\d:\d\d"#)
    private static let syslogDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm:ss yyyy"
        return formatter
    }()

    static func parse(path: String, head: String, tail: String, sampled: Bool, reference: Date = Date()) -> TimelineFileSource {
        let (iso, fractional, pattern, syslog, syslogDate) = (Self.iso, Self.fractional, Self.pattern, Self.syslog, Self.syslogDate)
        let calendar = Calendar.current
        let year = calendar.component(.year, from: reference)
        var inferred = false
        var matches: [(Date, String)] = []
        for line in (head + (tail.isEmpty ? "" : "\n" + tail)).split(separator: "\n") {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            let date: Date
            if let match = pattern.firstMatch(in: text, range: range), let swiftRange = Range(match.range, in: text) {
                let timestamp = String(text[swiftRange]).replacingOccurrences(of: " ", with: "T")
                guard let parsed = fractional.date(from: timestamp) ?? iso.date(from: timestamp) else { continue }
                date = parsed
            } else if let match = syslog.firstMatch(in: text, range: range), let swiftRange = Range(match.range, in: text) {
                let prefix = text[swiftRange].split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard let parsed = syslogDate.date(from: "\(prefix) \(year)") else { continue }
                date = parsed > reference.addingTimeInterval(86_400) ? (calendar.date(byAdding: .year, value: -1, to: parsed) ?? parsed) : parsed
                inferred = true
            } else { continue }
            matches.append((date, text))
        }
        let selected = matches.count <= eventLimit ? matches : Array(matches.prefix(eventLimit / 2)) + Array(matches.suffix(eventLimit / 2))
        let events = selected.enumerated().map { index, item in
            ActivityEvent.make(kind: .fileLog, timestamp: item.0, subject: URL(fileURLWithPath: path).lastPathComponent,
                               severity: .info, details: ["path": path, "message": item.1], dedupe: "\(index)|\(item.1)")
        }
        return TimelineFileSource(path: path, start: matches.map(\.0).min(), end: matches.map(\.0).max(),
                                  sampled: sampled || matches.count > eventLimit, inferredYear: inferred, events: events, error: nil)
    }

    static func scan(custom: [Data]) -> [TimelineFileSource] {
        let fm = FileManager.default
        let roots = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs"),
                     URL(fileURLWithPath: "/Library/Logs"), URL(fileURLWithPath: "/private/var/log")]
        return scan(custom: custom, roots: roots, systemPaths: ["/private/var/log/system.log", "/private/var/log/install.log"])
    }

    static func scan(custom: [Data], roots: [URL], systemPaths: [String],
                     files: any LogFileAccess = LocalLogFileAccess()) -> [TimelineFileSource] {
        var candidates: [(URL, Bool)] = []
        var inaccessible: [TimelineFileSource] = []
        var visited = 0
        for data in custom.prefix(fileLimit) {
            if let url = files.resolveBookmark(data) { candidates.append((url, true)) }
        }
        for path in systemPaths where files.exists(path) {
            candidates.append((URL(fileURLWithPath: path), false))
        }
        for root in roots {
            let readable = files.walk(root, levels: 2) { url, isFile in
                visited += 1
                if Task.isCancelled || candidates.count >= fileLimit || visited > 5_000 { return false }
                if isFile, ["log", "_log", "its"].contains(url.pathExtension.lowercased()) { candidates.append((url, false)) }
                return true
            }
            if !readable {
                inaccessible.append(unavailable(root.path))
                continue
            }
            if candidates.count >= fileLimit || visited > 5_000 || Task.isCancelled { break }
        }
        var seen = Set<String>()
        let sources: [TimelineFileSource] = candidates.prefix(fileLimit).compactMap { url, scoped in
            guard seen.insert(url.path).inserted, !Task.isCancelled else { return nil }
            return files.withAccess(to: url, scoped: scoped) { sample(url.path, files: files) }
        }
        return inaccessible + sources
    }

    /// Parses at most `sampleBytes` from each end of a file.
    private static func sample(_ path: String, files: any LogFileAccess) -> TimelineFileSource {
        let limit = UInt64(sampleBytes)
        guard let size = files.size(of: path),
              let head = size == 0 ? Data() : files.read(path, offset: 0, length: sampleBytes),
              let tail = size > limit ? files.read(path, offset: max(limit, size - limit), length: sampleBytes) : Data() else {
            return unavailable(path)
        }
        return parse(path: path, head: String(decoding: head, as: UTF8.self), tail: String(decoding: tail, as: UTF8.self),
                     sampled: size > limit * 2, reference: files.modified(path) ?? Date())
    }

    private static func unavailable(_ path: String) -> TimelineFileSource {
        TimelineFileSource(path: path, start: nil, end: nil, sampled: false, events: [], error: "Unavailable")
    }
}
