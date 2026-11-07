import Foundation

typealias BaselineItem = [String: String]

private struct BaselineFieldKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

struct BaselineSection: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable { case complete, incomplete, unavailable }
    var status: Status = .complete
    var durationMs: Int = 0
    var error: String?
    var items: [BaselineItem] = []
    var coverage: [String]? = nil

    private enum CodingKeys: String, CodingKey { case status, durationMs, error, items, coverage }
    init(status: Status = .complete, durationMs: Int = 0, error: String? = nil,
         items: [BaselineItem] = [], coverage: [String]? = nil) {
        self.status = status; self.durationMs = durationMs; self.error = error
        self.items = items; self.coverage = coverage
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(Status.self, forKey: .status)
        durationMs = try c.decode(Int.self, forKey: .durationMs)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        coverage = try c.decodeIfPresent([String].self, forKey: .coverage)
        let section = decoder.codingPath.last?.stringValue ?? ""
        let rule = BaselineDiff.rules[section]
        let fields = Set((rule?.identity ?? []) + (rule?.fields ?? []))
        var values = try c.nestedUnkeyedContainer(forKey: .items)
        while !values.isAtEnd {
            let item = try values.nestedContainer(keyedBy: BaselineFieldKey.self)
            var result: BaselineItem = [:]
            for key in item.allKeys where fields.contains(key.stringValue) {
                result[key.stringValue] = try item.decodeIfPresent(String.self, forKey: key)
            }
            items.append(result)
        }
    }
}

struct BaselineDocument: Codable, Sendable, Equatable {
    var schemaVersion = 1
    var generator = ["app": "Smack", "version": "1.1.0", "flavor": Capabilities.flavor.rawValue]
    var capturedAt = Date()
    var name = ""
    var note = ""
    var pinned = false
    var machine: [String: String] = [:]
    var sections: [String: BaselineSection] = [:]

    enum CodingKeys: String, CodingKey { case schemaVersion, generator, capturedAt, name, note, pinned, machine, sections }
    init(name: String = "", machine: [String: String] = [:], sections: [String: BaselineSection] = [:]) {
        self.name = name; self.machine = machine; self.sections = sections
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        func strings(_ key: CodingKeys, fields: [String]) throws -> [String: String] {
            let object = try c.nestedContainer(keyedBy: BaselineFieldKey.self, forKey: key)
            var result: [String: String] = [:]
            for field in fields {
                result[field] = try object.decodeIfPresent(String.self, forKey: BaselineFieldKey(field))
            }
            return result
        }
        generator = try strings(.generator, fields: ["app", "version", "flavor"])
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        machine = try strings(.machine, fields: ["model", "chip", "macOS", "build", "hostName"])
        let sectionValues = try c.nestedContainer(keyedBy: BaselineFieldKey.self, forKey: .sections)
        for key in sectionValues.allKeys {
            sections[key.stringValue] = BaselineDiff.rules[key.stringValue] == nil
                ? .init(status: .unavailable, error: "Unknown section")
                : try sectionValues.decode(BaselineSection.self, forKey: key)
        }
    }

    static let sizeLimit = 32 * 1024 * 1024

    func encoded(home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> Data {
        var copy = self
        for id in copy.sections.keys {
            var section = copy.sections[id]!
            section.items = section.items.map { item in
                item.mapValues { Self.normalize($0, home: home) }
            }.sorted { BaselineDiff.key($0, section: id) < BaselineDiff.key($1, section: id) }
            section.error = section.error.map { Self.normalize($0, home: home) }
            copy.sections[id] = section
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(copy)
        guard data.count <= Self.sizeLimit else { throw BaselineError("Baseline exceeds 32 MiB") }
        return data
    }

    static func normalize(_ value: String, home: String) -> String {
        value == home ? "~" : value.replacingOccurrences(of: home + "/", with: "~/")
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= sizeLimit else { throw BaselineError("Baseline exceeds 32 MiB") }
        struct Header: Decodable { var schemaVersion: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard try decoder.decode(Header.self, from: data).schemaVersion == 1 else {
            throw BaselineError("Unsupported baseline schemaVersion")
        }
        let result = try decoder.decode(Self.self, from: data)
        for (id, section) in result.sections where BaselineDiff.rules[id] != nil {
            let keys = section.items.map { BaselineDiff.key($0, section: id) }
            guard Set(keys).count == keys.count else { throw BaselineError("Duplicate identities in " + id) }
        }
        return result
    }

    static func read(_ url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw BaselineError("Baseline must be a regular file") }
        guard let size = values.fileSize, size <= sizeLimit else { throw BaselineError("Baseline exceeds 32 MiB") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: sizeLimit + 1) ?? Data()
        return try decode(data)
    }
}

struct BaselineError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct BaselineDiffResult: Codable, Sendable, Equatable {
    struct Change: Codable, Sendable, Equatable {
        struct Value: Codable, Sendable, Equatable { var old: String?; var new: String? }
        var identity: String
        var fields: [String: Value]
        var displayIdentity: String? = nil
    }
    struct Section: Codable, Sendable, Equatable {
        var reason: String?
        var added: [BaselineItem] = []
        var removed: [BaselineItem] = []
        var changed: [Change] = []
        var count: Int { added.count + removed.count + changed.count }
    }
    var baseMachine: [String: String]
    var againstMachine: [String: String]
    var baseCapturedAt: Date
    var againstCapturedAt: Date
    var sections: [String: Section]
    var drift: Bool { sections.values.contains { $0.count > 0 } }
    func exitCode(strict: Bool) -> Int { drift || (strict && sections.values.contains { $0.reason != nil }) ? 2 : 0 }

    var markdown: String {
        func header(_ machine: [String: String], _ date: Date) -> String {
            "\(machine["model"] ?? "?"), macOS \(machine["macOS"] ?? "?"), \(date.ISO8601Format())"
        }
        var lines = ["# Baseline drift", "", "Base: " + header(baseMachine, baseCapturedAt),
                     "Against: " + header(againstMachine, againstCapturedAt), ""]
        for id in sections.keys.sorted() {
            let s = sections[id]!
            lines += ["## " + id, ""]
            if let reason = s.reason { lines += ["Not compared: " + reason, ""]; continue }
            lines += ["Added: \(s.added.count), removed: \(s.removed.count), changed: \(s.changed.count)", ""]
            for item in s.added { lines.append("+ " + BaselineDiff.label(item, section: id)) }
            for item in s.removed { lines.append("- " + BaselineDiff.label(item, section: id)) }
            for change in s.changed {
                for field in change.fields.keys.sorted() {
                    let value = change.fields[field]!
                    lines.append("* \(change.displayIdentity ?? change.identity) \(field): \(value.old ?? "(absent)") -> \(value.new ?? "(absent)")")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

enum BaselineDiff {
    static let rules: [String: (identity: [String], fields: [String])] = [
        "system": ([], ["macOS", "build", "firmware", "sip"]),
        "posture": (["id"], ["status"]),
        "startup": (["id"], ["name", "category", "enabled", "program", "trigger", "developer"]),
        "listeners": (["protocol", "scope", "port", "program"], ["path"]),
        "apps": (["bundleID", "path"], ["version", "build", "teamID"]),
        "homebrew": (["name", "type"], ["version", "pinned", "tap"]),
        "runtimes": (["language", "path"], ["version", "manager"]),
        "agents": (["agentID", "path"], ["size", "sha256"]),
        "profiles": (["identifier"], ["displayName", "organization", "installDate"]),
        "systemExtensions": (["bundleID", "teamID"], ["version", "state"]),
        "docker": (["kind", "name"], ["imageID", "state"])
    ]
    static func label(_ item: BaselineItem, section: String) -> String {
        let parts = (rules[section]?.identity ?? item.keys.sorted()).compactMap { item[$0] }
        return parts.isEmpty ? section : parts.joined(separator: " / ")
    }
    static func key(_ item: BaselineItem, section: String) -> String {
        // Length-prefixed components prevent collisions when paths or names contain separators.
        (rules[section]?.identity ?? item.keys.sorted()).map {
            let value = item[$0] ?? ""
            return "\(value.utf8.count):\(value)"
        }.joined(separator: "|")
    }
    static func compare(_ base: BaselineDocument, _ against: BaselineDocument) -> BaselineDiffResult {
        var sections: [String: BaselineDiffResult.Section] = [:]
        for id in Set(base.sections.keys).union(against.sections.keys).sorted() {
            guard let rule = rules[id] else { sections[id] = .init(reason: "Unknown section"); continue }
            guard let a = base.sections[id], let b = against.sections[id] else {
                sections[id] = .init(reason: "Section absent from one capture"); continue
            }
            guard a.status == .complete, b.status == .complete else {
                sections[id] = .init(reason: "Base: \(a.status.rawValue) \(a.error ?? ""); against: \(b.status.rawValue) \(b.error ?? "")")
                continue
            }
            guard a.coverage.map(Set.init) == b.coverage.map(Set.init) else {
                sections[id] = .init(reason: "Inventory coverage differs between captures")
                continue
            }
            let left = Dictionary(grouping: a.items, by: { key($0, section: id) })
            let right = Dictionary(grouping: b.items, by: { key($0, section: id) })
            guard left.values.allSatisfy({ $0.count == 1 }), right.values.allSatisfy({ $0.count == 1 }) else {
                sections[id] = .init(reason: "Duplicate identities"); continue
            }
            var diff = BaselineDiffResult.Section()
            for key in Set(left.keys).union(right.keys).sorted() {
                guard let old = left[key]?.first else { diff.added.append(right[key]!.first!); continue }
                guard let new = right[key]?.first else { diff.removed.append(old); continue }
                var fields: [String: BaselineDiffResult.Change.Value] = [:]
                for field in rule.fields where old[field] != new[field] { fields[field] = .init(old: old[field], new: new[field]) }
                if !fields.isEmpty { diff.changed.append(.init(identity: key, fields: fields, displayIdentity: label(new, section: id))) }
            }
            sections[id] = diff
        }
        return .init(baseMachine: base.machine, againstMachine: against.machine,
                     baseCapturedAt: base.capturedAt, againstCapturedAt: against.capturedAt, sections: sections)
    }
}

actor BaselineRepository {
    let directory: URL
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Smack/baselines")) { self.directory = directory }

    func list() throws -> [(URL, BaselineDocument)] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { ($0, try BaselineDocument.read($0)) }
            .sorted { ($0.1.capturedAt, $0.0.lastPathComponent) > ($1.1.capturedAt, $1.0.lastPathComponent) }
    }
    func update(_ id: String, name: String, note: String, pinned: Bool) throws {
        let rows = try list()
        guard let row = rows.first(where: { $0.0.lastPathComponent == id }) else { throw BaselineError("Baseline not found") }
        var doc = row.1
        doc.name = name; doc.note = note; doc.pinned = pinned
        try doc.encoded().write(to: row.0, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: row.0.path)
    }
    func load(_ id: String?) throws -> BaselineDocument {
        let rows = try list()
        guard let row = rows.first(where: { id == nil || $0.0.lastPathComponent == id }) else {
            throw BaselineError("Baseline not found")
        }
        return row.1
    }
    func save(_ document: BaselineDocument, retention: Int = 20, golden: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let slug = String(document.name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }.prefix(60))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: document.capturedAt).replacingOccurrences(of: ":", with: "")
        var url = directory.appendingPathComponent(stamp + "-" + (slug.isEmpty ? "baseline" : slug) + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(stamp + "-" + UUID().uuidString + ".json")
        }
        try document.encoded().write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let unpinned = try list().filter { !$0.1.pinned && $0.0.lastPathComponent != golden && $0.0.lastPathComponent != url.lastPathComponent }
        let remaining = max(1, retention) - (document.pinned || url.lastPathComponent == golden ? 0 : 1)
        for row in unpinned.dropFirst(remaining) { try FileManager.default.removeItem(at: row.0) }
        return url
    }
}
