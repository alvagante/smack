import Foundation

protocol AgentSessionLogAdapter: Sendable {
    var agentID: String { get }
    func latestLog(for session: AgentSession, home: URL) -> AgentSessionLog?
}

/// Metadata is the only filesystem capability available to adapters.
protocol SessionLogFileSystem: Sendable {
    func files(under root: URL) -> [AgentSessionLog]
}

struct LocalSessionLogFileSystem: SessionLogFileSystem {
    func files(under root: URL) -> [AgentSessionLog] {
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [AgentSessionLog] = []
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            guard visited <= 10_000 else { break }
            guard ["jsonl", "json"].contains(url.pathExtension),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, let modified = values.contentModificationDate else { continue }
            files.append(AgentSessionLog(path: url.path, size: values.fileSize ?? 0, modifiedAt: modified))
        }
        return files
    }
}

struct CatalogSessionLogAdapter: AgentSessionLogAdapter {
    var agentID: String
    var fileSystem: any SessionLogFileSystem = LocalSessionLogFileSystem()
    func latestLog(for session: AgentSession, home: URL) -> AgentSessionLog? {
        let root: URL
        switch agentID {
        case "claude":
            guard let directory = session.project?.directory else { return nil }
            // Claude Code names the folder after the directory with every non-alphanumeric character as "-".
            let name = String(directory.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
            root = home.appendingPathComponent(".claude/projects").appendingPathComponent(name)
        case "codex": root = home.appendingPathComponent(".codex/sessions")
        case "gemini": root = home.appendingPathComponent(".gemini/tmp")
        default: return nil
        }
        return fileSystem.files(under: root).filter {
            $0.modifiedAt >= session.startedAt &&
                (agentID != "claude" || $0.path.hasSuffix(".jsonl")) &&
                (agentID != "gemini" || $0.path.contains("/chats/session-"))
        }.max { $0.modifiedAt < $1.modifiedAt }
    }
}
