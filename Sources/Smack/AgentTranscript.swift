import Foundation

/// A Session Timeline row. Lanes are drawn top to bottom in declaration order.
enum TranscriptLane: String, CaseIterable, Identifiable, Sendable {
    case prompts = "Prompts"
    case answers = "Answers"
    case thinking = "Thinking"
    case commands = "Commands"
    case mcp = "MCP"
    case files = "Files"
    case web = "Web"
    case tools = "Tools"
    case subagents = "Subagents"
    case context = "Context"
    case processes = "Processes"
    var id: Self { self }
}

enum TranscriptEventKind: String, Sendable {
    case prompt, answer, thinking, command, mcp, fileRead, fileChange, web, tool, subagent, compaction, notice, process

    var lane: TranscriptLane {
        switch self {
        case .prompt: .prompts
        case .answer: .answers
        case .thinking: .thinking
        case .command: .commands
        case .mcp: .mcp
        case .fileRead, .fileChange: .files
        case .web: .web
        case .tool: .tools
        case .subagent: .subagents
        case .compaction, .notice: .context
        case .process: .processes
        }
    }

    var title: String {
        switch self {
        case .prompt: "Prompt"
        case .answer: "Answer"
        case .thinking: "Thinking"
        case .command: "Command"
        case .mcp: "MCP call"
        case .fileRead: "File read"
        case .fileChange: "File change"
        case .web: "Web"
        case .tool: "Tool call"
        case .subagent: "Subagent"
        case .compaction: "Compaction"
        case .notice: "Notice"
        case .process: "Process"
        }
    }

    var systemImage: String {
        switch self {
        case .prompt: "person.fill"
        case .answer: "text.bubble.fill"
        case .thinking: "brain"
        case .command: "terminal.fill"
        case .mcp: "server.rack"
        case .fileRead: "doc.text"
        case .fileChange: "pencil.line"
        case .web: "globe"
        case .tool: "wrench.and.screwdriver"
        case .subagent: "person.2.fill"
        case .compaction: "arrow.down.right.and.arrow.up.left"
        case .notice: "info.circle"
        case .process: "gearshape"
        }
    }
}

enum TranscriptEventStatus: Sendable {
    case ok, failed, running
}

/// Where a line sits in a transcript file, so details are read back only when an event is opened.
struct TranscriptByteRange: Sendable, Hashable {
    var offset: UInt64
    var length: Int
}

enum TranscriptRef: Sendable, Equatable {
    case none
    case lines([TranscriptByteRange])
    case openCode(messageID: String, part: Int?)
}

/// One thing an Agent Session did: a prompt, an answer, a tool call, a process. Only a short title is kept;
/// the full text stays in the transcript and is read on demand.
struct TranscriptEvent: Identifiable, Sendable, Equatable {
    var id: String
    var kind: TranscriptEventKind
    var start: Date
    var end: Date?
    var title: String
    var subtitle: String?
    var status: TranscriptEventStatus = .ok
    /// Work done by a subagent inside the same transcript; drawn on the Subagents lane.
    var sidechain = false
    var ref: TranscriptRef = .none

    var lane: TranscriptLane { sidechain && kind != .process ? .subagents : kind.lane }
    var duration: TimeInterval? { end.map { max(0, $0.timeIntervalSince(start)) } }
}

struct TranscriptTokens: Sendable, Equatable {
    var date: Date
    var input: Int
    var output: Int
}

/// One prompt and the work it caused, until the next prompt or the end of the turn.
struct TranscriptTurn: Identifiable, Sendable, Equatable {
    var id: String
    var start: Date
    var end: Date
}

/// Everything the Session Timeline draws for one transcript, about 100 bytes per event.
struct TranscriptIndex: Sendable, Equatable {
    var events: [TranscriptEvent] = []
    var tokens: [TranscriptTokens] = []
    var turns: [TranscriptTurn] = []
    var model: String?
    var directory: String?
    var title: String?
    /// Oldest events dropped to stay under `TranscriptAccumulator.eventCap`.
    var dropped = 0
    /// Line or record types this version does not read, with their counts. Shown by the live transcript test.
    var unrecognized: [String: Int] = [:]

    var first: Date? { events.first?.start }
    var last: Date? { events.reduce(nil as Date?) { latest, event in max(latest ?? event.start, event.end ?? event.start) } }
    var outputTokens: Int { tokens.reduce(0) { $0 + $1.output } }
    var inputTokens: Int { tokens.reduce(0) { $0 + $1.input } }
}

/// Collects events while a transcript is read; ids are unique, so a later line can complete an earlier call.
struct TranscriptAccumulator: Sendable {
    static let eventCap = 20_000

    private(set) var events: [TranscriptEvent] = []
    private var positions: [String: Int] = [:]
    /// Codex writes some calls twice, in an older and a newer form; older ones are dropped once newer ones appear.
    private var legacyIDs: Set<String> = []
    private(set) var hasItems = false
    private(set) var tokens: [TranscriptTokens] = []
    private var tokenPositions: [String: Int] = [:]
    var turns: [TranscriptTurn] = []
    var model: String?
    var directory: String?
    var title: String?
    private(set) var unrecognized: [String: Int] = [:]
    private(set) var dropped = 0

    mutating func add(_ event: TranscriptEvent, legacy: Bool = false) {
        if let index = positions[event.id] {
            events[index] = event
            return
        }
        positions[event.id] = events.count
        events.append(event)
        if legacy { legacyIDs.insert(event.id) }
        if events.count > Self.eventCap + Self.eventCap / 4 { compact() }
    }

    /// Changes an event added earlier; false when it is unknown, such as a result whose call was dropped.
    @discardableResult
    mutating func update(_ id: String, _ change: (inout TranscriptEvent) -> Void) -> Bool {
        guard let index = positions[id] else { return false }
        change(&events[index])
        return true
    }

    func contains(_ id: String) -> Bool { positions[id] != nil }

    mutating func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        events.removeAll { ids.contains($0.id) }
        legacyIDs.subtract(ids)
        reindex()
    }

    mutating func markItems() { hasItems = true }

    /// Adds a token sample; a `key` already seen replaces its sample, because a message can be logged more than once.
    mutating func token(_ sample: TranscriptTokens, key: String? = nil) {
        if let key, let index = tokenPositions[key] {
            tokens[index] = sample
            return
        }
        if let key { tokenPositions[key] = tokens.count }
        tokens.append(sample)
        if tokens.count > Self.eventCap {
            tokens.removeFirst(tokens.count - Self.eventCap)
            tokenPositions.removeAll()
        }
    }

    mutating func note(_ type: String) {
        guard unrecognized.count < 64 || unrecognized[type] != nil else { return }
        unrecognized[type, default: 0] += 1
    }

    private mutating func compact() {
        events.sort { $0.start < $1.start }
        let excess = events.count - Self.eventCap
        dropped += excess
        events.removeFirst(excess)
        reindex()
    }

    private mutating func reindex() {
        positions = Dictionary(events.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        legacyIDs = legacyIDs.filter { positions[$0] != nil }
    }

    func index() -> TranscriptIndex {
        var list = hasItems && !legacyIDs.isEmpty ? events.filter { !legacyIDs.contains($0.id) } : events
        list.sort { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        var result = TranscriptIndex(events: list, tokens: tokens.sorted { $0.date < $1.date }, model: model,
                                     directory: directory, dropped: dropped, unrecognized: unrecognized)
        let prompts = list.filter { $0.kind == .prompt && !$0.sidechain }
        result.title = title ?? prompts.first?.title
        if !turns.isEmpty {
            result.turns = turns.sorted { $0.start < $1.start }
        } else {
            let last = result.last
            result.turns = prompts.enumerated().map { offset, prompt in
                let end = offset + 1 < prompts.count ? prompts[offset + 1].start : (last ?? prompt.start)
                return TranscriptTurn(id: prompt.id, start: prompt.start, end: max(end, prompt.start))
            }
        }
        return result
    }
}

// MARK: - Shared parsing helpers

extension Dictionary where Key == String, Value == Any {
    func txString(_ key: String) -> String? { self[key] as? String }
    func txObject(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func txObjects(_ key: String) -> [[String: Any]]? { self[key] as? [[String: Any]] }
    func txNumber(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func txBool(_ key: String) -> Bool? { self[key] as? Bool }
    /// True when the key holds anything but JSON null.
    func txPresent(_ key: String) -> Bool { self[key].map { !($0 is NSNull) } ?? false }
}

enum TranscriptTime {
    /// Parses the fixed ISO 8601 layout agents write (`2026-11-01T18:31:14.422Z`) without a formatter;
    /// other layouts fall back to `ISO8601FormatStyle`.
    static func parse(_ text: String) -> Date? {
        let b = Array(text.utf8)
        guard b.count >= 20, b[4] == 45, b[7] == 45, b[10] == 84 || b[10] == 32, b[13] == 58, b[16] == 58 else {
            return fallback(text)
        }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                guard (48...57).contains(b[index]) else { return nil }
                value = value * 10 + Int(b[index] - 48)
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              (1...12).contains(month), (1...31).contains(day) else { return fallback(text) }
        var index = 19
        var fraction = 0.0
        if index < b.count, b[index] == 46 {
            index += 1
            var scale = 0.1
            while index < b.count, (48...57).contains(b[index]) {
                fraction += Double(b[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }
        guard index < b.count else { return fallback(text) }
        var offset = 0
        if b[index] == 90 {
            index += 1
        } else if b[index] == 43 || b[index] == 45, index + 6 <= b.count, b[index + 3] == 58,
                  let hours = number(index + 1..<index + 3), let minutes = number(index + 4..<index + 6) {
            offset = (hours * 3600 + minutes * 60) * (b[index] == 43 ? 1 : -1)
            index += 6
        } else {
            return fallback(text)
        }
        guard index == b.count else { return fallback(text) }
        let days = daysFromCivil(year: year, month: month, day: day)
        return Date(timeIntervalSince1970: Double(days * 86_400 + hour * 3600 + minute * 60 + second - offset) + fraction)
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func milliseconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }

    /// A Rust `Duration` as written by Codex: `{"secs": 1, "nanos": 500000000}`.
    static func seconds(_ value: Any?) -> TimeInterval? {
        guard let object = value as? [String: Any], let secs = object.txNumber("secs") else { return nil }
        return secs + (object.txNumber("nanos") ?? 0) / 1_000_000_000
    }

    private static func fallback(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ??
            (try? Date.ISO8601FormatStyle().parse(text))
    }
}

enum TranscriptText {
    /// One line of at most `limit` characters, read from the start of `text` only.
    static func title(_ text: String, limit: Int = 160) -> String {
        let words = text.prefix(limit * 4).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > limit ? String(words.prefix(limit - 1)) + "…" : words
    }

    /// Text in `content` that is either a string or an array of `{text: …}` blocks.
    static func joined(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0.txString("text") }.joined(separator: "\n")
    }

    static func basename(_ path: String) -> String {
        path.isEmpty ? path : (path as NSString).lastPathComponent
    }

    /// The first short string value in a tool's input, used as its subtitle.
    static func summary(_ input: [String: Any]) -> String? {
        for key in ["command", "file_path", "filePath", "path", "url", "query", "pattern", "description", "prompt", "name"] {
            if let value = input.txString(key), !value.isEmpty { return title(value, limit: 120) }
        }
        for key in input.keys.sorted() {
            if let value = input.txString(key), !value.isEmpty { return title(value, limit: 120) }
        }
        return nil
    }

    static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - JSONL transcripts

enum TranscriptFormat: String, Sendable, Hashable {
    case claude, codex, openCode

    init?(agentID: String) {
        switch agentID {
        case "claude": self = .claude
        case "codex": self = .codex
        case "opencode": self = .openCode
        default: return nil
        }
    }

    var agentID: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .openCode: "opencode"
        }
    }
}

/// Reads one JSONL line at a time. Parsers sit in optionals so they are mutated in place, never copied per line.
struct JSONLTranscriptParser: Sendable {
    private var claude: ClaudeTranscriptParser?
    private var codex: CodexTranscriptParser?

    init(format: TranscriptFormat) {
        if format == .codex { codex = CodexTranscriptParser() } else { claude = ClaudeTranscriptParser() }
    }

    mutating func consume(line: Data, range: TranscriptByteRange) {
        guard !line.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        claude?.consume(object, range: range)
        codex?.consume(object, range: range)
    }

    func index() -> TranscriptIndex {
        claude?.acc.index() ?? codex?.acc.index() ?? TranscriptIndex()
    }
}

/// Claude Code: `~/.claude/projects/<project>/<session>.jsonl`, one message or content block per line.
struct ClaudeTranscriptParser: Sendable {
    var acc = TranscriptAccumulator()

    static let ignored: Set<String> = ["file-history-snapshot", "queue-operation", "progress", "attachment", "custom-title", "tag"]

    mutating func consume(_ object: [String: Any], range: TranscriptByteRange) {
        let type = object.txString("type") ?? ""
        if acc.directory == nil, let cwd = object.txString("cwd") { acc.directory = cwd }
        switch type {
        case "user", "assistant", "system": break
        case "summary":
            if acc.title == nil, let summary = object.txString("summary") { acc.title = TranscriptText.title(summary) }
            return
        default:
            if !Self.ignored.contains(type) { acc.note(type.isEmpty ? "untyped" : type) }
            return
        }
        guard let date = object.txString("timestamp").flatMap(TranscriptTime.parse) else { return }
        let sidechain = object.txBool("isSidechain") ?? false
        let uuid = object.txString("uuid") ?? "line-\(range.offset)"
        let message = object.txObject("message")
        switch type {
        case "user": user(object, message: message, uuid: uuid, date: date, sidechain: sidechain, range: range)
        case "assistant": assistant(message, uuid: uuid, date: date, sidechain: sidechain, range: range)
        default: system(object, uuid: uuid, date: date, range: range)
        }
    }

    private mutating func user(_ object: [String: Any], message: [String: Any]?, uuid: String, date: Date, sidechain: Bool, range: TranscriptByteRange) {
        if object.txBool("isMeta") == true { return }
        if object.txBool("isCompactSummary") == true {
            acc.add(TranscriptEvent(id: uuid, kind: .compaction, start: date, title: "Conversation compacted", ref: .lines([range])))
            return
        }
        var texts: [String] = []
        var results = false
        if let text = message?["content"] as? String {
            texts.append(text)
        } else {
            for block in message?.txObjects("content") ?? [] {
                switch block.txString("type") ?? "" {
                case "tool_result":
                    results = true
                    guard let id = block.txString("tool_use_id") else { continue }
                    let failed = block.txBool("is_error") == true
                    acc.update(id) { event in
                        event.end = max(date, event.start)
                        event.status = failed ? .failed : .ok
                        if case .lines(let ranges) = event.ref, !ranges.contains(range) { event.ref = .lines(ranges + [range]) }
                    }
                case "text":
                    if let text = block.txString("text") { texts.append(text) }
                case "image":
                    texts.append("[Image]")
                default:
                    break
                }
            }
        }
        guard !results else { return }
        let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !text.hasPrefix("<local-command-stdout>"), !text.hasPrefix("<local-command-stderr>"),
              !text.hasPrefix("<local-command-caveat>") else { return }
        if text.hasPrefix("[Request interrupted") {
            acc.add(TranscriptEvent(id: uuid, kind: .notice, start: date, title: "Interrupted by user", status: .failed, ref: .lines([range])))
            return
        }
        var title = text
        if let name = TranscriptText.tag("command-name", in: text) {
            title = [name, TranscriptText.tag("command-args", in: text) ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        }
        acc.add(TranscriptEvent(id: uuid, kind: .prompt, start: date, title: TranscriptText.title(title), sidechain: sidechain, ref: .lines([range])))
    }

    private mutating func assistant(_ message: [String: Any]?, uuid: String, date: Date, sidechain: Bool, range: TranscriptByteRange) {
        guard let message else { return }
        if let model = message.txString("model"), model != "<synthetic>" { acc.model = model }
        if let usage = message.txObject("usage") {
            let input = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].reduce(0) { $0 + Int(usage.txNumber($1) ?? 0) }
            acc.token(TranscriptTokens(date: date, input: input, output: Int(usage.txNumber("output_tokens") ?? 0)),
                      key: message.txString("id") ?? uuid)
        }
        for (offset, block) in (message.txObjects("content") ?? []).enumerated() {
            switch block.txString("type") ?? "" {
            case "text":
                guard let text = block.txString("text"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                acc.add(TranscriptEvent(id: "\(uuid)#\(offset)", kind: .answer, start: date, title: TranscriptText.title(text),
                                        sidechain: sidechain, ref: .lines([range])))
            case "thinking", "redacted_thinking":
                let text = block.txString("thinking") ?? ""
                acc.add(TranscriptEvent(id: "\(uuid)#\(offset)", kind: .thinking, start: date,
                                        title: text.isEmpty ? "Thinking" : TranscriptText.title(text), sidechain: sidechain, ref: .lines([range])))
            case "tool_use", "server_tool_use":
                guard let id = block.txString("id") else { continue }
                let (kind, title, subtitle) = Self.classify(block.txString("name") ?? "tool", block.txObject("input") ?? [:])
                // A result that arrived first (a resumed transcript) leaves the call complete.
                if acc.contains(id) { continue }
                acc.add(TranscriptEvent(id: id, kind: kind, start: date, title: title, subtitle: subtitle, status: .running,
                                        sidechain: sidechain, ref: .lines([range])))
            default:
                break
            }
        }
    }

    private mutating func system(_ object: [String: Any], uuid: String, date: Date, range: TranscriptByteRange) {
        switch object.txString("subtype") ?? "" {
        case "compact_boundary":
            acc.add(TranscriptEvent(id: uuid, kind: .compaction, start: date, title: "Context compacted", ref: .lines([range])))
        case "api_error":
            acc.add(TranscriptEvent(id: uuid, kind: .notice, start: date, title: "API error", status: .failed, ref: .lines([range])))
        default:
            guard object.txString("level") == "error" || object.txString("level") == "warning",
                  let content = object.txString("content") else { return }
            acc.add(TranscriptEvent(id: uuid, kind: .notice, start: date, title: TranscriptText.title(content),
                                    status: object.txString("level") == "error" ? .failed : .ok, ref: .lines([range])))
        }
    }

    static func classify(_ name: String, _ input: [String: Any]) -> (TranscriptEventKind, String, String?) {
        if name.hasPrefix("mcp__") {
            let parts = name.dropFirst(5).components(separatedBy: "__")
            let server = parts.first ?? "mcp"
            let tool = parts.dropFirst().joined(separator: "__")
            return (.mcp, tool.isEmpty ? server : "\(server) › \(tool)", TranscriptText.summary(input))
        }
        let path = input.txString("file_path") ?? input.txString("notebook_path") ?? input.txString("path") ?? ""
        switch name {
        case "Bash", "BashOutput", "KillShell", "KillBash":
            return (.command, TranscriptText.title(input.txString("command") ?? input.txString("bash_id") ?? name), input.txString("description"))
        case "Read", "NotebookRead":
            return (.fileRead, "Read " + TranscriptText.basename(path), path)
        case "Grep", "Glob", "LS":
            return (.fileRead, "\(name) " + TranscriptText.title(input.txString("pattern") ?? path, limit: 120), input.txString("path"))
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return (.fileChange, "\(name) " + TranscriptText.basename(path), path)
        case "WebFetch":
            return (.web, "Fetch " + (input.txString("url") ?? ""), input.txString("prompt").map { TranscriptText.title($0, limit: 120) })
        case "WebSearch", "web_search":
            return (.web, "Search " + (input.txString("query") ?? ""), nil)
        case "Task", "Agent":
            return (.subagent, TranscriptText.title(input.txString("description") ?? input.txString("subagent_type") ?? name),
                    input.txString("subagent_type"))
        default:
            return (.tool, name, TranscriptText.summary(input))
        }
    }
}

/// Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Newer versions log `item_completed` items with start and end
/// times; older ones log calls and their outputs. Both are read; the older form is dropped once items appear.
struct CodexTranscriptParser: Sendable {
    var acc = TranscriptAccumulator()
    private var turnStarts: [String: Date] = [:]

    static let ignoredEvents: Set<String> = [
        "thread_settings_applied", "thread_goal_updated", "agent_message_delta", "agent_reasoning_delta",
        "agent_reasoning_raw_content", "agent_reasoning_raw_content_delta", "agent_reasoning_section_break",
        "exec_command_begin", "exec_command_output_delta", "mcp_tool_call_begin", "patch_apply_begin", "web_search_begin",
        "turn_diff", "background_event", "plan_update", "item_started", "raw_response_item", "get_history_entry_response",
        "entered_review_mode", "exited_review_mode", "mcp_list_tools_response", "list_custom_prompts_response",
        "session_configured", "shutdown_complete", "turn_context", "view_image_tool_call", "user_message_delta",
    ]
    static let ignoredLines: Set<String> = ["world_state", "token_usage_record", "inter_agent_communication_metadata"]

    mutating func consume(_ object: [String: Any], range: TranscriptByteRange) {
        let type = object.txString("type") ?? ""
        let payload = object.txObject("payload") ?? [:]
        let date = object.txString("timestamp").flatMap(TranscriptTime.parse)
        switch type {
        case "session_meta":
            if acc.directory == nil { acc.directory = payload.txString("cwd") }
        case "turn_context":
            if let model = payload.txString("model") { acc.model = model }
        case "event_msg":
            if let date { event(payload, date: date, range: range) }
        case "response_item":
            if let date { responseItem(payload, date: date, range: range) }
        case "compacted":
            if let date {
                acc.add(TranscriptEvent(id: "compacted-\(range.offset)", kind: .compaction, start: date, title: "Context compacted", ref: .lines([range])))
            }
        default:
            if !Self.ignoredLines.contains(type) { acc.note(type.isEmpty ? "untyped" : type) }
        }
    }

    private mutating func event(_ payload: [String: Any], date: Date, range: TranscriptByteRange) {
        let kind = payload.txString("type") ?? ""
        let ref = TranscriptRef.lines([range])
        let fallbackID = "\(kind)-\(range.offset)"
        switch kind {
        case "item_completed":
            item(payload, date: date, range: range)
        case "task_started":
            if let id = payload.txString("turn_id") { turnStarts[id] = date }
        case "task_complete", "turn_aborted":
            if let id = payload.txString("turn_id"), let start = turnStarts.removeValue(forKey: id), !acc.turns.contains(where: { $0.id == id }) {
                acc.turns.append(TranscriptTurn(id: id, start: start, end: max(start, date)))
            }
            if kind == "turn_aborted" {
                acc.add(TranscriptEvent(id: fallbackID, kind: .notice, start: date, title: "Turn aborted", status: .failed, ref: ref))
            }
        case "token_count":
            if let usage = payload.txObject("info")?.txObject("last_token_usage") {
                acc.token(TranscriptTokens(date: date, input: Int(usage.txNumber("input_tokens") ?? 0),
                                           output: Int(usage.txNumber("output_tokens") ?? 0)), key: "tokens-\(range.offset)")
            }
        case "error", "stream_error":
            acc.add(TranscriptEvent(id: fallbackID, kind: .notice, start: date,
                                    title: TranscriptText.title(payload.txString("message") ?? "Error"), status: .failed, ref: ref))
        case "context_compacted":
            acc.add(TranscriptEvent(id: fallbackID, kind: .compaction, start: date, title: "Context compacted", ref: ref))
        case "user_message":
            guard let text = payload.txString("message"), !text.isEmpty else { return }
            acc.add(TranscriptEvent(id: fallbackID, kind: .prompt, start: date, title: TranscriptText.title(text), ref: ref), legacy: true)
        case "agent_message":
            guard let text = payload.txString("message"), !text.isEmpty else { return }
            acc.add(TranscriptEvent(id: fallbackID, kind: .answer, start: date, title: TranscriptText.title(text),
                                    subtitle: payload.txString("phase"), ref: ref), legacy: true)
        case "agent_reasoning":
            acc.add(TranscriptEvent(id: fallbackID, kind: .thinking, start: date,
                                    title: TranscriptText.title(payload.txString("text") ?? "Reasoning"), ref: ref), legacy: true)
        case "mcp_tool_call_end":
            let invocation = payload.txObject("invocation") ?? [:]
            let duration = TranscriptTime.seconds(payload["duration"]) ?? 0
            let server = invocation.txString("server") ?? "mcp"
            let failed = (payload.txObject("result")?.txPresent("Err") ?? false)
            acc.add(TranscriptEvent(id: payload.txString("call_id") ?? fallbackID, kind: .mcp, start: date.addingTimeInterval(-duration), end: date,
                                    title: "\(server) › \(invocation.txString("tool") ?? "tool")",
                                    subtitle: (invocation.txObject("arguments")).flatMap(TranscriptText.summary),
                                    status: failed ? .failed : .ok, ref: ref), legacy: true)
        case "patch_apply_end":
            let paths = (payload.txObject("changes") ?? [:]).keys.sorted()
            acc.add(TranscriptEvent(id: payload.txString("call_id").map { $0 + "-patch" } ?? fallbackID, kind: .fileChange, start: date,
                                    title: Self.changeTitle(paths), subtitle: paths.first,
                                    status: payload.txBool("success") == false ? .failed : .ok, ref: ref), legacy: true)
        case "web_search_end":
            acc.add(TranscriptEvent(id: payload.txString("call_id") ?? fallbackID, kind: .web, start: date,
                                    title: "Search " + TranscriptText.title(payload.txString("query") ?? ""), ref: ref), legacy: true)
        case "exec_command_end":
            let id = payload.txString("call_id") ?? fallbackID
            let exit = payload.txNumber("exit_code").map { Int($0) }
            let failed = exit.map { $0 != 0 } ?? false
            let completed = acc.update(id) { event in
                event.end = max(date, event.start)
                event.status = failed ? .failed : .ok
                event.subtitle = exit.map { "exit \($0)" }
            }
            if !completed {
                let duration = TranscriptTime.seconds(payload["duration"]) ?? 0
                acc.add(TranscriptEvent(id: id, kind: .command, start: date.addingTimeInterval(-duration), end: date,
                                        title: TranscriptText.title(Self.command(payload["command"])), subtitle: exit.map { "exit \($0)" },
                                        status: failed ? .failed : .ok, ref: ref), legacy: true)
            }
        case "sub_agent_activity":
            let start = TranscriptTime.milliseconds(payload["occurred_at_ms"]) ?? date
            acc.add(TranscriptEvent(id: payload.txString("event_id") ?? fallbackID, kind: .subagent, start: start,
                                    title: "\(payload.txString("kind") ?? "Activity") \(payload.txString("agent_path") ?? "")", ref: ref), legacy: true)
        default:
            if !Self.ignoredEvents.contains(kind) { acc.note("event_msg:" + kind) }
        }
    }

    private mutating func item(_ payload: [String: Any], date: Date, range: TranscriptByteRange) {
        guard let item = payload.txObject("item") else { return }
        acc.markItems()
        let start = TranscriptTime.milliseconds(payload["started_at_ms"]) ?? date
        var end = max(start, TranscriptTime.milliseconds(payload["completed_at_ms"]) ?? date)
        let type = item.txString("type") ?? ""
        let id = item.txString("id") ?? "\(type)-\(range.offset)"
        let failedStatus = item.txString("status") == "failed"
        var event = TranscriptEvent(id: id, kind: .tool, start: start, end: end, title: type, status: failedStatus ? .failed : .ok, ref: .lines([range]))
        switch type {
        case "UserMessage":
            event.kind = .prompt
            event.end = nil
            event.title = TranscriptText.title(TranscriptText.joined(item["content"]))
        case "AgentMessage":
            event.kind = .answer
            event.title = TranscriptText.title(TranscriptText.joined(item["content"]))
            event.subtitle = item.txString("phase")
        case "Reasoning":
            let summary = (item["summary_text"] as? [String])?.joined(separator: " ") ?? ""
            event.kind = .thinking
            event.title = summary.isEmpty ? "Reasoning" : TranscriptText.title(summary)
        case "CommandExecution":
            if let duration = TranscriptTime.seconds(item["duration"]) { end = max(end, start.addingTimeInterval(duration)) }
            let exit = item.txNumber("exit_code").map { Int($0) }
            event.kind = .command
            event.end = end
            event.title = TranscriptText.title(Self.command(item["command"]))
            event.subtitle = exit.map { "exit \($0)" }
            if exit.map({ $0 != 0 }) ?? false { event.status = .failed }
        case "McpToolCall":
            event.kind = .mcp
            event.title = "\(item.txString("server") ?? "mcp") › \(item.txString("tool") ?? "tool")"
            event.subtitle = item.txObject("arguments").flatMap(TranscriptText.summary)
            if item.txPresent("error") { event.status = .failed }
        case "FileChange":
            let paths = (item.txObject("changes") ?? [:]).keys.sorted()
            event.kind = .fileChange
            event.title = Self.changeTitle(paths)
            event.subtitle = paths.first
        case "Extension":
            let kind = item.txString("kind") ?? "extension"
            if kind.hasPrefix("web") {
                event.kind = .web
                event.title = "Search " + TranscriptText.title(item.txString("query") ?? "")
            } else {
                event.title = kind
            }
        case "SubAgentActivity":
            event.kind = .subagent
            event.title = "Subagent \(item.txString("kind") ?? "activity") \(item.txString("agent_path") ?? "")"
            event.subtitle = item.txString("model")
        case "CollabAgentToolCall":
            event.kind = .subagent
            event.title = "Agents: \(item.txString("tool") ?? "call")"
        case "ContextCompaction":
            event.kind = .compaction
            event.title = "Context compacted"
        case "ImageView":
            event.title = "View image"
            event.subtitle = item.txString("path")
        default:
            acc.note("item:" + type)
        }
        acc.add(event)
    }

    private mutating func responseItem(_ payload: [String: Any], date: Date, range: TranscriptByteRange) {
        let ref = TranscriptRef.lines([range])
        switch payload.txString("type") ?? "" {
        case "function_call":
            let name = payload.txString("name") ?? "tool"
            let id = payload.txString("call_id") ?? "call-\(range.offset)"
            let arguments = payload.txString("arguments")?.data(using: .utf8)
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            var event = TranscriptEvent(id: id, kind: .tool, start: date, title: name, subtitle: TranscriptText.summary(arguments),
                                        status: .running, ref: ref)
            switch name {
            case "exec_command", "shell", "local_shell", "container.exec":
                event.kind = .command
                event.title = TranscriptText.title(Self.command(arguments["cmd"] ?? arguments["command"]))
                event.subtitle = arguments.txString("workdir")
            case "write_stdin", "wait", "sleep", "request_user_input_async":
                return
            case "spawn_agent", "send_message", "wait_agent", "list_agents", "close_agent":
                event.kind = .subagent
                event.title = "Agents: " + name
            default:
                if name.hasPrefix("mcp__") {
                    (event.kind, event.title, event.subtitle) = ClaudeTranscriptParser.classify(name, arguments)
                }
            }
            if !acc.contains(id) { acc.add(event, legacy: true) }
        case "custom_tool_call":
            let name = payload.txString("name") ?? "tool"
            let input = payload.txString("input") ?? ""
            let id = payload.txString("call_id") ?? "custom-\(range.offset)"
            var event = TranscriptEvent(id: id, kind: .tool, start: date, title: name, status: .running, ref: ref)
            if name == "apply_patch" {
                let paths = input.split(separator: "\n").compactMap { line -> String? in
                    for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                        return String(line.dropFirst(prefix.count))
                    }
                    return nil
                }
                event.kind = .fileChange
                event.title = Self.changeTitle(paths)
                event.subtitle = paths.first
            } else {
                event.title = name == "exec" ? "Script" : name
                event.subtitle = TranscriptText.title(input, limit: 120)
            }
            if !acc.contains(id) { acc.add(event, legacy: true) }
        case "function_call_output", "custom_tool_call_output":
            guard let id = payload.txString("call_id") else { return }
            let output = TranscriptText.joined(payload["output"])
            let exit = Self.exitCode(in: output)
            acc.update(id) { event in
                event.end = max(date, event.start)
                event.status = (exit.map { $0 != 0 } ?? false) ? .failed : .ok
                if let exit, event.kind == .command { event.subtitle = "exit \(exit)" }
                if case .lines(let ranges) = event.ref, !ranges.contains(range) { event.ref = .lines(ranges + [range]) }
            }
        case "web_search_call":
            let query = payload.txObject("action")?.txString("query") ?? ""
            acc.add(TranscriptEvent(id: payload.txString("id") ?? "search-\(range.offset)", kind: .web, start: date,
                                    title: "Search " + TranscriptText.title(query), ref: ref), legacy: true)
        default:
            break
        }
    }

    static func command(_ value: Any?) -> String {
        if let parts = value as? [String] {
            if parts.count >= 3, ["-lc", "-c"].contains(parts[1]) { return parts[2] }
            return parts.joined(separator: " ")
        }
        return value as? String ?? ""
    }

    static func changeTitle(_ paths: [String]) -> String {
        guard let first = paths.first else { return "Patch" }
        return "Edit " + TranscriptText.basename(first) + (paths.count > 1 ? " +\(paths.count - 1)" : "")
    }

    /// `Process exited with code 1` in older Codex command output.
    static func exitCode(in output: String) -> Int? {
        guard let range = output.prefix(400).range(of: "exited with code ") else { return nil }
        return Int(output[range.upperBound...].prefix { $0.isNumber || $0 == "-" })
    }
}

/// OpenCode: rows of `session_message` in `~/.local/share/opencode/opencode.db`. Assistant rows are rewritten while
/// they stream, so a row read again replaces every event it produced before.
struct OpenCodeTranscriptParser: Sendable {
    var acc = TranscriptAccumulator()
    private var produced: [String: Set<String>] = [:]

    static let builtins: Set<String> = ["todowrite", "todoread", "skill", "question", "invalid", "lsp_diagnostics", "lsp_hover", "batch"]

    mutating func consume(id: String, type: String, created: Date, data: Data) {
        if let previous = produced.removeValue(forKey: id) { acc.remove(previous) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let start = TranscriptTime.milliseconds(object.txObject("time")?["created"]) ?? created
        let ref = TranscriptRef.openCode(messageID: id, part: nil)
        var events: [TranscriptEvent] = []
        switch type {
        case "user":
            let text = object.txString("text") ?? ""
            if !text.isEmpty { events.append(TranscriptEvent(id: id, kind: .prompt, start: start, title: TranscriptText.title(text), ref: ref)) }
        case "assistant":
            events = assistant(object, id: id, start: start)
        case "compaction":
            events.append(TranscriptEvent(id: id, kind: .compaction, start: start, title: "Context compacted", ref: ref))
        case "idle":
            if object.txString("outcome") == "failed" {
                let message = object.txObject("error")?.txString("message") ?? "Turn failed"
                events.append(TranscriptEvent(id: id, kind: .notice, start: start, title: TranscriptText.title(message), status: .failed, ref: ref))
            }
        case "agent-switched":
            events.append(TranscriptEvent(id: id, kind: .notice, start: start, title: "Agent: " + (object.txString("agent") ?? "?"), ref: ref))
        case "model-switched":
            events.append(TranscriptEvent(id: id, kind: .notice, start: start,
                                          title: "Model: " + (object.txObject("model")?.txString("id") ?? "?"), ref: ref))
        case "location-switched":
            events.append(TranscriptEvent(id: id, kind: .notice, start: start, title: "Location changed", ref: ref))
        case "system", "synthetic":
            break
        default:
            acc.note(type)
        }
        for event in events { acc.add(event) }
        if !events.isEmpty { produced[id] = Set(events.map(\.id)) }
    }

    /// Tokens and model are recorded here; the events are returned for the caller to add.
    private mutating func assistant(_ object: [String: Any], id: String, start: Date) -> [TranscriptEvent] {
        let completed = TranscriptTime.milliseconds(object.txObject("time")?["completed"])
        if let model = object.txObject("model")?.txString("id") { acc.model = model }
        if let tokens = object.txObject("tokens") {
            let cache = tokens.txObject("cache")
            let input = Int(tokens.txNumber("input") ?? 0) + Int(cache?.txNumber("read") ?? 0) + Int(cache?.txNumber("write") ?? 0)
            let output = Int(tokens.txNumber("output") ?? 0) + Int(tokens.txNumber("reasoning") ?? 0)
            if input + output > 0 { acc.token(TranscriptTokens(date: completed ?? start, input: input, output: output), key: id) }
        }
        var events: [TranscriptEvent] = []
        if object.txString("finish") == "error", let error = object.txObject("error") {
            events.append(TranscriptEvent(id: id + "#error", kind: .notice, start: completed ?? start,
                                          title: TranscriptText.title(error.txString("message") ?? "Error"), status: .failed,
                                          ref: .openCode(messageID: id, part: nil)))
        }
        for (offset, part) in (object.txObjects("content") ?? []).enumerated() {
            let partTime = part.txObject("time")
            let partStart = TranscriptTime.milliseconds(partTime?["created"]) ?? start
            let partEnd = TranscriptTime.milliseconds(partTime?["completed"])
            let ref = TranscriptRef.openCode(messageID: id, part: offset)
            switch part.txString("type") ?? "" {
            case "text":
                let text = part.txString("text") ?? ""
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                events.append(TranscriptEvent(id: "\(id)#\(offset)", kind: .answer, start: partStart, end: partEnd ?? completed,
                                              title: TranscriptText.title(text), ref: ref))
            case "reasoning":
                let text = part.txString("text") ?? ""
                events.append(TranscriptEvent(id: "\(id)#\(offset)", kind: .thinking, start: partStart, end: partEnd,
                                              title: text.isEmpty ? "Reasoning" : TranscriptText.title(text), ref: ref))
            case "tool":
                let state = part.txObject("state") ?? [:]
                let (kind, title, subtitle) = Self.classify(part.txString("name") ?? "tool", state.txObject("input") ?? [:])
                let exit = state.txObject("metadata")?.txNumber("exit").map { Int($0) }
                var status = TranscriptEventStatus.ok
                switch state.txString("status") ?? "" {
                case "error": status = .failed
                case "running", "pending": status = .running
                default: if let exit, exit != 0 { status = .failed }
                }
                let detail = kind == .command ? (exit.map { "exit \($0)" } ?? subtitle) : subtitle
                events.append(TranscriptEvent(id: part.txString("id") ?? "\(id)#\(offset)", kind: kind, start: partStart,
                                              end: status == .running ? nil : (partEnd ?? completed), title: title, subtitle: detail,
                                              status: status, ref: ref))
            default:
                break
            }
        }
        return events
    }

    static func classify(_ name: String, _ input: [String: Any]) -> (TranscriptEventKind, String, String?) {
        let path = input.txString("filePath") ?? input.txString("file_path") ?? input.txString("path") ?? ""
        switch name {
        case "bash", "shell", "execute":
            return (.command, TranscriptText.title(input.txString("command") ?? name), input.txString("description"))
        case "read":
            return (.fileRead, "Read " + TranscriptText.basename(path), path)
        case "glob", "grep", "list", "ls", "codesearch":
            return (.fileRead, "\(name) " + TranscriptText.title(input.txString("pattern") ?? path, limit: 120), input.txString("path"))
        case "write", "edit", "patch", "multiedit", "apply_patch":
            return (.fileChange, "\(name.prefix(1).uppercased() + name.dropFirst()) " + TranscriptText.basename(path), path)
        case "webfetch":
            return (.web, "Fetch " + (input.txString("url") ?? ""), nil)
        case "websearch":
            return (.web, "Search " + (input.txString("query") ?? ""), nil)
        case "task":
            return (.subagent, TranscriptText.title(input.txString("description") ?? "Subagent"), input.txString("subagent_type"))
        default:
            // OpenCode names MCP tools `<server>_<tool>`; its own tools have no underscore.
            if !builtins.contains(name), !name.contains("."), let separator = name.firstIndex(of: "_"),
               separator != name.startIndex, name.index(after: separator) != name.endIndex {
                return (.mcp, "\(name[..<separator]) › \(name[name.index(after: separator)...])", TranscriptText.summary(input))
            }
            return (.tool, name, TranscriptText.summary(input))
        }
    }
}
