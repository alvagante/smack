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
            if manifest == nil, let found = Self.manifest(at: current) {
                manifest = (current.path, found.0, found.1)
            }
            let marker = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                var gitDirectory = marker
                if !isDirectory.boolValue, let text = Self.text(marker), text.hasPrefix("gitdir:") {
                    let target = text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                    gitDirectory = URL(fileURLWithPath: target, relativeTo: current).standardizedFileURL
                }
                let head = gitDirectory.appendingPathComponent("HEAD")
                headPath = head.path
                if let text = Self.text(head)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    var branch: String?
                    var commit: String?
                    if text.hasPrefix("ref: ") {
                        let ref = String(text.dropFirst(5))
                        if ref.hasPrefix("refs/heads/") { branch = String(ref.dropFirst(11)) }
                        var common = gitDirectory
                        if let relative = Self.text(gitDirectory.appendingPathComponent("commondir"))?.trimmingCharacters(in: .whitespacesAndNewlines) {
                            common = URL(fileURLWithPath: relative, relativeTo: gitDirectory).standardizedFileURL
                        }
                        if ref.hasPrefix("refs/"), !ref.split(separator: "/").contains("..") {
                            commit = Self.text(common.appendingPathComponent(ref))?.trimmingCharacters(in: .whitespacesAndNewlines)
                            if commit == nil, let packed = Self.text(common.appendingPathComponent("packed-refs")) {
                                commit = packed.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                                    let parts = line.split(separator: " ")
                                    return parts.count == 2 && parts[1] == ref ? String(parts[0]) : nil
                                }.first
                            }
                        }
                    } else { commit = text }
                    git = GitHead(branch: branch, commit: commit.map { String($0.prefix(12)) }, isWorktree: !isDirectory.boolValue)
                }
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

    private static func text(_ url: URL) -> String? {
        guard let data = BoundedFile.read(url.path, limit: 262_144, followLinks: true) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func manifest(at directory: URL) -> (ProjectKind, String?)? {
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
}
