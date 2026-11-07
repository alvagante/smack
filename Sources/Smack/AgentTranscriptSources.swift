import Foundation
import SQLite3

/// Where an Agent Session's transcript lives: an append-only JSONL file (Claude Code, Codex) or an OpenCode session.
enum TranscriptSource: Sendable, Hashable, Identifiable {
    case file(path: String, format: TranscriptFormat)
    case openCode(database: String, session: String)

    var id: String {
        switch self {
        case .file(let path, _): "file:" + path
        case .openCode(_, let session): "opencode:" + session
        }
    }

    var format: TranscriptFormat {
        switch self {
        case .file(_, let format): format
        case .openCode: .openCode
        }
    }

    /// The file to reveal in Finder; the database for OpenCode.
    var path: String {
        switch self {
        case .file(let path, _): path
        case .openCode(let database, _): database
        }
    }
}

/// The only file capabilities transcripts need, injected so tests count what is read.
protocol TranscriptFileAccess: Sendable {
    func size(of path: String) -> UInt64?
    func read(_ path: String, offset: UInt64, length: Int) -> Data?
}

struct LocalTranscriptFileAccess: TranscriptFileAccess {
    func size(of path: String) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.size] as? NSNumber)?.uint64Value
    }

    func read(_ path: String, offset: UInt64, length: Int) -> Data? {
        guard length > 0, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: length)
        } catch {
            return nil
        }
    }
}

// MARK: - Following a transcript

/// Reads a JSONL transcript incrementally: each call reads only the bytes appended since the last one.
struct TranscriptFileTail: Sendable {
    static let chunk = 1 << 20
    /// A longer line (a huge tool output) is skipped rather than buffered.
    static let maximumLine = 16 << 20

    let path: String
    let format: TranscriptFormat
    private(set) var offset: UInt64 = 0
    private var lineStart: UInt64 = 0
    private var partial = Data()
    private var skipping = false
    private var parser: JSONLTranscriptParser

    init(path: String, format: TranscriptFormat) {
        self.path = path
        self.format = format
        parser = JSONLTranscriptParser(format: format)
    }

    /// False when the file did not grow. A file that shrank was replaced, so it is read again from the start.
    mutating func advance(using files: any TranscriptFileAccess, budget: UInt64 = 512 << 20) -> Bool {
        guard let size = files.size(of: path) else { return false }
        if size < offset { self = TranscriptFileTail(path: path, format: format) }
        guard size > offset else { return false }
        var remaining = budget
        while offset < size, remaining > 0 {
            let length = Int(min(UInt64(Self.chunk), size - offset, remaining))
            guard let data = files.read(path, offset: offset, length: length), !data.isEmpty else { break }
            consume(data)
            offset += UInt64(data.count)
            remaining -= min(remaining, UInt64(data.count))
        }
        // A line still being written waits for its newline; agents end every record with one.
        return true
    }

    private mutating func consume(_ data: Data) {
        let base = offset
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            if skipping {
                skipping = false
            } else if partial.isEmpty {
                parser.consume(line: data[start..<newline], range: TranscriptByteRange(offset: lineStart, length: newline - start))
            } else {
                partial.append(data[start..<newline])
                parser.consume(line: partial, range: TranscriptByteRange(offset: lineStart, length: partial.count))
            }
            partial.removeAll(keepingCapacity: true)
            start = data.index(after: newline)
            lineStart = base + UInt64(start - data.startIndex)
        }
        guard start < data.endIndex, !skipping else { return }
        if partial.count + (data.endIndex - start) > Self.maximumLine {
            skipping = true
            partial.removeAll()
        } else {
            partial.append(data[start...])
        }
    }

    var index: TranscriptIndex { parser.index() }
}

/// An OpenCode database opened read-only. Only `session_v2` and `session_message` are ever queried:
/// the same file holds account credentials, which Smack never reads.
struct OpenCodeDatabase: Sendable {
    let path: String

    static let messagesSQL = """
        SELECT id, type, time_created, time_updated, data FROM session_message
        WHERE session_id = ?1 AND (time_updated > ?2 OR (time_updated = ?2 AND id > ?3))
        ORDER BY time_updated, id LIMIT ?4
        """
    static let messageSQL = "SELECT type, data FROM session_message WHERE session_id = ?1 AND id = ?2"
    static let liveSQL = """
        SELECT id FROM session_v2 WHERE directory = ?1 AND parent_id IS NULL AND time_updated >= ?2
        ORDER BY time_updated DESC LIMIT 1
        """
    static let recentSQL = """
        SELECT id, title, directory, time_created, time_updated FROM session_v2
        WHERE parent_id IS NULL AND time_archived IS NULL ORDER BY time_updated DESC LIMIT ?1
        """
    static var statements: [String] { [messagesSQL, messageSQL, liveSQL, recentSQL] }

    struct Row: Sendable {
        var id: String
        var type: String
        var created: Int64
        var updated: Int64
        var data: Data
    }

    struct Summary: Sendable {
        var id: String
        var title: String?
        var directory: String?
        var created: Date
        var updated: Date
    }

    func open() -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var components = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        var db: OpaquePointer?
        guard sqlite3_open_v2(components.string!, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 200)
        return db
    }

    func messages(_ db: OpaquePointer, session: String, after cursor: (updated: Int64, id: String), limit: Int) -> [Row]? {
        query(db, Self.messagesSQL, bind: { statement in
            Self.bind(session, at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, cursor.updated)
            Self.bind(cursor.id, at: 3, to: statement)
            sqlite3_bind_int64(statement, 4, Int64(limit))
        }) { statement in
            Row(id: Self.text(statement, 0) ?? "", type: Self.text(statement, 1) ?? "",
                created: sqlite3_column_int64(statement, 2), updated: sqlite3_column_int64(statement, 3), data: Self.data(statement, 4))
        }
    }

    func message(session: String, id: String) -> (type: String, data: Data)? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        return query(db, Self.messageSQL, bind: { statement in
            Self.bind(session, at: 1, to: statement)
            Self.bind(id, at: 2, to: statement)
        }) { statement in (type: Self.text(statement, 0) ?? "", data: Self.data(statement, 1)) }?.first
    }

    /// The newest top-level session in `directory` updated since `since`: the one a running process is writing.
    func liveSession(directory: String, since: Date) -> String? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        return query(db, Self.liveSQL, bind: { statement in
            Self.bind(directory, at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, Int64(since.timeIntervalSince1970 * 1000))
        }) { Self.text($0, 0) }?.first ?? nil
    }

    func recent(limit: Int) -> [Summary] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        return query(db, Self.recentSQL, bind: { sqlite3_bind_int64($0, 1, Int64(limit)) }) { statement in
            Summary(id: Self.text(statement, 0) ?? "", title: Self.text(statement, 1), directory: Self.text(statement, 2),
                    created: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000),
                    updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 4)) / 1000))
        } ?? []
    }

    private func query<T>(_ db: OpaquePointer, _ sql: String, bind: (OpaquePointer) -> Void, map: (OpaquePointer) -> T) -> [T]? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        bind(statement)
        var result: [T] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            result.append(map(statement))
            code = sqlite3_step(statement)
        }
        return code == SQLITE_DONE ? result : nil
    }

    private static func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private static func data(_ statement: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}

/// Reads the rows of one OpenCode session changed since the last call.
struct OpenCodeTranscriptTail: Sendable {
    static let page = 1_000

    let database: OpenCodeDatabase
    let session: String
    private var cursor: (updated: Int64, id: String) = (-1, "")
    private var parser = OpenCodeTranscriptParser()

    init(database: OpenCodeDatabase, session: String) {
        self.database = database
        self.session = session
    }

    mutating func advance() -> Bool {
        guard let db = database.open() else { return false }
        defer { sqlite3_close(db) }
        var changed = false
        for _ in 0..<50 {
            guard let rows = database.messages(db, session: session, after: cursor, limit: Self.page) else { break }
            for row in rows {
                parser.consume(id: row.id, type: row.type, created: Date(timeIntervalSince1970: Double(row.created) / 1000), data: row.data)
                cursor = (row.updated, row.id)
            }
            changed = changed || !rows.isEmpty
            if rows.count < Self.page { break }
        }
        return changed
    }

    var index: TranscriptIndex { parser.acc.index() }
}

/// Follows one transcript. A class handed to one background task at a time, so its parsed state is never copied;
/// `SessionTimelineModel` never touches it while a task holds it.
final class TranscriptTail: @unchecked Sendable {
    let source: TranscriptSource
    private var file: TranscriptFileTail?
    private var openCode: OpenCodeTranscriptTail?

    init(source: TranscriptSource) {
        self.source = source
        switch source {
        case .file(let path, let format): file = TranscriptFileTail(path: path, format: format)
        case .openCode(let database, let session): openCode = OpenCodeTranscriptTail(database: OpenCodeDatabase(path: database), session: session)
        }
    }

    /// Reads what changed; nil when nothing did.
    func advance(using files: any TranscriptFileAccess) -> TranscriptIndex? {
        if file != nil {
            return file!.advance(using: files) ? file!.index : nil
        }
        if openCode != nil {
            return openCode!.advance() ? openCode!.index : nil
        }
        return nil
    }
}

// MARK: - Finding transcripts

/// Matches a running Agent Session to its transcript, by project directory and start time.
struct TranscriptLocator: Sendable {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var files: any TranscriptFileAccess = LocalTranscriptFileAccess()
    var listing: @Sendable (URL) -> [AgentSessionLog] = TranscriptLocator.files(in:)
    var now: @Sendable () -> Date = { Date() }

    func source(for session: AgentSession) -> TranscriptSource? {
        switch session.agentID {
        case "claude":
            if let path = session.log?.path, path.hasSuffix(".jsonl") { return .file(path: path, format: .claude) }
            return CatalogSessionLogAdapter(agentID: "claude").latestLog(for: session, home: home).map { .file(path: $0.path, format: .claude) }
        case "codex":
            return codex(for: session)
        case "opencode":
            guard let directory = session.project?.directory else { return nil }
            let database = OpenCodeDatabase(path: openCodeDatabase.path)
            return database.liveSession(directory: directory, since: session.startedAt.addingTimeInterval(-5))
                .map { .openCode(database: database.path, session: $0) }
        default:
            return nil
        }
    }

    var openCodeDatabase: URL { home.appendingPathComponent(".local/share/opencode/opencode.db") }

    /// Codex files rollouts by the day they started; only the days the session spans are listed.
    private func codex(for session: AgentSession) -> TranscriptSource? {
        let root = home.appendingPathComponent(".codex/sessions")
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: session.startedAt.addingTimeInterval(-86_400))
        let end = now()
        var candidates: [AgentSessionLog] = []
        while day <= end, candidates.count < 400 {
            candidates += listing(Self.dayFolder(root, day, calendar)).filter {
                $0.path.hasSuffix(".jsonl") && $0.modifiedAt >= session.startedAt.addingTimeInterval(-5)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        for log in candidates.sorted(by: { $0.modifiedAt > $1.modifiedAt }).prefix(20) {
            guard let directory = session.project?.directory else { return .file(path: log.path, format: .codex) }
            if Self.codexDirectory(files.read(log.path, offset: 0, length: 16_384)) == directory {
                return .file(path: log.path, format: .codex)
            }
        }
        return nil
    }

    static func dayFolder(_ root: URL, _ day: Date, _ calendar: Calendar) -> URL {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        func pad(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return root.appendingPathComponent(pad(parts.year, 4)).appendingPathComponent(pad(parts.month, 2)).appendingPathComponent(pad(parts.day, 2))
    }

    /// The `cwd` in the head of a Codex rollout, read without parsing its first line, which can be very long.
    static func codexDirectory(_ head: Data?) -> String? {
        guard let head else { return nil }
        let text = String(decoding: head, as: UTF8.self)
        guard let key = text.range(of: "\"cwd\":\"") else { return nil }
        var end = key.upperBound
        var escaped = false
        while end < text.endIndex {
            let character = text[end]
            if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { break }
            end = text.index(after: end)
        }
        guard end < text.endIndex else { return nil }
        let literal = "\"" + text[key.upperBound..<end] + "\""
        return (try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed)) as? String
    }

    /// Regular files directly inside `folder`, with size and modification time.
    static func files(in folder: URL) -> [AgentSessionLog] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return urls.prefix(10_000).compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate else { return nil }
            return AgentSessionLog(path: url.path, size: values.fileSize ?? 0, modifiedAt: modified)
        }
    }

    /// Subfolders directly inside `folder`, newest name first.
    static func folders(in folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

/// A transcript of an Agent Session that is no longer tracked, listed for the Session Timeline.
struct PastTranscript: Identifiable, Sendable, Equatable {
    var source: TranscriptSource
    var directory: String?
    var title: String?
    var started: Date?
    var updated: Date
    var size: Int?

    var id: String { source.id }
    var agentID: String { source.format.agentID }
    var projectName: String? { directory.map { ($0 as NSString).lastPathComponent } }
}

struct TranscriptCatalogResult: Sendable, Equatable {
    var items: [PastTranscript] = []
    /// Codex rollouts kept only compressed (`.jsonl.zst`), which Smack cannot read without a dependency.
    var compressed = 0
}

/// Lists the newest transcripts of every supported agent. Reads directory entries, the first 64 KB of the listed
/// Claude Code and Codex files, and one OpenCode query.
struct TranscriptCatalog: Sendable {
    static let headBytes = 65_536

    var home = FileManager.default.homeDirectoryForCurrentUser
    var files: any TranscriptFileAccess = LocalTranscriptFileAccess()
    var listing: @Sendable (URL) -> [AgentSessionLog] = TranscriptLocator.files(in:)
    var folders: @Sendable (URL) -> [URL] = TranscriptLocator.folders(in:)
    var agents: Set<String> = ["claude", "codex", "opencode"]

    func recent(limit: Int) -> TranscriptCatalogResult {
        var result = TranscriptCatalogResult()
        var items: [PastTranscript] = []
        if agents.contains("claude") { items += claude(limit: limit) }
        if agents.contains("codex") {
            let (codex, compressed) = self.codex(limit: limit)
            items += codex
            result.compressed = compressed
        }
        if agents.contains("opencode") {
            let database = OpenCodeDatabase(path: home.appendingPathComponent(".local/share/opencode/opencode.db").path)
            items += database.recent(limit: limit).map {
                PastTranscript(source: .openCode(database: database.path, session: $0.id), directory: $0.directory,
                               title: $0.title, started: $0.created, updated: $0.updated)
            }
        }
        result.items = Array(items.sorted { $0.updated > $1.updated }.prefix(limit))
        return result
    }

    private func claude(limit: Int) -> [PastTranscript] {
        let root = home.appendingPathComponent(".claude/projects")
        var logs: [AgentSessionLog] = []
        for folder in folders(root).prefix(2_000) {
            // Subagent transcripts (`agent-*.jsonl`) belong to their parent session.
            logs += listing(folder).filter { $0.path.hasSuffix(".jsonl") && !($0.path as NSString).lastPathComponent.hasPrefix("agent-") }
        }
        return logs.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit).map { log in
            let head = Self.headIndex(files.read(log.path, offset: 0, length: Self.headBytes), format: .claude)
            return PastTranscript(source: .file(path: log.path, format: .claude), directory: head.directory, title: head.title,
                                  started: head.first, updated: log.modifiedAt, size: log.size)
        }
    }

    private func codex(limit: Int) -> ([PastTranscript], Int) {
        let root = home.appendingPathComponent(".codex/sessions")
        var logs: [AgentSessionLog] = []
        var compressed = 0
        outer: for year in folders(root) {
            for month in folders(year) {
                for day in folders(month) {
                    let entries = listing(day)
                    let plain = Set(entries.map(\.path).filter { $0.hasSuffix(".jsonl") })
                    logs += entries.filter { $0.path.hasSuffix(".jsonl") }
                    compressed += entries.filter { $0.path.hasSuffix(".jsonl.zst") && !plain.contains(String($0.path.dropLast(4))) }.count
                    if logs.count >= limit { break outer }
                }
            }
        }
        let items = logs.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit).map { log in
            let data = files.read(log.path, offset: 0, length: Self.headBytes * 2)
            let head = Self.headIndex(data, format: .codex)
            return PastTranscript(source: .file(path: log.path, format: .codex),
                                  directory: head.directory ?? TranscriptLocator.codexDirectory(data), title: head.title,
                                  started: head.first, updated: log.modifiedAt, size: log.size)
        }
        return (Array(items), compressed)
    }

    /// Parses the complete lines in the head of a transcript.
    static func headIndex(_ data: Data?, format: TranscriptFormat) -> TranscriptIndex {
        guard let data, !data.isEmpty else { return TranscriptIndex() }
        var parser = JSONLTranscriptParser(format: format)
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            parser.consume(line: data[start..<newline],
                           range: TranscriptByteRange(offset: UInt64(start - data.startIndex), length: newline - start))
            start = data.index(after: newline)
        }
        return parser.index()
    }
}
