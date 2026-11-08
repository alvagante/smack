import Foundation
import SQLite3
import Synchronization
import Testing
@testable import Smack

/// An in-memory file system that counts what is read.
final class MemoryTranscriptFiles: TranscriptFileAccess, Sendable {
    struct State: Sendable {
        var files: [String: Data] = [:]
        var reads = 0
        var bytesRead = 0
    }
    let state = Mutex(State())

    func set(_ path: String, _ text: String) { state.withLock { $0.files[path] = Data(text.utf8) } }
    func append(_ path: String, _ text: String) { state.withLock { $0.files[path, default: Data()].append(Data(text.utf8)) } }
    var reads: Int { state.withLock { $0.reads } }
    var bytesRead: Int { state.withLock { $0.bytesRead } }

    func size(of path: String) -> UInt64? {
        state.withLock { $0.files[path].map { UInt64($0.count) } }
    }

    func read(_ path: String, offset: UInt64, length: Int) -> Data? {
        state.withLock { state in
            guard let data = state.files[path], offset <= UInt64(data.count) else { return nil }
            let start = Int(offset)
            let end = min(start + length, data.count)
            state.reads += 1
            state.bytesRead += end - start
            return data.subdata(in: start..<end)
        }
    }
}

private func at(_ text: String) -> Date { TranscriptTime.parse(text)! }

private func lines(_ values: [String]) -> String { values.joined(separator: "\n") + "\n" }

private func index(_ text: String, format: TranscriptFormat) -> TranscriptIndex {
    let files = MemoryTranscriptFiles()
    files.set("/t.jsonl", text)
    var tail = TranscriptFileTail(path: "/t.jsonl", format: format)
    _ = tail.advance(using: files)
    return tail.index
}

// MARK: - Fixtures. Shapes follow real transcripts; content is invented.

let claudeTranscript = lines([
    #"{"type":"summary","summary":"Fix the login bug","leafUuid":"a5"}"#,
    #"{"type":"user","uuid":"u1","sessionId":"s","cwd":"/work/app","timestamp":"2026-11-01T10:00:00.000Z","message":{"role":"user","content":"Fix the login bug"}}"#,
    #"{"type":"user","uuid":"meta","isMeta":true,"timestamp":"2026-11-01T10:00:00.100Z","message":{"role":"user","content":"<local-command-caveat>Caveat</local-command-caveat>"}}"#,
    #"{"type":"assistant","uuid":"a1","timestamp":"2026-11-01T10:00:02.000Z","message":{"id":"msg_1","model":"claude-opus-5-5","role":"assistant","content":[{"type":"thinking","thinking":"Look at auth first"}],"usage":{"input_tokens":10,"cache_read_input_tokens":90,"output_tokens":5}}}"#,
    #"{"type":"assistant","uuid":"a2","timestamp":"2026-11-01T10:00:03.000Z","message":{"id":"msg_1","model":"claude-opus-5-5","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"npm test","description":"Run tests"}}],"usage":{"input_tokens":10,"cache_read_input_tokens":90,"output_tokens":40}}}"#,
    #"{"type":"user","uuid":"r1","timestamp":"2026-11-01T10:00:08.500Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"1 failing","is_error":true}]}}"#,
    #"{"type":"assistant","uuid":"a3","timestamp":"2026-11-01T10:00:09.000Z","message":{"id":"msg_2","role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"mcp__github__create_issue","input":{"title":"Login"}}]}}"#,
    #"{"type":"user","uuid":"r2","timestamp":"2026-11-01T10:00:10.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":[{"type":"text","text":"created #4"}]}]}}"#,
    #"{"type":"assistant","uuid":"a4","timestamp":"2026-11-01T10:00:11.000Z","message":{"id":"msg_3","role":"assistant","content":[{"type":"tool_use","id":"toolu_3","name":"Task","input":{"description":"Explore auth","subagent_type":"Explore","prompt":"Find the bug"}}]}}"#,
    #"{"type":"assistant","uuid":"s1","isSidechain":true,"timestamp":"2026-11-01T10:00:12.000Z","message":{"id":"msg_4","role":"assistant","content":[{"type":"tool_use","id":"toolu_4","name":"Read","input":{"file_path":"/work/app/auth.ts"}}]}}"#,
    #"{"type":"user","uuid":"r4","isSidechain":true,"timestamp":"2026-11-01T10:00:12.200Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_4","content":"export function login() {}"}]}}"#,
    #"{"type":"user","uuid":"r3","timestamp":"2026-11-01T10:00:20.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_3","content":"found it"}]}}"#,
    #"{"type":"assistant","uuid":"a5","timestamp":"2026-11-01T10:00:21.000Z","message":{"id":"msg_5","role":"assistant","content":[{"type":"text","text":"Fixed the login bug."}]}}"#,
    #"{"type":"user","uuid":"u2","timestamp":"2026-11-01T10:05:00.000Z","message":{"role":"user","content":"<command-name>/compact</command-name>\n<command-args>keep auth</command-args>"}}"#,
    #"{"type":"file-history-snapshot","messageId":"x"}"#,
    #"{"type":"mystery"}"#,
])

let codexTranscript = lines([
    #"{"timestamp":"2026-11-01T18:31:14.422Z","type":"session_meta","payload":{"id":"t1","cwd":"/work/app","cli_version":"0.166.0","base_instructions":{"text":"You are Codex."}}}"#,
    #"{"timestamp":"2026-11-01T18:31:14.423Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn1","started_at":1793557874}}"#,
    #"{"timestamp":"2026-11-01T18:31:14.500Z","type":"turn_context","payload":{"model":"gpt-6","cwd":"/work/app"}}"#,
    #"{"timestamp":"2026-11-01T18:31:18.062Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"t1","turn_id":"turn1","item":{"type":"UserMessage","id":"um1","content":[{"type":"text","text":"implement phase 1"}]},"started_at_ms":1793557878061,"completed_at_ms":1793557878062}}"#,
    #"{"timestamp":"2026-11-01T18:31:18.100Z","type":"event_msg","payload":{"type":"user_message","message":"implement phase 1"}}"#,
    #"{"timestamp":"2026-11-01T18:31:21.040Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"t1","turn_id":"turn1","item":{"type":"AgentMessage","id":"am1","content":[{"type":"Text","text":"Reading phase 1 first."}],"phase":"commentary"},"started_at_ms":1793557880497,"completed_at_ms":1793557881040}}"#,
    #"{"timestamp":"2026-11-01T18:31:21.985Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"git status\"}","call_id":"call_x"}}"#,
    #"{"timestamp":"2026-11-01T18:31:22.316Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"t1","turn_id":"turn1","item":{"type":"CommandExecution","id":"exec-1","command":["/bin/bash","-lc","swift test"],"cwd":"file:///work/app","status":"failed","exit_code":1,"aggregated_output":"error: 1 failure","duration":{"secs":4,"nanos":500000000}},"started_at_ms":1793557882000,"completed_at_ms":1793557882100}}"#,
    #"{"timestamp":"2026-11-01T18:31:30.000Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"t1","turn_id":"turn1","item":{"type":"McpToolCall","id":"exec-2","server":"context7","tool":"query-docs","arguments":{"query":"tart exec"},"status":"completed","result":{"content":[{"type":"text","text":"docs"}]}},"started_at_ms":1793557888000,"completed_at_ms":1793557890000}}"#,
    #"{"timestamp":"2026-11-01T18:31:31.000Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"t1","turn_id":"turn1","item":{"type":"FileChange","id":"exec-3","changes":{"/work/app/a.swift":{"type":"update","unified_diff":"@@ -1 +1 @@\n-old\n+new"},"/work/app/b.swift":{"type":"add","content":"x"}},"status":"completed"},"started_at_ms":1793557891000,"completed_at_ms":1793557891050}}"#,
    #"{"timestamp":"2026-11-01T18:31:32.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20411,"output_tokens":106}}}}"#,
    #"{"timestamp":"2026-11-01T18:39:27.809Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn1","last_agent_message":"done"}}"#,
    #"{"timestamp":"2026-11-01T18:39:28.000Z","type":"world_state","payload":{}}"#,
])

let codexLegacyTranscript = lines([
    #"{"timestamp":"2026-06-25T06:00:00.000Z","type":"session_meta","payload":{"cwd":"/work/old"}}"#,
    #"{"timestamp":"2026-06-25T06:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"! git pull"}}"#,
    #"{"timestamp":"2026-06-25T06:00:02.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"git pull\",\"workdir\":\"/work/old\"}","call_id":"call_1"}}"#,
    #"{"timestamp":"2026-06-25T06:00:05.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"Chunk ID: 1\nWall time: 3 seconds\nProcess exited with code 128\nOutput:\nfatal"}}"#,
    #"{"timestamp":"2026-06-25T06:00:06.000Z","type":"event_msg","payload":{"type":"mcp_tool_call_end","call_id":"call_2","invocation":{"server":"context7","tool":"resolve-library-id","arguments":{"libraryName":"Ansible"}},"duration":{"secs":1,"nanos":500000000},"result":{"Ok":{"content":[]}}}}"#,
    #"{"timestamp":"2026-06-25T06:00:07.000Z","type":"event_msg","payload":{"type":"patch_apply_end","call_id":"call_3","success":true,"changes":{"/work/old/site.yml":{"type":"add","content":"---"}}}}"#,
    #"{"timestamp":"2026-06-25T06:00:08.000Z","type":"event_msg","payload":{"type":"web_search_end","call_id":"ws_1","query":"tart cli"}}"#,
    #"{"timestamp":"2026-06-25T06:00:09.000Z","type":"event_msg","payload":{"type":"agent_message","message":"Pulled.","phase":"final"}}"#,
])

// MARK: - Parsing

@Test func transcriptTimesParseWithoutAFormatter() {
    #expect(abs(at("2026-11-01T18:31:14.422Z").timeIntervalSince1970 - 1_793_557_874.422) < 0.0005)
    #expect(at("2026-11-01T18:31:14Z").timeIntervalSince1970 == 1_793_557_874)
    #expect(at("2026-11-01T19:31:14+01:00").timeIntervalSince1970 == 1_793_557_874)
    #expect(at("2000-02-29T00:00:00Z").timeIntervalSince1970 == 951_782_400)
    #expect(TranscriptTime.parse("yesterday") == nil)
    #expect(TranscriptTime.milliseconds(1_793_557_878_061 as NSNumber)?.timeIntervalSince1970 == 1_793_557_878.061)
}

@Test func claudeTranscriptPairsCallsWithResultsAndSortsEventsIntoLanes() throws {
    let index = index(claudeTranscript, format: .claude)
    #expect(index.directory == "/work/app")
    #expect(index.model == "claude-opus-5-5")
    #expect(index.title == "Fix the login bug")
    #expect(index.events.filter { $0.kind == .prompt }.map(\.title) == ["Fix the login bug", "/compact keep auth"])

    let command = try #require(index.events.first { $0.id == "toolu_1" })
    #expect(command.kind == .command && command.lane == .commands)
    #expect(command.title == "npm test" && command.subtitle == "Run tests")
    #expect(command.status == .failed)
    #expect(command.duration == 5.5)

    let mcp = try #require(index.events.first { $0.id == "toolu_2" })
    #expect(mcp.kind == .mcp && mcp.title == "github › create_issue" && mcp.status == .ok)

    let task = try #require(index.events.first { $0.id == "toolu_3" })
    #expect(task.kind == .subagent && task.title == "Explore auth" && task.duration == 9)

    let sidechain = try #require(index.events.first { $0.id == "toolu_4" })
    #expect(sidechain.kind == .fileRead && sidechain.lane == .subagents)

    #expect(index.events.contains { $0.kind == .thinking && $0.title == "Look at auth first" })
    #expect(index.events.contains { $0.kind == .answer && $0.title == "Fixed the login bug." })
    // One message logged twice counts its tokens once.
    #expect(index.tokens.count == 1 && index.outputTokens == 40 && index.inputTokens == 100)
    #expect(index.turns.count == 2)
    #expect(index.turns.first?.end == at("2026-11-01T10:05:00Z"))
    #expect(index.unrecognized == ["mystery": 1])
    #expect(index.events.map(\.start) == index.events.map(\.start).sorted())
}

@Test func codexItemsWinOverTheOlderFormInTheSameRollout() throws {
    let index = index(codexTranscript, format: .codex)
    #expect(index.directory == "/work/app" && index.model == "gpt-6")
    #expect(index.events.filter { $0.kind == .prompt }.count == 1)
    #expect(!index.events.contains { $0.id == "call_x" })

    let command = try #require(index.events.first { $0.id == "exec-1" })
    #expect(command.title == "swift test" && command.subtitle == "exit 1" && command.status == .failed)
    #expect(command.start.timeIntervalSince1970 == 1_793_557_882)
    #expect(command.duration == 4.5)

    let mcp = try #require(index.events.first { $0.id == "exec-2" })
    #expect(mcp.title == "context7 › query-docs" && mcp.duration == 2)
    #expect(index.events.first { $0.id == "exec-3" }?.title == "Edit a.swift +1")
    #expect(index.events.first { $0.id == "am1" }?.subtitle == "commentary")
    #expect(index.outputTokens == 106)
    #expect(index.turns == [TranscriptTurn(id: "turn1", start: at("2026-11-01T18:31:14.423Z"), end: at("2026-11-01T18:39:27.809Z"))])
    #expect(index.unrecognized.isEmpty)
}

@Test func codexOlderRolloutsPairCallsAndOutputs() throws {
    let index = index(codexLegacyTranscript, format: .codex)
    #expect(index.directory == "/work/old")
    #expect(index.title == "! git pull")
    let command = try #require(index.events.first { $0.id == "call_1" })
    #expect(command.title == "git pull" && command.status == .failed && command.subtitle == "exit 128" && command.duration == 3)
    let mcp = try #require(index.events.first { $0.id == "call_2" })
    #expect(mcp.duration == 1.5 && mcp.title == "context7 › resolve-library-id")
    #expect(index.events.contains { $0.kind == .fileChange && $0.title == "Edit site.yml" })
    #expect(index.events.contains { $0.kind == .web && $0.title == "Search tart cli" })
    #expect(index.events.contains { $0.kind == .answer && $0.title == "Pulled." && $0.subtitle == "final" })
}

@Test func transcriptsReadInPiecesMatchOneRead() {
    let whole = index(claudeTranscript, format: .claude)
    let files = MemoryTranscriptFiles()
    var tail = TranscriptFileTail(path: "/t.jsonl", format: .claude)
    let bytes = Array(claudeTranscript.utf8)
    var cut = 0
    // Cuts fall inside lines, so partial lines must wait for the rest.
    for size in [37, 211, 5, 400, 1_000, 3, 10_000] where cut < bytes.count {
        let next = min(cut + size, bytes.count)
        files.append("/t.jsonl", String(decoding: bytes[cut..<next], as: UTF8.self))
        _ = tail.advance(using: files)
        cut = next
    }
    #expect(tail.index == whole)
}

@Test func aTranscriptThatShrankIsReadAgain() {
    let files = MemoryTranscriptFiles()
    files.set("/t.jsonl", claudeTranscript)
    var tail = TranscriptFileTail(path: "/t.jsonl", format: .claude)
    _ = tail.advance(using: files)
    let first = lines(Array(claudeTranscript.split(separator: "\n").prefix(2).map(String.init)))
    files.set("/t.jsonl", first)
    let rereadAfterShrink = tail.advance(using: files)
    #expect(rereadAfterShrink)
    #expect(tail.index.events.map(\.id) == ["u1"])
}

@Test func detailsAreReadFromTheEventsLines() throws {
    let files = MemoryTranscriptFiles()
    files.set("/c.jsonl", claudeTranscript)
    files.set("/x.jsonl", codexTranscript)
    var claude = TranscriptFileTail(path: "/c.jsonl", format: .claude)
    _ = claude.advance(using: files)
    let command = try #require(claude.index.events.first { $0.id == "toolu_1" })
    let detail = TranscriptDetailReader.read(command, source: .file(path: "/c.jsonl", format: .claude), files: files)
    #expect(detail.sections.first { $0.title == "Command" }?.body == "npm test")
    #expect(detail.sections.first { $0.title == "Error" }?.body == "1 failing")

    var codex = TranscriptFileTail(path: "/x.jsonl", format: .codex)
    _ = codex.advance(using: files)
    let change = try #require(codex.index.events.first { $0.id == "exec-3" })
    let diff = TranscriptDetailReader.read(change, source: .file(path: "/x.jsonl", format: .codex), files: files)
    #expect(diff.sections.map(\.title) == ["/work/app/a.swift", "/work/app/b.swift"])
    #expect(diff.sections.allSatisfy { $0.style == .diff })
    #expect(diff.sections.last?.body == "+x")
}

@Test func detailSectionsAreBounded() {
    var detail = TranscriptDetail()
    detail.add("Output", String(repeating: "a", count: TranscriptDetail.sectionLimit * 2), .code)
    #expect(detail.truncated)
    #expect(detail.sections[0].body.utf8.count <= TranscriptDetail.sectionLimit + 4)
    detail.add("Empty", "  \n ")
    #expect(detail.sections.count == 1)
}

// MARK: - OpenCode

private func makeOpenCodeDatabase(_ extra: String = "") throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("smack-opencode-\(UUID().uuidString).db").path
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    defer { sqlite3_close(db) }
    let sql = """
        CREATE TABLE session_v2 (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT NOT NULL, title TEXT,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER);
        CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
        CREATE TABLE credential (id TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT INTO credential VALUES ('c', 'SECRET');
        INSERT INTO session_v2 VALUES ('ses_1', NULL, '/work/app', 'Fix login', 1793557870000, 1793557900000, NULL);
        INSERT INTO session_v2 VALUES ('ses_child', 'ses_1', '/work/app', 'Subagent', 1793557880000, 1793557999000, NULL);
        INSERT INTO session_message VALUES ('m1', 'ses_1', 'user', 1, 1793557871000, 1793557871000,
            '{"time":{"created":1793557871000},"text":"Fix the login"}');
        INSERT INTO session_message VALUES ('m2', 'ses_1', 'assistant', 2, 1793557872000, 1793557880000,
            '{"time":{"created":1793557872000,"completed":1793557880000},"model":{"id":"deepseek"},"content":[{"type":"text","text":"Looking"},{"type":"tool","id":"call_a","name":"bash","state":{"status":"completed","input":{"command":"npm test"},"metadata":{"exit":2}},"time":{"created":1793557873000,"completed":1793557875000}},{"type":"tool","id":"call_b","name":"context7_query-docs","state":{"status":"completed","input":{"query":"x"}},"time":{"created":1793557876000,"completed":1793557877000}}],"tokens":{"input":100,"output":20,"reasoning":5,"cache":{"read":50,"write":0}}}');
        \(extra)
        """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    return path
}

private func execute(_ path: String, _ sql: String) {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return }
    defer { sqlite3_close(db) }
    sqlite3_exec(db, sql, nil, nil, nil)
}

@Test func openCodeSessionsAreReadIncrementallyAndRewrittenRowsReplaceTheirEvents() throws {
    let path = try makeOpenCodeDatabase()
    defer { try? FileManager.default.removeItem(atPath: path) }
    var tail = OpenCodeTranscriptTail(database: OpenCodeDatabase(path: path), session: "ses_1")
    let initialAdvance = tail.advance()
    #expect(initialAdvance)
    var index = tail.index
    #expect(index.events.map(\.kind) == [.prompt, .answer, .command, .mcp])
    let command = try #require(index.events.first { $0.id == "call_a" })
    #expect(command.title == "npm test" && command.subtitle == "exit 2" && command.status == .failed && command.duration == 2)
    #expect(index.events.first { $0.id == "call_b" }?.title == "context7 › query-docs")
    #expect(index.inputTokens == 150 && index.outputTokens == 25 && index.model == "deepseek")
    let unchanged = !tail.advance()
    #expect(unchanged, "nothing changed")

    // The assistant row streams on: it is rewritten with one more part.
    execute(path, """
        UPDATE session_message SET time_updated = 1793557890000, data =
        '{"time":{"created":1793557872000,"completed":1793557890000},"content":[{"type":"text","text":"Looking"},{"type":"tool","id":"call_a","name":"bash","state":{"status":"completed","input":{"command":"npm test"},"metadata":{"exit":0}},"time":{"created":1793557873000,"completed":1793557875000}},{"type":"text","text":"All green"}]}'
        WHERE id = 'm2';
        """)
    let updated = tail.advance()
    #expect(updated)
    index = tail.index
    #expect(index.events.filter { $0.id == "call_a" }.count == 1)
    #expect(index.events.first { $0.id == "call_a" }?.status == .ok)
    #expect(!index.events.contains { $0.id == "call_b" })
    #expect(index.events.contains { $0.title == "All green" })
}

@Test func openCodeQueriesTouchOnlySessionTables() throws {
    for sql in OpenCodeDatabase.statements {
        let lower = sql.lowercased()
        #expect(!lower.contains("credential") && !lower.contains("account") && !lower.contains("kv"))
        #expect(lower.contains("session_v2") || lower.contains("session_message"))
    }
    let path = try makeOpenCodeDatabase()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let database = OpenCodeDatabase(path: path)
    // Subagent sessions are children; the live process belongs to the top-level one.
    #expect(database.liveSession(directory: "/work/app", since: Date(timeIntervalSince1970: 1_793_557_800)) == "ses_1")
    #expect(database.liveSession(directory: "/elsewhere", since: .distantPast) == nil)
    #expect(database.recent(limit: 10).map(\.id) == ["ses_1"])
}

// MARK: - Finding transcripts

private func temporaryHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("smack-transcripts-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func write(_ text: String, to url: URL, modified: Date) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
}

@Test func catalogListsEveryAgentNewestFirstAndCountsCompressedRollouts() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let now = Date()
    try write(claudeTranscript, to: home.appendingPathComponent(".claude/projects/-work-app/s1.jsonl"), modified: now.addingTimeInterval(-60))
    try write(claudeTranscript, to: home.appendingPathComponent(".claude/projects/-work-app/agent-1.jsonl"), modified: now)
    try write(codexTranscript, to: home.appendingPathComponent(".codex/sessions/2026/11/01/rollout-a.jsonl"), modified: now.addingTimeInterval(-30))
    try write("compressed", to: home.appendingPathComponent(".codex/sessions/2026/11/01/rollout-b.jsonl.zst"), modified: now)
    let database = try makeOpenCodeDatabase()
    let target = home.appendingPathComponent(".local/share/opencode/opencode.db")
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(atPath: database, toPath: target.path)

    let result = TranscriptCatalog(home: home).recent(limit: 10)
    #expect(result.items.map(\.agentID) == ["codex", "claude", "opencode"])
    #expect(result.compressed == 1)
    let claude = try #require(result.items.first { $0.agentID == "claude" })
    #expect(claude.title == "Fix the login bug" && claude.directory == "/work/app" && claude.projectName == "app")
    #expect(result.items.first { $0.agentID == "codex" }?.title == "implement phase 1")
    #expect(result.items.first { $0.agentID == "opencode" }?.title == "Fix login")
    #expect(TranscriptCatalog(home: home).recent(limit: 1).items.count == 1)
}

@Test func codexSessionsMatchTheirRolloutByProjectDirectory() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let now = Date()
    let folder = TranscriptLocator.dayFolder(home.appendingPathComponent(".codex/sessions"), now, .current)
    try write(codexTranscript, to: folder.appendingPathComponent("rollout-mine.jsonl"), modified: now.addingTimeInterval(-10))
    try write(codexTranscript.replacingOccurrences(of: "/work/app", with: "/work/other"),
              to: folder.appendingPathComponent("rollout-other.jsonl"), modified: now)
    var session = AgentSession(agentID: "codex", root: ProcessIdentity(pid: 42, startTime: now.addingTimeInterval(-60)), startedAt: now.addingTimeInterval(-60))
    session.project = ProjectContext(directory: "/work/app", root: nil, name: "app", kind: nil, git: nil)
    let source = TranscriptLocator(home: home).source(for: session)
    guard case .file(let path, let format) = source else { Issue.record("the matching rollout is selected"); return }
    #expect(format == .codex)
    #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath() ==
            folder.appendingPathComponent("rollout-mine.jsonl").resolvingSymlinksInPath())
    session.project?.directory = "/work/none"
    #expect(TranscriptLocator(home: home).source(for: session) == nil)
    #expect(TranscriptLocator.codexDirectory(Data(#"{"payload":{"cwd":"/a \"b\"/c"}}"#.utf8)) == #"/a "b"/c"#)
}

// MARK: - Viewport and layout

private let epoch = Date(timeIntervalSince1970: 1_000_000)

@Test func zoomKeepsTheAnchorStillAndStaysInsideTheSession() {
    var viewport = TimelineViewport(domain: epoch...epoch.addingTimeInterval(100))
    let anchor = epoch.addingTimeInterval(25)
    let before = viewport.x(anchor, width: 1000)
    viewport.zoom(by: 2, anchor: anchor)
    #expect(abs(viewport.span - 50) < 0.0001)
    #expect(abs(viewport.x(anchor, width: 1000) - before) < 0.001)
    viewport.zoom(by: 1_000_000, anchor: anchor)
    #expect(abs(viewport.span - TimelineViewport.minimumSpan) < 0.000_01)
    viewport.pan(by: -1_000)
    #expect(viewport.visible.lowerBound == epoch)
    viewport.zoom(by: 0.000001, anchor: anchor)
    #expect(viewport.isFit)
}

@Test func liveDomainsGrowAndAFollowingWindowKeepsItsEnd() {
    var fit = TimelineViewport(domain: epoch...epoch.addingTimeInterval(100))
    fit.update(domain: epoch...epoch.addingTimeInterval(200), follow: true)
    #expect(fit.isFit)

    var following = fit
    following.show(epoch.addingTimeInterval(180)...epoch.addingTimeInterval(200))
    #expect(following.isAtEnd)
    following.update(domain: epoch...epoch.addingTimeInterval(260), follow: true)
    #expect(following.visible == epoch.addingTimeInterval(240)...epoch.addingTimeInterval(260))

    var reading = fit
    reading.show(epoch.addingTimeInterval(10)...epoch.addingTimeInterval(30))
    reading.update(domain: epoch...epoch.addingTimeInterval(260), follow: true)
    #expect(reading.visible == epoch.addingTimeInterval(10)...epoch.addingTimeInterval(30))

    let from = TimelineViewport(domain: epoch...epoch.addingTimeInterval(100))
    #expect(TimelineViewport.blend(from, reading, progress: 0).visible == from.visible)
    #expect(TimelineViewport.blend(from, reading, progress: 1).visible == reading.visible)
}

@Test func ticksAlignToTheClockAtAReadableSpacing() {
    #expect(TimelineTicks.step(span: 3600, width: 900) == 600)
    let utc = TimeZone(identifier: "UTC")!
    let ticks = TimelineTicks.ticks(in: at("2026-11-01T10:00:07Z")...at("2026-11-01T10:00:31Z"), step: 10, timeZone: utc)
    #expect(ticks == [at("2026-11-01T10:00:10Z"), at("2026-11-01T10:00:20Z"), at("2026-11-01T10:00:30Z")])
}

private func event(_ id: String, _ kind: TranscriptEventKind, _ start: TimeInterval, _ end: TimeInterval? = nil,
                   status: TranscriptEventStatus = .ok) -> TranscriptEvent {
    TranscriptEvent(id: id, kind: kind, start: epoch.addingTimeInterval(start), end: end.map { epoch.addingTimeInterval($0) },
                    title: id, status: status)
}

@Test func layoutStacksOverlapsClustersCrowdsAndHitTests() throws {
    let viewport = TimelineViewport(domain: epoch...epoch.addingTimeInterval(100))
    let overlapping = [event("a", .command, 10, 50), event("b", .command, 20, 40)]
    let stacked = TimelineLayout.build(events: overlapping, lanes: [.commands], viewport: viewport, width: 1000, now: epoch)
    #expect(stacked.lanes.first?.rows == 2)
    #expect(Set(stacked.items.map(\.row)) == [0, 1])
    let a = try #require(stacked.items.first { $0.id == "a" })
    #expect(stacked.item(at: CGPoint(x: stacked.frame(of: a).midX, y: stacked.frame(of: a).midY))?.id == "a")

    // 200 prompts 0.1 s apart are 1 point apart at this zoom: they become clusters, and no event is lost.
    let crowd = (0..<200).map { event("p\($0)", .prompt, 10 + Double($0) / 10) }
    let clustered = TimelineLayout.build(events: crowd, lanes: [.prompts], viewport: viewport, width: 1000, now: epoch)
    #expect(clustered.items.count < 20)
    #expect(clustered.items.reduce(0) { $0 + $1.count } == 200)
    var zoomed = viewport
    zoomed.show(epoch.addingTimeInterval(10)...epoch.addingTimeInterval(12))
    let spread = TimelineLayout.build(events: crowd, lanes: [.prompts], viewport: zoomed, width: 1000, now: epoch)
    #expect(spread.items.filter { !$0.isCluster }.count > 10)

    // A running call is drawn up to now.
    let running = TimelineLayout.build(events: [event("r", .mcp, 10, status: .running)], lanes: [.mcp], viewport: viewport,
                                       width: 1000, now: epoch.addingTimeInterval(60))
    #expect(running.items.first?.isSpan == true)
    #expect(running.items.first.map { abs($0.maxX - 600) < 0.5 } == true)
}

// MARK: - Resource budget

extension ResourceBudgetTests {
    @Test func sessionTimelineReadsOnlyAppendedBytesAndDetailsOnDemand() throws {
        let files = MemoryTranscriptFiles()
        files.set("/t.jsonl", claudeTranscript)
        var tail = TranscriptFileTail(path: "/t.jsonl", format: .claude)
        let initialAdvance = tail.advance(using: files)
        #expect(initialAdvance)
        #expect(files.bytesRead == claudeTranscript.utf8.count)
        let unchanged = !tail.advance(using: files)
        #expect(unchanged, "an unchanged transcript costs one size check")
        #expect(files.bytesRead == claudeTranscript.utf8.count)
        let line = #"{"type":"assistant","uuid":"a9","timestamp":"2026-11-01T10:06:00.000Z","message":{"id":"msg_9","role":"assistant","content":[{"type":"text","text":"Done"}]}}"# + "\n"
        files.append("/t.jsonl", line)
        let before = files.bytesRead
        let appended = tail.advance(using: files)
        #expect(appended)
        #expect(files.bytesRead - before == line.utf8.count)

        let command = try #require(tail.index.events.first { $0.id == "toolu_1" })
        let reads = files.bytesRead
        _ = TranscriptDetailReader.read(command, source: .file(path: "/t.jsonl", format: .claude), files: files)
        guard case .lines(let ranges) = command.ref else { Issue.record("a call points at its lines"); return }
        #expect(files.bytesRead - reads == ranges.reduce(0) { $0 + $1.length })
    }

    @Test @MainActor func sessionTimelineReadsNothingWhileTranscriptsAreOff() async {
        let files = MemoryTranscriptFiles()
        files.set("/t.jsonl", claudeTranscript)
        let model = SessionTimelineModel(source: .file(path: "/t.jsonl", format: .claude), files: files)
        await model.refresh(session: nil, transcripts: false, live: false)
        #expect(files.reads == 0)
        #expect(model.phase == .off)
        await model.refresh(session: nil, transcripts: true, live: false)
        #expect(files.reads > 0)
        #expect(model.phase == .ready)
        #expect(model.events.count == model.index.events.count)
        #expect(model.viewport != nil)
    }
}

// MARK: - Live check against this Mac's transcripts (opt-in)

/// `SMACK_LIVE_TRANSCRIPTS=1 swift test --filter liveTranscripts` parses the newest real transcripts and prints
/// record types this version does not read, so format changes in Claude Code, Codex or OpenCode show up early.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SMACK_LIVE_TRANSCRIPTS"] == "1"))
func liveTranscriptsParse() {
    let result = TranscriptCatalog().recent(limit: 40)
    var unknown: [String: Int] = [:]
    for item in result.items {
        let index = TranscriptTail(source: item.source).advance(using: LocalTranscriptFileAccess()) ?? TranscriptIndex()
        for (type, count) in index.unrecognized { unknown["\(item.agentID): \(type)", default: 0] += count }
        let kinds = Dictionary(index.events.map { ($0.kind.rawValue, 1) }, uniquingKeysWith: +).sorted { $0.key < $1.key }
        print("[\(item.agentID)] \(index.events.count) events, \(index.turns.count) turns, \(index.outputTokens) tokens out — \(item.title ?? "untitled")")
        print("    \(item.source.path)  \(kinds.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        if (item.size ?? 0) > 8_192 { #expect(!index.events.isEmpty, "no events in \(item.source.path)") }
    }
    print("Unrecognized record types:", unknown.isEmpty ? "none" : unknown.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
    print("Compressed Codex rollouts not listed: \(result.compressed)")
    #expect(!result.items.isEmpty)
}
