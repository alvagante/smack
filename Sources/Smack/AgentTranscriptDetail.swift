import Foundation

/// The full content of one Session Timeline event, read from the transcript when it is opened.
struct TranscriptDetail: Sendable, Equatable {
    enum Style: Sendable {
        case text, code, diff
    }

    struct Section: Identifiable, Sendable, Equatable {
        var id: Int
        var title: String
        var body: String
        var style: Style
    }

    static let sectionLimit = 128 * 1024
    static let totalLimit = 512 * 1024

    private(set) var sections: [Section] = []
    private(set) var truncated = false
    private var total = 0

    mutating func add(_ title: String, _ body: String?, _ style: Style = .text) {
        guard let body else { return }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, total < Self.totalLimit else { return }
        let budget = min(Self.sectionLimit, Self.totalLimit - total)
        var text = trimmed
        if text.utf8.count > budget {
            text = String(decoding: text.utf8.prefix(budget), as: UTF8.self) + "\n…"
            truncated = true
        }
        total += text.utf8.count
        sections.append(Section(id: sections.count, title: title, body: text, style: style))
    }

    static func message(_ text: String) -> TranscriptDetail {
        var detail = TranscriptDetail()
        detail.add("Details", text)
        return detail
    }
}

enum TranscriptDetailReader {
    /// Reads at most the lines the event points at, each capped at 32 MiB.
    static func read(_ event: TranscriptEvent, source: TranscriptSource, files: any TranscriptFileAccess) -> TranscriptDetail {
        switch (event.ref, source) {
        case (.lines(let ranges), .file(let path, let format)):
            let objects: [[String: Any]] = ranges.prefix(4).compactMap { range in
                guard let data = files.read(path, offset: range.offset, length: min(range.length, 32 << 20)) else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            guard !objects.isEmpty else { return .message("The transcript no longer contains this event.") }
            return format == .codex ? codex(event, objects) : claude(event, objects)
        case (.openCode(let messageID, let part), .openCode(let database, let session)):
            guard let row = OpenCodeDatabase(path: database).message(session: session, id: messageID),
                  let object = (try? JSONSerialization.jsonObject(with: row.data)) as? [String: Any] else {
                return .message("OpenCode no longer has this message.")
            }
            return openCode(event, object, part: part)
        default:
            return .message("No transcript details for this event.")
        }
    }

    /// Details for events Smack observed itself rather than read from a transcript.
    static func process(_ event: TranscriptEvent) -> TranscriptDetail {
        var detail = TranscriptDetail()
        detail.add("Process", event.title)
        detail.add("Path", event.subtitle, .code)
        return detail
    }

    // MARK: Claude Code

    private static func claude(_ event: TranscriptEvent, _ objects: [[String: Any]]) -> TranscriptDetail {
        var detail = TranscriptDetail()
        let first = objects[0]
        let message = first.txObject("message")
        let blocks = message?.txObjects("content") ?? []
        switch event.kind {
        case .prompt, .compaction, .notice:
            if let text = message?["content"] as? String {
                detail.add(event.kind == .prompt ? "Prompt" : "Message", text)
            } else {
                detail.add(event.kind == .prompt ? "Prompt" : "Message", blocks.compactMap { $0.txString("text") }.joined(separator: "\n\n"))
            }
            if event.kind == .notice { detail.add("Content", first.txString("content")) }
        case .answer, .thinking:
            let block = blockIndex(event.id).flatMap { blocks.indices.contains($0) ? blocks[$0] : nil } ?? blocks.first ?? [:]
            detail.add(event.kind == .answer ? "Answer" : "Thinking", block.txString("text") ?? block.txString("thinking") ?? "")
            if event.kind == .thinking, (block.txString("thinking") ?? "").isEmpty {
                detail.add("Thinking", "The model's reasoning is not stored in readable form.")
            }
        default:
            if let call = blocks.first(where: { $0.txString("id") == event.id }) {
                toolInput(name: call.txString("name") ?? "", input: call.txObject("input") ?? [:], into: &detail)
            }
            for object in objects.dropFirst() {
                let results = object.txObject("message")?.txObjects("content") ?? []
                if let result = results.first(where: { $0.txString("tool_use_id") == event.id }) {
                    detail.add(result.txBool("is_error") == true ? "Error" : "Output", TranscriptText.joined(result["content"]), .code)
                }
            }
        }
        if let model = message?.txString("model"), event.kind == .answer { detail.add("Model", model) }
        if detail.sections.isEmpty { detail.add("Line", pretty(first), .code) }
        return detail
    }

    private static func toolInput(name: String, input: [String: Any], into detail: inout TranscriptDetail) {
        switch name {
        case "Bash":
            detail.add("Command", input.txString("command"), .code)
            detail.add("Description", input.txString("description"))
        case "Edit":
            detail.add(input.txString("file_path") ?? "Edit", diff(old: input.txString("old_string") ?? "", new: input.txString("new_string") ?? ""), .diff)
        case "MultiEdit":
            for edit in input.txObjects("edits") ?? [] {
                detail.add(input.txString("file_path") ?? "Edit", diff(old: edit.txString("old_string") ?? "", new: edit.txString("new_string") ?? ""), .diff)
            }
        case "Write":
            detail.add(input.txString("file_path") ?? "Write", added(input.txString("content") ?? ""), .diff)
        default:
            detail.add("Input", pretty(input), .code)
        }
    }

    private static func blockIndex(_ id: String) -> Int? {
        guard let marker = id.lastIndex(of: "#") else { return nil }
        return Int(id[id.index(after: marker)...])
    }

    // MARK: Codex

    private static func codex(_ event: TranscriptEvent, _ objects: [[String: Any]]) -> TranscriptDetail {
        var detail = TranscriptDetail()
        let first = objects[0]
        let payload = first.txObject("payload") ?? [:]
        if payload.txString("type") == "item_completed", let item = payload.txObject("item") {
            switch item.txString("type") ?? "" {
            case "UserMessage": detail.add("Prompt", TranscriptText.joined(item["content"]))
            case "AgentMessage": detail.add("Answer", TranscriptText.joined(item["content"]))
            case "Reasoning":
                let summary = (item["summary_text"] as? [String])?.joined(separator: "\n\n") ?? ""
                detail.add("Summary", summary.isEmpty ? "Codex stores this reasoning encrypted; only its timing is shown." : summary)
            case "CommandExecution":
                detail.add("Command", CodexTranscriptParser.command(item["command"]), .code)
                detail.add("Directory", item.txString("cwd").map { $0.hasPrefix("file://") ? String($0.dropFirst(7)) : $0 })
                detail.add("Exit code", item.txNumber("exit_code").map { String(Int($0)) })
                detail.add("Output", item.txString("aggregated_output") ?? item.txString("stdout"), .code)
                detail.add("Errors", item.txString("stderr"), .code)
            case "McpToolCall":
                detail.add("Tool", "\(item.txString("server") ?? "") › \(item.txString("tool") ?? "")")
                detail.add("Arguments", item["arguments"].map(pretty), .code)
                if let result = item.txObject("result") {
                    let text = TranscriptText.joined(result["content"])
                    detail.add("Result", text.isEmpty ? pretty(result) : text, .code)
                }
                if item.txPresent("error") { detail.add("Error", item["error"].map(pretty), .code) }
            case "FileChange":
                changes(item.txObject("changes"), into: &detail)
            case "Extension":
                detail.add("Query", item.txString("query"))
                detail.add("Results", item.txString("results") ?? item["results"].map(pretty), .code)
            default:
                detail.add("Item", pretty(item), .code)
            }
            return detail
        }
        switch payload.txString("type") ?? "" {
        case "user_message": detail.add("Prompt", payload.txString("message"))
        case "agent_message": detail.add("Answer", payload.txString("message"))
        case "agent_reasoning": detail.add("Reasoning", payload.txString("text"))
        case "mcp_tool_call_end":
            detail.add("Arguments", (payload.txObject("invocation")?["arguments"]).map(pretty), .code)
            detail.add("Result", payload["result"].map(pretty), .code)
        case "patch_apply_end":
            changes(payload.txObject("changes"), into: &detail)
            detail.add("Output", payload.txString("stdout"), .code)
        case "web_search_end": detail.add("Query", payload.txString("query"))
        case "exec_command_end":
            detail.add("Command", CodexTranscriptParser.command(payload["command"]), .code)
            detail.add("Output", payload.txString("aggregated_output") ?? payload.txString("stdout"), .code)
        case "function_call":
            let arguments = payload.txString("arguments") ?? ""
            let parsed = arguments.data(using: .utf8).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            if event.kind == .command, let parsed {
                detail.add("Command", CodexTranscriptParser.command(parsed["cmd"] ?? parsed["command"]), .code)
                detail.add("Directory", parsed.txString("workdir"))
            } else {
                detail.add("Arguments", parsed.map(pretty) ?? arguments, .code)
            }
        case "custom_tool_call":
            detail.add(event.kind == .fileChange ? "Patch" : "Input", payload.txString("input"), event.kind == .fileChange ? .diff : .code)
        default:
            detail.add("Line", pretty(first), .code)
        }
        for object in objects.dropFirst() {
            let output = object.txObject("payload")?["output"]
            detail.add("Output", TranscriptText.joined(output), .code)
        }
        return detail
    }

    private static func changes(_ changes: [String: Any]?, into detail: inout TranscriptDetail) {
        for path in (changes ?? [:]).keys.sorted() {
            guard let change = changes?[path] as? [String: Any] else { continue }
            if let diff = change.txString("unified_diff") {
                detail.add(path, diff, .diff)
            } else if let content = change.txString("content") {
                detail.add(path, change.txString("type") == "delete" ? removed(content) : added(content), .diff)
            } else {
                detail.add(path, change.txString("type"))
            }
        }
    }

    // MARK: OpenCode

    private static func openCode(_ event: TranscriptEvent, _ object: [String: Any], part: Int?) -> TranscriptDetail {
        var detail = TranscriptDetail()
        guard let part else {
            detail.add(event.kind == .prompt ? "Prompt" : "Message", object.txString("text"))
            if let error = object.txObject("error") { detail.add("Error", pretty(error), .code) }
            if detail.sections.isEmpty { detail.add("Message", pretty(object), .code) }
            return detail
        }
        let parts = object.txObjects("content") ?? []
        guard parts.indices.contains(part) else { return .message("OpenCode no longer has this part.") }
        let value = parts[part]
        switch value.txString("type") ?? "" {
        case "text": detail.add("Answer", value.txString("text"))
        case "reasoning":
            let text = value.txString("text") ?? ""
            detail.add("Reasoning", text.isEmpty ? "This model's reasoning is stored encrypted; only its timing is shown." : text)
        case "tool":
            let state = value.txObject("state") ?? [:]
            let input = state.txObject("input") ?? [:]
            if event.kind == .command {
                detail.add("Command", input.txString("command"), .code)
                detail.add("Description", input.txString("description"))
            } else if let old = input.txString("oldString"), let new = input.txString("newString") {
                detail.add(input.txString("filePath") ?? "Edit", diff(old: old, new: new), .diff)
            } else if let content = input.txString("content") {
                detail.add(input.txString("filePath") ?? "Write", added(content), .diff)
            } else {
                detail.add("Input", pretty(input), .code)
            }
            let output = TranscriptText.joined(state["content"])
            detail.add(state.txString("status") == "error" ? "Error" : "Output",
                       output.isEmpty ? (state.txString("output") ?? state.txString("error")) : output, .code)
            if let metadata = state.txObject("metadata"), !metadata.isEmpty { detail.add("Metadata", pretty(metadata), .code) }
        default:
            detail.add("Part", pretty(value), .code)
        }
        if let model = object.txObject("model")?.txString("id") { detail.add("Model", model) }
        return detail
    }

    // MARK: Formatting

    static func pretty(_ value: Any) -> String {
        if let text = value as? String { return text }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func diff(old: String, new: String) -> String {
        removed(old) + (old.isEmpty || new.isEmpty ? "" : "\n") + added(new)
    }

    static func added(_ text: String) -> String {
        text.isEmpty ? "" : text.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
    }

    static func removed(_ text: String) -> String {
        text.isEmpty ? "" : text.split(separator: "\n", omittingEmptySubsequences: false).map { "-" + $0 }.joined(separator: "\n")
    }
}
