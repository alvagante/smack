import Foundation

struct McpServerDefinition: Codable, Sendable {
    var name: String
    var commands: Set<String>
}

actor McpConfigReader {
    private struct Cached {
        var modified: Date?
        var size: Int
        var servers: [McpServerDefinition]
    }
    private var cache: [URL: Cached] = [:]
    private let home: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    func servers(for definition: AgentDefinition?) -> [McpServerDefinition] {
        guard let definition else { return [] }
        let urls = definition.locations.filter { $0.category == .mcp }.flatMap { location in
            location.homeRelative ? [home.appendingPathComponent(location.path)] :
                definition.roots.map { root in
                    let base = root.hasPrefix("/") ? URL(fileURLWithPath: root) : home.appendingPathComponent(root)
                    return base.appendingPathComponent(location.path)
                }
        }
        return urls.flatMap { read($0) }
    }

    func read(_ url: URL) -> [McpServerDefinition] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size <= 1_048_576 else { return [] }
        let modified = attributes[.modificationDate] as? Date
        if let cached = cache[url], cached.modified == modified, cached.size == size { return cached.servers }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576 else { return [] }
        let servers = Self.parse(data, toml: url.pathExtension == "toml")
        cache[url] = Cached(modified: modified, size: size, servers: servers)
        return servers
    }

    static func parse(_ data: Data, toml: Bool) -> [McpServerDefinition] {
        func server(_ name: String, _ command: String?, _ args: [String]) -> McpServerDefinition {
            McpServerDefinition(name: name, commands: Set(([command].compactMap { $0 } + Array(args.prefix(2))).map {
                ($0 as NSString).lastPathComponent
            }))
        }
        if !toml {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = object["mcpServers"] as? [String: [String: Any]] else { return [] }
            return servers.keys.sorted().compactMap { name in
                guard let value = servers[name], let command = value["command"] as? String else { return nil }
                return server(name, command, value["args"] as? [String] ?? [])
            }
        }
        // Read only the command and args fields in server tables. Nested env and headers tables are skipped.
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [McpServerDefinition] = []
        var name: String?
        var command: String?
        var args: [String] = []
        func flush() {
            if let name, let command { result.append(server(name, command, args)) }
        }
        func uncomment(_ line: String) -> String {
            var quote: Character?
            var escaped = false
            var result = ""
            for char in line {
                if escaped { result.append(char); escaped = false; continue }
                if char == "\\", quote == "\"" { result.append(char); escaped = true; continue }
                if let current = quote {
                    if char == current { quote = nil }
                } else if char == "\"" || char == "'" { quote = char }
                else if char == "#" { break }
                result.append(char)
            }
            return result.trimmingCharacters(in: .whitespaces)
        }
        func string(_ value: String) -> String? {
            let value = value.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 { return String(value.dropFirst().dropLast()) }
            return try? JSONDecoder().decode(String.self, from: Data(value.utf8))
        }
        func array(_ value: String) -> [String] {
            var quote: Character?
            var escaped = false
            var item = ""
            var values: [String] = []
            for char in value.dropFirst().dropLast() {
                if escaped { item.append(char); escaped = false; continue }
                if char == "\\", quote == "\"" { item.append(char); escaped = true; continue }
                if let current = quote {
                    if char == current { quote = nil }
                } else if char == "\"" || char == "'" { quote = char }
                else if char == "," { if let decoded = string(item) { values.append(decoded) }; item = ""; continue }
                item.append(char)
            }
            if let decoded = string(item) { values.append(decoded) }
            return values
        }
        var pendingArray: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = uncomment(raw)
            if let pending = pendingArray {
                let value = pending + line
                if value.hasSuffix("]") { args = array(value); pendingArray = nil }
                else { pendingArray = value }
                continue
            }
            if line.hasPrefix("[") {
                flush(); name = nil; command = nil; args = []
                if line.hasPrefix("[mcp_servers."), let end = line.firstIndex(of: "]") {
                    let key = String(line[line.index(line.startIndex, offsetBy: 13)..<end])
                    if let quoted = string(key) { name = quoted }
                    else if !key.contains(".") { name = key }
                }
            } else if name != nil, let equals = line.firstIndex(of: "=") {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                if key == "command" { command = string(value) }
                if key == "args", value.hasPrefix("[") {
                    if value.hasSuffix("]") { args = array(value) }
                    else { pendingArray = value }
                }
            }
        }
        flush()
        return result.sorted { $0.name < $1.name }
    }
}
