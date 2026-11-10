import Foundation

/// One language manifest at a repository root, summarized as facts, with the runtime version it asks for.
struct ProjectManifest: Identifiable, Equatable, Sendable {
    struct Fact: Equatable, Sendable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    let file: String
    /// A Development Environment language name, or "Puppet".
    let language: String
    var facts: [Fact] = []
    /// The runtime version or range the manifest declares, such as `>=3.11` or `1.22.1`.
    var requirement: String?

    var id: String { file }
    var devLanguage: DevLanguage? { DevLanguage(rawValue: language) }
}

/// Reads the language manifests directly at a repository root: only the names below, each capped at
/// `byteLimit`. Lockfiles are only checked for existence, never read. No subprocess.
struct ProjectManifestReader: Sendable {
    static let byteLimit = 262_144

    var read: @Sendable (String, Int) -> Data? = { path, limit in
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: limit)
    }
    var exists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    private static let files: [(name: String, language: String, lockfiles: [String])] = [
        ("package.json", DevLanguage.node.rawValue, ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock"]),
        ("pyproject.toml", DevLanguage.python.rawValue, ["uv.lock", "poetry.lock", "pdm.lock", "Pipfile.lock"]),
        ("requirements.txt", DevLanguage.python.rawValue, []),
        ("go.mod", DevLanguage.go.rawValue, ["go.sum"]),
        ("Cargo.toml", DevLanguage.rust.rawValue, ["Cargo.lock"]),
        ("Package.swift", DevLanguage.swift.rawValue, ["Package.resolved"]),
        ("Gemfile", DevLanguage.ruby.rawValue, ["Gemfile.lock"]),
        ("composer.json", DevLanguage.php.rawValue, ["composer.lock"]),
        ("pom.xml", DevLanguage.java.rawValue, []),
        ("build.gradle", DevLanguage.java.rawValue, []),
        ("build.gradle.kts", DevLanguage.kotlin.rawValue, []),
        ("metadata.json", "Puppet", []),
        ("Puppetfile", "Puppet", ["Puppetfile.lock"]),
    ]

    func manifests(root: String) -> [ProjectManifest] {
        Self.files.compactMap { file in
            guard let data = read(root + "/" + file.name, Self.byteLimit) else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            guard var manifest = Self.parse(file.name, language: file.language, text: text) else { return nil }
            if let lockfile = file.lockfiles.first(where: { exists(root + "/" + $0) }) {
                manifest.facts.append(.init(label: "Lockfile", value: lockfile))
            }
            return manifest
        }
    }

    static func parse(_ name: String, language: String, text: String) -> ProjectManifest? {
        var manifest = ProjectManifest(file: name, language: language)
        var facts: [(String, String?)] = []
        switch name {
        case "package.json":
            guard let json = jsonObject(text) else { return unreadable(manifest) }
            let scripts = (json["scripts"] as? [String: Any])?.keys.sorted() ?? []
            facts = [("Name", json["name"] as? String), ("Version", json["version"] as? String),
                     ("Module type", json["type"] as? String), ("Package manager", json["packageManager"] as? String),
                     ("Scripts", scripts.isEmpty ? nil : "\(scripts.count): " + scripts.prefix(6).joined(separator: ", ")
                        + (scripts.count > 6 ? ", …" : "")),
                     ("Dependencies", counts((json["dependencies"] as? [String: Any])?.count, (json["devDependencies"] as? [String: Any])?.count)),
                     ("Workspaces", (json["workspaces"] as? [Any]).map { String($0.count) })]
            manifest.requirement = (json["engines"] as? [String: Any])?["node"] as? String
        case "pyproject.toml":
            let toml = TOMLLite(text)
            let project = toml.string("project", "name") != nil ? "project" : "tool.poetry"
            let poetry = toml.keys("tool.poetry.dependencies")
            facts = [("Name", toml.string(project, "name")), ("Version", toml.string(project, "version")),
                     ("Dependencies", toml.arrayCount("project", "dependencies").map(String.init)
                        ?? (poetry.isEmpty ? nil : String(poetry.filter { $0 != "python" }.count))),
                     ("Build backend", toml.string("build-system", "build-backend"))]
            manifest.requirement = toml.string("project", "requires-python") ?? toml.string("tool.poetry.dependencies", "python")
        case "requirements.txt":
            let packages = lines(text).filter { !$0.hasPrefix("#") && !$0.hasPrefix("-") }
            facts = [("Packages", String(packages.count))]
        case "go.mod":
            var requires = 0, indirect = 0, block = false
            for line in lines(text) {
                if line.hasPrefix("module ") { facts.append(("Module", String(line.dropFirst(7)))) }
                else if line.hasPrefix("go ") { manifest.requirement = String(line.dropFirst(3)) }
                else if line.hasPrefix("toolchain ") { facts.append(("Toolchain", String(line.dropFirst(10)))) }
                else if line == "require (" { block = true }
                else if block && line == ")" { block = false }
                else if block || line.hasPrefix("require ") {
                    requires += 1
                    if line.contains("// indirect") { indirect += 1 }
                }
            }
            if requires > 0 { facts.append(("Requirements", indirect > 0 ? "\(requires) (\(indirect) indirect)" : String(requires))) }
        case "Cargo.toml":
            let toml = TOMLLite(text)
            facts = [("Name", toml.string("package", "name")), ("Version", toml.string("package", "version")),
                     ("Edition", toml.string("package", "edition")),
                     ("Dependencies", counts(toml.keys("dependencies").count, toml.keys("dev-dependencies").count)),
                     ("Workspace members", toml.arrayCount("workspace", "members").map(String.init))]
            manifest.requirement = toml.string("package", "rust-version")
        case "Package.swift":
            if let first = text.split(whereSeparator: \.isNewline).first, first.contains("swift-tools-version") {
                manifest.requirement = first.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
            }
            let dependencies = text.components(separatedBy: ".package(").count - 1
            facts = [("Package dependencies", String(dependencies))]
        case "Gemfile":
            let entries = lines(text).filter { !$0.hasPrefix("#") }
            manifest.requirement = entries.first { $0.hasPrefix("ruby ") }.flatMap(quoted)
            facts = [("Gems", String(entries.filter { $0.hasPrefix("gem ") }.count))]
        case "composer.json":
            guard let json = jsonObject(text) else { return unreadable(manifest) }
            let require = json["require"] as? [String: Any] ?? [:]
            let packages = require.keys.filter { $0 != "php" && !$0.hasPrefix("ext-") }
            facts = [("Name", json["name"] as? String),
                     ("Dependencies", counts(packages.count, (json["require-dev"] as? [String: Any])?.count))]
            manifest.requirement = require["php"] as? String
        case "pom.xml":
            facts = [("Artifact", xml(text, "artifactId")),
                     ("Dependencies", String(text.components(separatedBy: "<dependency>").count - 1))]
            manifest.requirement = xml(text, "maven.compiler.release") ?? xml(text, "java.version") ?? xml(text, "maven.compiler.source")
        case "build.gradle", "build.gradle.kts":
            let entries = lines(text)
            let dependencies = entries.filter { line in
                ["implementation", "api", "testImplementation", "compileOnly", "runtimeOnly"].contains { line.hasPrefix($0 + "(") || line.hasPrefix($0 + " ") }
            }
            facts = [("Dependencies", String(dependencies.count))]
            manifest.requirement = firstMatch(text, #"JavaLanguageVersion\.of\((\d+)\)"#)
                ?? firstMatch(text, #"(?:source|target)Compatibility\s*=\s*['"]?(?:JavaVersion\.VERSION_)?([0-9_.]+)"#)?.replacingOccurrences(of: "_", with: ".")
        case "metadata.json":
            guard let json = jsonObject(text) else { return nil }
            guard json["operatingsystem_support"] != nil || (json["requirements"] as? [[String: Any]])?.isEmpty == false else { return nil }
            let puppet = (json["requirements"] as? [[String: Any]])?.first { $0["name"] as? String == "puppet" }
            let systems = (json["operatingsystem_support"] as? [[String: Any]])?.compactMap { $0["operatingsystem"] as? String } ?? []
            facts = [("Module", json["name"] as? String), ("Version", json["version"] as? String),
                     ("Author", json["author"] as? String), ("License", json["license"] as? String),
                     ("Puppet", puppet?["version_requirement"] as? String),
                     ("Dependencies", (json["dependencies"] as? [Any]).map { String($0.count) }),
                     ("Supported OS", systems.isEmpty ? nil : systems.joined(separator: ", "))]
        case "Puppetfile":
            let entries = lines(text)
            facts = [("Modules", String(entries.filter { $0.hasPrefix("mod ") }.count)),
                     ("Forge", entries.first { $0.hasPrefix("forge ") }.flatMap(quoted))]
        default:
            return nil
        }
        manifest.facts += facts.compactMap { label, value in value.map { ProjectManifest.Fact(label: label, value: $0) } }
        return manifest
    }

    private static func unreadable(_ manifest: ProjectManifest) -> ProjectManifest {
        var manifest = manifest
        manifest.facts = [.init(label: "Contents", value: "Unavailable")]
        return manifest
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func counts(_ main: Int?, _ dev: Int?) -> String? {
        switch (main ?? 0, dev ?? 0) {
        case (0, 0): nil
        case (let main, 0): String(main)
        case (let main, let dev): "\(main) + \(dev) dev"
        }
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func quoted(_ line: String) -> String? { firstMatch(line, #"['"]([^'"]+)['"]"#) }

    private static func xml(_ text: String, _ tag: String) -> String? {
        firstMatch(text, "<\(NSRegularExpression.escapedPattern(for: tag))>\\s*([^<]+?)\\s*</")
    }

    static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// Just enough TOML for manifests: `[table]` headers, `key = "string"`, arrays (counted) and inline tables.
private struct TOMLLite {
    private var values: [String: [String: String]] = [:]
    private var arrays: [String: [String: Int]] = [:]
    private var order: [String: [String]] = [:]

    init(_ text: String) {
        var table = ""
        var open: (key: String, count: Int)?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var array = open {
                if line.hasPrefix("]") { arrays[table, default: [:]][array.key] = array.count; open = nil }
                else if line.hasPrefix("\"") || line.hasPrefix("'") { array.count += 1; open = array }
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                table = String(line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            order[table, default: []].append(key)
            if value == "[" { open = (key, 0) }
            else if value.hasPrefix("[") {
                arrays[table, default: [:]][key] = value.split(separator: ",").filter { $0.contains("\"") || $0.contains("'") }.count
            } else if value.hasPrefix("\"") || value.hasPrefix("'") {
                values[table, default: [:]][key] = String(value.dropFirst().prefix { $0 != "\"" && $0 != "'" })
            } else if value.hasPrefix("{") {
                values[table, default: [:]][key] = ProjectManifestReader.firstMatch(value, #"version\s*=\s*["']([^"']+)"#)
            } else {
                values[table, default: [:]][key] = value
            }
        }
    }

    func string(_ table: String, _ key: String) -> String? { values[table]?[key] }
    func arrayCount(_ table: String, _ key: String) -> Int? { arrays[table]?[key] }
    func keys(_ table: String) -> [String] { order[table] ?? [] }
}

/// Runtime versions read without running anything: from version-manager and Homebrew paths, and compared with a
/// manifest's requirement.
enum RuntimeVersion {
    /// The last path component that is a version: `v20.11.1`, `3.12.4_1` (Homebrew revision), `1.77.0-aarch64-…`.
    static func fromPath(_ path: String) -> String? {
        path.split(separator: "/").reversed().lazy.compactMap { component in
            ProjectManifestReader.firstMatch(String(component), #"^v?(\d+\.\d+(?:\.\d+)?)(?:[_-].*)?$"#)
        }.first
    }

    /// Whether `version` meets `requirement`; nil when the requirement is not a numeric constraint (`lts/iron`).
    /// No operator or `=` matches as a prefix (`3.12` accepts `3.12.4`); `^` keeps the major version; `~` and `~>`
    /// keep all but the last given component; comparisons may be combined (`>= 7.0.0 < 9.0.0`).
    static func satisfies(_ version: String, requirement: String) -> Bool? {
        let allowed = CharacterSet(charactersIn: "0123456789.<>=^~v ,*")
        guard !requirement.isEmpty, requirement.unicodeScalars.allSatisfy(allowed.contains),
              let regex = try? NSRegularExpression(pattern: #"(>=|<=|>|<|=|\^|~>|~)?\s*v?(\d+(?:\.\d+)*)"#) else { return nil }
        let installed = numbers(version)
        let matches = regex.matches(in: requirement, range: NSRange(requirement.startIndex..., in: requirement))
        guard !matches.isEmpty, !installed.isEmpty else { return nil }
        for match in matches {
            let op = Range(match.range(at: 1), in: requirement).map { String(requirement[$0]) } ?? ""
            guard let range = Range(match.range(at: 2), in: requirement) else { return nil }
            let wanted = numbers(String(requirement[range]))
            let order = compare(installed, wanted)
            let holds: Bool = switch op {
            case ">=": order >= 0
            case ">": order > 0
            case "<=": order <= 0
            case "<": order < 0
            case "^": order >= 0 && installed.first == wanted.first
            case "~", "~>": order >= 0 && Array(installed.prefix(max(1, wanted.count - 1))) == Array(wanted.prefix(max(1, wanted.count - 1)))
            default: Array(installed.prefix(wanted.count)) == wanted
            }
            if !holds { return false }
        }
        return true
    }

    private static func numbers(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0, b = index < rhs.count ? rhs[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }
}

/// A runtime the repository asks for, from a manifest or a version pin.
struct ProjectRuntimeRequirement: Equatable, Sendable {
    let language: DevLanguage
    let requirement: String?
    /// The file that declares it.
    let source: String
}

/// A requirement next to the installations Development environments discovered for its language.
struct ProjectRuntimeMatch: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// An installation's version meets the requirement.
        case installed
        /// Every installation with a known version misses it.
        case mismatch
        /// Installations exist, but their versions cannot be told from their paths, or nothing is required.
        case unknown
        /// No installation of the language was discovered.
        case notFound
    }

    struct Installation: Equatable, Sendable, Identifiable {
        let environment: DevEnvironment
        let version: String?
        let satisfies: Bool?
        var id: String { environment.id }
    }

    let requirement: ProjectRuntimeRequirement
    let installations: [Installation]
    let status: Status
    var id: String { requirement.source + ":" + requirement.language.rawValue }
    var onPath: DevEnvironment? { installations.first { $0.environment.onPath }?.environment }

    static func matches(_ requirements: [ProjectRuntimeRequirement], environments: [DevEnvironment]) -> [ProjectRuntimeMatch] {
        requirements.map { requirement in
            let installations = environments.filter { $0.language == requirement.language }.map { environment in
                let version = RuntimeVersion.fromPath(environment.executable)
                return Installation(environment: environment, version: version,
                                    satisfies: version.flatMap { version in requirement.requirement.flatMap { RuntimeVersion.satisfies(version, requirement: $0) } })
            }.sorted { lhs, rhs in
                switch (lhs.version, rhs.version) {
                case let (a?, b?): a.compare(b, options: .numeric) == .orderedDescending
                case (.some, nil): true
                default: false
                }
            }
            let status: Status = installations.isEmpty ? .notFound
                : installations.contains { $0.satisfies == true } ? .installed
                : installations.contains { $0.satisfies == false } && !installations.contains { $0.satisfies == nil } ? .mismatch
                : .unknown
            return ProjectRuntimeMatch(requirement: requirement, installations: installations, status: status)
        }
    }

    /// Requirements from manifests and from version pins that name a Development Environment language.
    static func requirements(manifests: [ProjectManifest], runtimes: [ProjectRuntime]) -> [ProjectRuntimeRequirement] {
        manifests.compactMap { manifest in
            manifest.devLanguage.map { ProjectRuntimeRequirement(language: $0, requirement: manifest.requirement, source: manifest.file) }
        } + runtimes.filter { !$0.isEnvironment }.compactMap { runtime in
            DevLanguage(rawValue: runtime.name).map { ProjectRuntimeRequirement(language: $0, requirement: runtime.version, source: runtime.marker) }
        }
    }
}
