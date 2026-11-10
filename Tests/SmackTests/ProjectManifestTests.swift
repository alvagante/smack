import Foundation
import Synchronization
import Testing
@testable import Smack

private final class Reads: Sendable {
    let paths = Mutex<[String]>([])
}

private func reader(_ files: [String: String], reads: Reads? = nil) -> ProjectManifestReader {
    ProjectManifestReader(read: { path, limit in
        reads?.paths.withLock { $0.append(path) }
        #expect(limit == ProjectManifestReader.byteLimit)
        return files[path].map { Data($0.utf8) }
    }, exists: { files[$0] != nil })
}

private func facts(_ manifest: ProjectManifest?) -> [String: String] {
    Dictionary((manifest?.facts ?? []).map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
}

@Test func manifestsReadOnlyKnownRootFilesAndSummarizeEachLanguage() {
    let root = "/work/app"
    let reads = Reads()
    let manifests = reader([
        root + "/package.json": #"{"name":"web","version":"1.2.0","type":"module","packageManager":"pnpm@9.1.0","engines":{"node":">=20"},"scripts":{"dev":"vite","build":"vite build"},"dependencies":{"react":"19","vite":"6"},"devDependencies":{"typescript":"5"}}"#,
        root + "/pnpm-lock.yaml": "lockfileVersion: '9.0'\n",
        root + "/pyproject.toml": """
        [build-system]
        build-backend = "hatchling.build"

        [project]
        name = "tool"
        version = "0.3.1"
        requires-python = ">=3.11"
        dependencies = [
            "httpx>=0.27",
            "rich",
        ]
        """,
        root + "/uv.lock": "version = 1\n",
        root + "/go.mod": "module example.com/app\n\ngo 1.22.1\n\ntoolchain go1.23.0\n\nrequire (\n\tgithub.com/a/b v1.0.0\n\tgithub.com/c/d v2.0.0 // indirect\n)\nrequire github.com/e/f v0.1.0\n",
        root + "/Cargo.toml": "[package]\nname = \"crate\"\nversion = \"0.1.0\"\nedition = \"2021\"\nrust-version = \"1.77\"\n\n[dependencies]\nserde = \"1\"\ntokio = { version = \"1\", features = [\"full\"] }\n\n[dev-dependencies]\ninsta = \"1\"\n",
        root + "/Package.swift": "// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: \"Smack\", dependencies: [\n.package(url: \"https://a\", from: \"1.0.0\"),\n])\n",
        root + "/Gemfile": "source 'https://rubygems.org'\nruby '3.3.0'\ngem 'rails', '~> 7.1'\ngem 'puma'\n# gem 'old'\n",
        root + "/metadata.json": #"{"name":"example42-psick","version":"1.0.0","author":"example42","license":"Apache-2.0","requirements":[{"name":"puppet","version_requirement":">= 7.0.0 < 9.0.0"}],"dependencies":[{"name":"puppetlabs/stdlib"}],"operatingsystem_support":[{"operatingsystem":"RedHat"},{"operatingsystem":"Debian"}]}"#,
        root + "/Puppetfile": "forge 'https://forge.puppet.com'\nmod 'puppetlabs/stdlib', '9.0.0'\nmod 'example42/psick'\n",
    ], reads: reads).manifests(root: root)

    #expect(reads.paths.withLock { $0 }.allSatisfy { $0.hasPrefix(root + "/") && !$0.dropFirst(root.count + 1).contains("/") },
            "only files directly at the repository root")
    #expect(manifests.map(\.file) == ["package.json", "pyproject.toml", "go.mod", "Cargo.toml", "Package.swift", "Gemfile",
                                      "metadata.json", "Puppetfile"])

    let node = manifests.first { $0.file == "package.json" }
    #expect(node?.language == "Node.js")
    #expect(facts(node) == ["Name": "web", "Version": "1.2.0", "Module type": "module", "Package manager": "pnpm@9.1.0",
                            "Scripts": "2: build, dev", "Dependencies": "2 + 1 dev", "Lockfile": "pnpm-lock.yaml"])
    #expect(node?.requirement == ">=20")

    let python = manifests.first { $0.file == "pyproject.toml" }
    #expect(facts(python)["Name"] == "tool" && facts(python)["Dependencies"] == "2" && facts(python)["Build backend"] == "hatchling.build")
    #expect(facts(python)["Lockfile"] == "uv.lock")
    #expect(python?.requirement == ">=3.11")

    let go = manifests.first { $0.file == "go.mod" }
    #expect(facts(go) == ["Module": "example.com/app", "Toolchain": "go1.23.0", "Requirements": "3 (1 indirect)"])
    #expect(go?.requirement == "1.22.1")

    let rust = manifests.first { $0.file == "Cargo.toml" }
    #expect(facts(rust)["Edition"] == "2021" && facts(rust)["Dependencies"] == "2 + 1 dev")
    #expect(rust?.requirement == "1.77")

    #expect(manifests.first { $0.file == "Package.swift" }?.requirement == "6.0")
    #expect(facts(manifests.first { $0.file == "Package.swift" })["Package dependencies"] == "1")
    #expect(facts(manifests.first { $0.file == "Gemfile" })["Gems"] == "2")
    #expect(manifests.first { $0.file == "Gemfile" }?.requirement == "3.3.0")

    let module = manifests.first { $0.file == "metadata.json" }
    #expect(module?.language == "Puppet")
    #expect(facts(module)["Module"] == "example42-psick" && facts(module)["Puppet"] == ">= 7.0.0 < 9.0.0")
    #expect(facts(module)["Supported OS"] == "RedHat, Debian")
    #expect(facts(manifests.first { $0.file == "Puppetfile" })["Modules"] == "2")
}

@Test func malformedManifestsShowWhatCouldBeReadWithoutFailing() {
    let manifests = reader(["/r/package.json": "{ not json", "/r/go.mod": ""]).manifests(root: "/r")
    #expect(manifests.map(\.file) == ["package.json", "go.mod"])
    #expect(manifests[0].facts.map(\.label) == ["Contents"])
    #expect(manifests[0].facts.first?.value == "Unavailable")
}

@Test func installedVersionsAreReadFromVersionManagerPaths() {
    let cases: [(String, String?)] = [
        ("/Users/u/.nvm/versions/node/v20.11.1/bin/node", "20.11.1"),
        ("/Users/u/.pyenv/versions/3.12.4/bin/python3", "3.12.4"),
        ("/opt/homebrew/Cellar/python@3.12/3.12.4_1/bin/python3", "3.12.4"),
        ("/Users/u/.local/share/mise/installs/ruby/3.3.0/bin/ruby", "3.3.0"),
        ("/Users/u/.rustup/toolchains/1.77.0-aarch64-apple-darwin/bin/rustc", "1.77.0"),
        ("/usr/local/go1.22.1/bin/go", nil),
        ("/usr/bin/python3", nil),
        ("/opt/homebrew/bin/node", nil),
    ]
    for (path, expected) in cases { #expect(RuntimeVersion.fromPath(path) == expected, "\(path)") }
}

@Test func requirementsMatchInstalledVersions() {
    let cases: [(String, String, Bool?)] = [
        ("20.11.1", "20.11.1", true), ("20.11.1", "20.11.0", false),
        ("3.12", "3.12.4", true), ("3.12", "3.11.9", false),
        (">=3.11", "3.12.4", true), (">=3.11", "3.10.2", false), (">= 7.0.0 < 9.0.0", "8.4.0", true),
        ("^18", "18.19.0", true), ("^18", "20.1.0", false), ("~> 7.1", "7.1.3", true),
        ("v20", "20.1.0", true), ("lts/iron", "20.1.0", nil), ("nightly-2024-03-01", "1.77.0", nil),
    ]
    for (requirement, version, expected) in cases {
        #expect(RuntimeVersion.satisfies(version, requirement: requirement) == expected, "\(requirement) vs \(version)")
    }
}

@Test func runtimeMatchesPairRequirementsWithInstallations() {
    let environments = [
        DevEnvironment(language: .node, executable: "/Users/u/.nvm/versions/node/v20.11.1/bin/node", resolvedPath: "", source: "nvm", onPath: false),
        DevEnvironment(language: .node, executable: "/Users/u/.nvm/versions/node/v18.19.0/bin/node", resolvedPath: "", source: "nvm", onPath: false),
        DevEnvironment(language: .node, executable: "/opt/homebrew/bin/node", resolvedPath: "", source: "Homebrew", onPath: true),
        DevEnvironment(language: .python, executable: "/usr/bin/python3", resolvedPath: "", source: "System", onPath: true),
    ]
    let requirements = [
        ProjectRuntimeRequirement(language: .node, requirement: ">=20", source: "package.json"),
        ProjectRuntimeRequirement(language: .python, requirement: ">=3.11", source: "pyproject.toml"),
        ProjectRuntimeRequirement(language: .go, requirement: "1.22.1", source: "go.mod"),
    ]
    let matches = ProjectRuntimeMatch.matches(requirements, environments: environments)
    #expect(matches.map(\.status) == [.installed, .unknown, .notFound])
    #expect(matches[0].installations.map(\.version) == ["20.11.1", "18.19.0", nil])
    #expect(matches[0].installations.map(\.satisfies) == [true, false, nil])
    #expect(matches[0].onPath?.executable == "/opt/homebrew/bin/node")
}
