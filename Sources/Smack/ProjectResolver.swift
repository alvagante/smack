import Foundation

enum ProjectKind: String, Codable, Sendable {
    case node, python, rust, go, ruby, java, php, swift, elixir, dotnet, compose, unknown
}

struct GitHead: Codable, Sendable, Equatable {
    var branch: String?
    var commit: String?
    var isWorktree: Bool
}

struct ProjectContext: Codable, Sendable, Equatable {
    var directory: String
    var root: String?
    var name: String
    var kind: ProjectKind?
    var git: GitHead?
}

protocol ProjectResolving: Sendable {
    func context(forDirectory path: String, now: Date) async -> ProjectContext?
}

actor ProjectResolver: ProjectResolving {
    private struct Entry {
        var value: ProjectContext
        var head: String?
        var modified: Date?
        var date: Date
        var used: UInt64
    }
    private var cache: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private let home: String
    init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) { self.home = home }
    var cachedDirectoryCount: Int { cache.count }

    func context(forDirectory path: String, now: Date = Date()) -> ProjectContext? {
        guard path.hasPrefix("/"), path != "/" else { return nil }
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        guard (try? directory.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true else { return nil }
        clock &+= 1
        if var entry = cache[directory.path], now.timeIntervalSince(entry.date) < 30,
           entry.modified == entry.head.flatMap({ modification($0) }) {
            entry.used = clock
            cache[directory.path] = entry
            return entry.value
        }
        var current = directory
        var manifest: (root: String, kind: ProjectKind, name: String?)?
        var git: GitHead?
        var root: String?
        var headPath: String?
        for _ in 0..<32 {
            if manifest == nil, let found = ProjectFile.manifest(at: current) {
                manifest = (current.path, found.kind, found.name)
            }
            if let found = ProjectFile.gitHead(at: current) {
                git = found.head
                headPath = found.headPath
                root = current.path
                break
            }
            if current.path == home || current.path == "/" { break }
            current.deleteLastPathComponent()
        }
        let value = ProjectContext(directory: directory.path, root: root ?? manifest?.root,
            name: manifest?.name ?? URL(fileURLWithPath: root ?? manifest?.root ?? directory.path).lastPathComponent,
            kind: manifest?.kind, git: git)
        cache[directory.path] = Entry(value: value, head: headPath, modified: headPath.flatMap { modification($0) }, date: now, used: clock)
        if cache.count > 512, let oldest = cache.min(by: { $0.value.used < $1.value.used })?.key { cache.removeValue(forKey: oldest) }
        return value
    }

    private func modification(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

}

/// Reads the few files project discovery needs, without loading whole manifests or running git.
enum ProjectFile {
    static func text(_ url: URL, limit: Int = 262_144) -> String? {
        guard let data = BoundedFile.read(url.path, limit: limit, followLinks: true) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Runtime markers at a repository root, in the order they are reported. Each is one bounded open; a missing
    /// marker costs a failed open and nothing else.
    static func runtimes(at directory: URL) -> [ProjectRuntime] {
        func read(_ name: String) -> String? { text(directory.appendingPathComponent(name), limit: 8_192) }
        func firstLine(_ value: String) -> String? {
            value.split(whereSeparator: \.isNewline).lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        var runtimes: [ProjectRuntime] = []
        func add(_ name: String, _ version: String?, _ marker: String, environment: Bool = false) {
            let runtime = ProjectRuntime(name: name, version: version.flatMap(ProjectRuntime.version), marker: marker,
                                         isEnvironment: environment)
            // `node` and `nodejs` name the same runtime in one file.
            guard runtimes.count < 16, !runtimes.contains(where: { $0.id == runtime.id }) else { return }
            runtimes.append(runtime)
        }
        for marker in [".venv", "venv", ".env"] {
            guard let config = read(marker + "/pyvenv.cfg") else { continue }
            let version = config.split(whereSeparator: \.isNewline).lazy.compactMap { line -> String? in
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, parts[0] == "version" || parts[0] == "version_info" else { return nil }
                return parts[1].split(separator: ".").prefix(3).joined(separator: ".")
            }.first
            add("Python", version, marker, environment: true)
        }
        let pins: [(String, String)] = [
            (".python-version", "Python"), (".nvmrc", "Node.js"), (".node-version", "Node.js"),
            (".ruby-version", "Ruby"), ("rust-toolchain", "Rust"),
        ]
        for (marker, name) in pins {
            if let value = read(marker).flatMap(firstLine) { add(name, value, marker) }
        }
        if let toml = read("rust-toolchain.toml") {
            add("Rust", tomlTable(toml, "toolchain")["channel"], "rust-toolchain.toml")
        }
        if let tools = read(".tool-versions") {
            for line in tools.split(whereSeparator: \.isNewline) {
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 2, !fields[0].hasPrefix("#") else { continue }
                add(ProjectRuntime.toolName(String(fields[0])), String(fields[1]), ".tool-versions")
            }
        }
        for marker in ["mise.toml", ".mise.toml"] {
            guard let toml = read(marker) else { continue }
            for (tool, version) in tomlTable(toml, "tools").sorted(by: { $0.key < $1.key }) {
                add(ProjectRuntime.toolName(tool), version, marker)
            }
        }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".envrc").path) {
            add("direnv", nil, ".envrc")
        }
        return runtimes
    }

    /// `key = "value"` pairs of one TOML table. Arrays and inline tables are skipped, not parsed.
    private static func tomlTable(_ text: String, _ table: String) -> [String: String] {
        var values: [String: String] = [:]
        var inside = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inside = line == "[\(table)]"; continue }
            guard inside else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[1].count >= 2, parts[1].hasPrefix("\""), parts[1].hasSuffix("\"") else { continue }
            values[parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))] = String(parts[1].dropFirst().dropLast())
        }
        return values
    }

    static func manifest(at directory: URL) -> (kind: ProjectKind, name: String?)? {
        let candidates: [(String, ProjectKind)] = [
            ("package.json", .node), ("pyproject.toml", .python), ("Cargo.toml", .rust), ("go.mod", .go),
            ("Gemfile", .ruby), ("pom.xml", .java), ("build.gradle", .java), ("build.gradle.kts", .java),
            ("composer.json", .php), ("Package.swift", .swift), ("mix.exs", .elixir),
            ("compose.yaml", .compose), ("compose.yml", .compose), ("docker-compose.yml", .compose),
            ("docker-compose.yaml", .compose), ("global.json", .dotnet)]
        for (file, kind) in candidates where FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) {
            guard let content = text(directory.appendingPathComponent(file)) else { return (kind, nil) }
            var name: String?
            if file.hasSuffix(".json"), let data = content.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { name = object["name"] as? String }
            if kind == .go {
                name = content.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("module ") })?
                    .dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if kind == .rust || kind == .python {
                var section = ""
                for line in content.components(separatedBy: .newlines) {
                    let line = line.trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("[") { section = line }
                    if section == (kind == .rust ? "[package]" : "[project]"),
                       let match = line.range(of: #"^name\s*=\s*["']([^"']+)["']"#, options: .regularExpression) {
                        let assignment = String(line[match])
                        name = assignment.split(separator: "=", maxSplits: 1).last?
                            .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        break
                    }
                }
            }
            return (kind, name.flatMap { $0.isEmpty ? nil : $0 })
        }
        if let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
           files.contains(where: { $0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj") || $0.hasSuffix(".sln") }) { return (.dotnet, nil) }
        return nil
    }

    /// The branch, commit and worktree marker of the repository rooted at `directory`, read from its `.git` entry.
    static func gitHead(at directory: URL) -> (head: GitHead, headPath: String)? {
        let marker = directory.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) else { return nil }
        var gitDirectory = marker
        if !isDirectory.boolValue, let text = text(marker), text.hasPrefix("gitdir:") {
            let target = text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDirectory = URL(fileURLWithPath: target, relativeTo: directory).standardizedFileURL
        }
        let head = gitDirectory.appendingPathComponent("HEAD")
        guard let headText = text(head)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        var branch: String?
        var commit: String?
        if headText.hasPrefix("ref: ") {
            let ref = String(headText.dropFirst(5))
            if ref.hasPrefix("refs/heads/") { branch = String(ref.dropFirst(11)) }
            var common = gitDirectory
            if let relative = text(gitDirectory.appendingPathComponent("commondir"))?.trimmingCharacters(in: .whitespacesAndNewlines) {
                common = URL(fileURLWithPath: relative, relativeTo: gitDirectory).standardizedFileURL
            }
            if ref.hasPrefix("refs/"), !ref.split(separator: "/").contains("..") {
                commit = text(common.appendingPathComponent(ref))?.trimmingCharacters(in: .whitespacesAndNewlines)
                if commit == nil, let packed = text(common.appendingPathComponent("packed-refs")) {
                    commit = packed.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                        let parts = line.split(separator: " ")
                        return parts.count == 2 && parts[1] == ref ? String(parts[0]) : nil
                    }.first
                }
            }
        } else { commit = headText }
        return (GitHead(branch: branch, commit: commit.map { String($0.prefix(12)) }, isWorktree: !isDirectory.boolValue), head.path)
    }
}
