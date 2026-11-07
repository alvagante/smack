import Foundation

struct ProjectCommit: Identifiable, Equatable, Sendable {
    let id: String
    let author: String
    let date: Date
    let subject: String
    let references: String
}

struct ProjectHistory: Sendable {
    var commits: [ProjectCommit] = []
    var references = ""
    var remotes = ""
    var messages: [String] = []
}

/// Separate from overview inspection: no history commands run until its section is opened.
struct ProjectHistoryInspector: Sendable {
    var run: ProjectGitInspector.Runner = ProjectGitInspector().run

    func history(root: String) async -> ProjectHistory {
        var history = ProjectHistory()
        let log = await run(root, ["log", "-100", "--date-order", "--format=%H%x00%an%x00%ct%x00%s%x00%D"])
        if let message = Self.failure(log) { history.messages.append(message) }
        else {
            history.commits = log.output.split(whereSeparator: \.isNewline).compactMap { line in
                let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
                guard fields.count == 5, let seconds = Double(fields[2]) else { return nil }
                return ProjectCommit(id: String(fields[0]), author: String(fields[1]),
                    date: Date(timeIntervalSince1970: seconds), subject: String(fields[3]), references: String(fields[4]))
            }
        }
        guard !Task.isCancelled else { return history }
        let refs = await run(root, ["for-each-ref", "--count=200", "--sort=-committerdate",
                                    "--format=%(refname:short) %(objectname:short) %(subject)"])
        if let message = Self.failure(refs) { history.messages.append(message) }
        else { history.references = refs.output }
        guard !Task.isCancelled else { return history }
        let remotes = await run(root, ["remote", "-v"])
        if let message = Self.failure(remotes) { history.messages.append(message) }
        else { history.remotes = remotes.output }
        if log.truncated || refs.truncated || remotes.truncated {
            history.messages.append("Git output limited to 2 MB per command; results may be incomplete.")
        }
        return history
    }

    func commit(root: String, id: String) async -> String {
        // Only object IDs from the history parser can become a revision argument.
        guard (7...64).contains(id.count), id.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            return "Commit unavailable."
        }
        let result = await run(root, ["show", "--no-ext-diff", "--no-textconv", "--format=fuller",
                                      "--stat", "--patch", id, "--"])
        if let message = Self.failure(result) { return message }
        return result.output + (result.truncated ? "\nOutput limited to 2 MB." : "")
    }

    private static func failure(_ result: CommandRunner.Result) -> String? {
        if result.cancelled { return "Git was stopped." }
        if result.timedOut { return "Git timed out after 8 seconds." }
        guard result.status == 0 else {
            let text = (result.error + result.output).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "Git information is unavailable." : text
        }
        return nil
    }
}
