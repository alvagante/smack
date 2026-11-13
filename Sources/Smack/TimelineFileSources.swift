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

    static func parse(path: String, head: String, tail: String, sampled: Bool, reference: Date = Date()) -> TimelineFileSource {
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let pattern = try! NSRegularExpression(pattern: #"^\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:?\d\d)"#)
        let syslog = try! NSRegularExpression(pattern: #"^[A-Z][a-z]{2}\s+\d{1,2}\s+\d\d:\d\d:\d\d"#)
        let syslogDate = DateFormatter()
        syslogDate.locale = Locale(identifier: "en_US_POSIX")
        syslogDate.dateFormat = "MMM d HH:mm:ss yyyy"
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

    static func scan(custom: [Data], roots: [URL], systemPaths: [String]) -> [TimelineFileSource] {
        let fm = FileManager.default
        var candidates: [(URL, Bool)] = []
        var inaccessible: [TimelineFileSource] = []
        var visited = 0
        for data in custom.prefix(fileLimit) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                candidates.append((url, true))
            }
        }
        for path in systemPaths where fm.fileExists(atPath: path) {
            candidates.append((URL(fileURLWithPath: path), false))
        }
        for root in roots {
            guard fm.isReadableFile(atPath: root.path),
                  let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                               options: [.skipsHiddenFiles]) else {
                inaccessible.append(TimelineFileSource(path: root.path, start: nil, end: nil, sampled: false, events: [], error: "Unavailable"))
                continue
            }
            for case let url as URL in iterator {
                visited += 1
                if Task.isCancelled || candidates.count >= fileLimit || visited > 5_000 { break }
                if iterator.level > 2 { iterator.skipDescendants(); continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                      ["log", "_log", "its"].contains(url.pathExtension.lowercased()) else { continue }
                candidates.append((url, false))
            }
            if candidates.count >= fileLimit || visited > 5_000 || Task.isCancelled { break }
        }
        var seen = Set<String>()
        let files: [TimelineFileSource] = candidates.prefix(fileLimit).compactMap { url, scoped in
            guard seen.insert(url.path).inserted, !Task.isCancelled else { return nil }
            let active = scoped && url.startAccessingSecurityScopedResource()
            defer { if active { url.stopAccessingSecurityScopedResource() } }
            do {
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let size = try file.seekToEnd()
                try file.seek(toOffset: 0)
                let head = try file.read(upToCount: sampleBytes) ?? Data()
                var tail = Data()
                if size > UInt64(sampleBytes) {
                    try file.seek(toOffset: max(UInt64(sampleBytes), size > UInt64(sampleBytes) ? size - UInt64(sampleBytes) : 0))
                    tail = try file.read(upToCount: sampleBytes) ?? Data()
                }
                let reference = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                return parse(path: url.path, head: String(decoding: head, as: UTF8.self),
                             tail: String(decoding: tail, as: UTF8.self), sampled: size > UInt64(sampleBytes * 2), reference: reference)
            } catch {
                return TimelineFileSource(path: url.path, start: nil, end: nil, sampled: false, events: [], error: "Unavailable")
            }
        }
        return inaccessible + files
    }
}
