import Foundation

// Discovery reads directory entries only. Runtime commands are deferred until an environment is opened.
enum DevLanguage: String, CaseIterable, Identifiable, Sendable {
    case python = "Python", ruby = "Ruby", erlang = "Erlang", elixir = "Elixir"
    case go = "Go", rust = "Rust", node = "Node.js", deno = "Deno", bun = "Bun"
    case java = "Java", kotlin = "Kotlin", scala = "Scala", dotnet = ".NET"
    case php = "PHP", perl = "Perl", lua = "Lua", luajit = "LuaJIT"
    case r = "R", julia = "Julia", swift = "Swift", haskell = "Haskell"
    case ocaml = "OCaml", zig = "Zig", dart = "Dart", clojure = "Clojure", c = "C / C++"
    var id: String { rawValue }
    var executables: [String] {
        switch self {
        case .python: ["python3", "python"]
        case .ruby: ["ruby"]
        case .erlang: ["erl"]
        case .elixir: ["elixir"]
        case .go: ["go"]
        case .rust: ["rustc"]
        case .node: ["node"]
        case .deno: ["deno"]
        case .bun: ["bun"]
        case .java: ["java"]
        case .kotlin: ["kotlinc"]
        case .scala: ["scala"]
        case .dotnet: ["dotnet"]
        case .php: ["php"]
        case .perl: ["perl"]
        case .lua: ["lua"]
        case .luajit: ["luajit"]
        case .r: ["R"]
        case .julia: ["julia"]
        case .swift: ["swift"]
        case .haskell: ["ghc"]
        case .ocaml: ["ocamlc"]
        case .zig: ["zig"]
        case .dart: ["dart"]
        case .clojure: ["clojure"]
        case .c: ["clang", "clang++", "gcc", "g++"]
        }
    }
    var versionArguments: [String] {
        switch self {
        case .erlang: ["-noshell", "-noinput", "-eval", "io:format(" + String(reflecting: "~s~n") + ", [erlang:system_info(otp_release)]), halt()."]
        case .go: ["version"]
        case .java, .kotlin: ["-version"]
        case .lua, .luajit: ["-v"]
        case .ocaml: ["-version"]
        case .zig: ["version"]
        case .clojure: ["-Sdescribe"]
        default: ["--version"]
        }
    }
}

struct DevEnvironment: Identifiable, Hashable, Sendable {
    let language: DevLanguage
    let executable: String
    let resolvedPath: String
    let source: String
    let onPath: Bool
    var id: String { language.rawValue + ":" + executable }
    var directory: String { URL(fileURLWithPath: executable).deletingLastPathComponent().path }
}

struct DevDiscovery: Sendable {
    var environments: [DevEnvironment] = []
    var roots: [String] = []
    var warnings: [String] = []
    var timestamp = Date()
}

struct DevReport: Identifiable, Sendable {
    let title: String
    let command: String
    let output: String
    let failed: Bool
    var id: String { title }
}

struct DevInspection: Sendable {
    var version = "Unavailable"
    var reports: [DevReport] = []
}

struct DevEnvironmentCollector: Sendable {
    typealias Runner = @Sendable (String, [String]) async -> CommandRunner.Result
    var run: Runner = { executable, arguments in
        await CommandRunner.run(executable, arguments, timeout: 10, outputLimit: 1_000_000)
    }

    static func discover(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                         environment: [String: String] = ProcessInfo.processInfo.environment,
                         folders: [String] = [], includeSystem: Bool = true) -> DevDiscovery {
        let fm = FileManager.default
        var snapshot = DevDiscovery()
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        var bins: [(String, String)] = []
        func bin(_ path: String, _ source: String) { bins.append((path, source)) }
        func children(_ root: String) -> [String] {
            guard fm.fileExists(atPath: root) else { return [] }
            do { return try fm.contentsOfDirectory(atPath: root).sorted().filter { !$0.hasPrefix(".") }.map { root + "/" + $0 } }
            catch { snapshot.warnings.append("Cannot read \(root): \(error.localizedDescription)"); return [] }
        }
        func versions(_ root: String, _ source: String, suffix: String = "/bin") {
            guard fm.fileExists(atPath: root) else { return }
            snapshot.roots.append(root)
            for version in children(root) { bin(version + suffix, source) }
        }
        for directory in path { bin(directory, "Inherited PATH") }
        if includeSystem {
            for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", home + "/.local/bin", home + "/.cargo/bin", home + "/.bun/bin", home + "/.deno/bin", "/Library/Developer/CommandLineTools/usr/bin", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"] {
                bin(directory, "Standard location")
            }
            for prefix in ["/opt/homebrew", "/usr/local"] {
                for formula in children(prefix + "/opt") { bin(formula + "/bin", "Homebrew"); bin(formula + "/libexec/bin", "Homebrew") }
            }
        }
        for (key, fallback, name) in [("PYENV_ROOT", "/.pyenv", "pyenv"), ("RBENV_ROOT", "/.rbenv", "rbenv"), ("NODENV_ROOT", "/.nodenv", "nodenv")] {
            versions((environment[key] ?? home + fallback) + "/versions", name)
        }
        versions((environment["NVM_DIR"] ?? home + "/.nvm") + "/versions/node", "nvm")
        for root in [home + "/Library/Application Support/fnm/node-versions", home + "/.local/share/fnm/node-versions"] {
            versions(root, "fnm", suffix: "/installation/bin")
        }
        for root in [(environment["ASDF_DATA_DIR"] ?? home + "/.asdf") + "/installs", (environment["MISE_DATA_DIR"] ?? home + "/.local/share/mise") + "/installs"] {
            for tool in children(root) { versions(tool, root.contains("mise") ? "mise" : "asdf") }
        }
        versions((environment["RUSTUP_HOME"] ?? home + "/.rustup") + "/toolchains", "rustup")
        versions(home + "/.gvm/gos", "gvm")
        versions(home + "/sdk", "Go SDK")
        versions(home + "/.rvm/rubies", "RVM")
        versions(home + "/.rubies", "chruby")
        for tool in children((environment["SDKMAN_DIR"] ?? home + "/.sdkman") + "/candidates") { versions(tool, "SDKMAN") }
        for root in (includeSystem ? ["/Library/Java/JavaVirtualMachines"] : []) + [home + "/Library/Java/JavaVirtualMachines"] { versions(root, "JDK", suffix: "/Contents/Home/bin") }
        if includeSystem {
            versions("/Library/Frameworks/Python.framework/Versions", "Python framework")
            versions("/Library/Frameworks/R.framework/Versions", "R framework", suffix: "/Resources/bin")
        }
        versions(home + "/.julia/juliaup", "juliaup")
        versions(home + "/.opam", "opam")
        versions(home + "/.local/share/uv/python", "uv")
        for root in [home + "/.virtualenvs", home + "/.local/share/pipx/venvs", home + "/Library/Caches/pypoetry/virtualenvs", home + "/.cache/pypoetry/virtualenvs", home + "/.conda/envs"] { versions(root, "Python environment") }
        for root in [home + "/miniconda3", home + "/anaconda3", home + "/miniforge3", environment["CONDA_PREFIX"]].compactMap({ $0 }) {
            bin(root + "/bin", "Conda"); versions(root + "/envs", "Conda")
        }
        if includeSystem {
            for root in ["/opt/anaconda3", "/opt/miniconda3"] { bin(root + "/bin", "Conda"); versions(root + "/envs", "Conda") }
        }
        bin(home + "/.dotnet", ".NET user installation")
        if let venv = environment["VIRTUAL_ENV"] { bin(venv + "/bin", "Active virtualenv") }
        // Explicit project roots only: never crawl the entire home directory or dependency caches.
        let ignored: Set<String> = [".git", "node_modules", "vendor", "target", ".build", "Library", "__pycache__", "site-packages"]
        for folder in folders {
            snapshot.roots.append(folder)
            bin(folder, "Custom folder")
            var remaining = 10_000
            func scan(_ directory: String, depth: Int) {
                guard depth <= 4, remaining > 0, !Task.isCancelled else { return }
                remaining -= 1
                bin(directory + "/bin", "Project / virtualenv")
                if fm.fileExists(atPath: directory + "/pyvenv.cfg") { return }
                for child in (try? fm.contentsOfDirectory(atPath: directory)) ?? [] {
                    guard !ignored.contains(child), !child.hasPrefix(".") || [".venv", ".env"].contains(child) else { continue }
                    let url = URL(fileURLWithPath: directory + "/" + child)
                    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { continue }
                    scan(url.path, depth: depth + 1)
                }
            }
            scan(folder, depth: 0)
            if remaining == 0 { snapshot.warnings.append("Project scan limited to 10,000 directories: \(folder)") }
        }
        var seen = Set<String>()
        for (directory, source) in bins {
            guard !Task.isCancelled else { break }
            // Shims select a version from shell/project state and may auto-install; inspect concrete installations instead.
            guard !directory.contains("/shims") else { continue }
            for language in DevLanguage.allCases {
                let names = language == .python ? ((try? fm.contentsOfDirectory(atPath: directory)) ?? []).filter {
                    $0 == "python" || $0 == "python3" || $0.range(of: #"^python[23]\.[0-9]+$"#, options: .regularExpression) != nil
                }.sorted() : language.executables
                for name in names {
                    let executable = URL(fileURLWithPath: directory + "/" + name).standardizedFileURL.path
                    guard fm.isExecutableFile(atPath: executable) else { continue }
                    let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
                    // Virtualenvs often symlink the same interpreter but have different prefixes and packages.
                    let identity = language.rawValue + ":" + (language == .python && fm.fileExists(atPath: URL(fileURLWithPath: directory).deletingLastPathComponent().appendingPathComponent("pyvenv.cfg").path) ? directory + ":" + resolved : resolved)
                    guard seen.insert(identity).inserted else { continue }
                    snapshot.environments.append(DevEnvironment(language: language, executable: executable, resolvedPath: resolved, source: source, onPath: path.contains(directory)))
                    if snapshot.environments.count == 512 {
                        snapshot.warnings.append("Discovery limited to 512 runtime installations. Narrow project folders to inspect more.")
                        return snapshot
                    }
                }
            }
        }
        snapshot.environments.sort { ($0.language.rawValue, $0.executable) < ($1.language.rawValue, $1.executable) }
        snapshot.roots = Array(Set(snapshot.roots + bins.map(\.0).filter { fm.fileExists(atPath: $0) })).sorted()
        return snapshot
    }

    func inspect(_ item: DevEnvironment) async -> DevInspection {
        var inspection = DevInspection()
        func report(_ title: String, executable: String, arguments: [String]) async -> DevReport {
            // Pair companion tools with this installation, with a deterministic PATH for GUI launches.
            let result = await run("/usr/bin/env", ["PATH=\(item.directory):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "DOTNET_CLI_TELEMETRY_OPTOUT=1", "DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1", "GOTOOLCHAIN=local", "RUSTUP_AUTO_INSTALL=0", executable] + arguments)
            var output = (result.output + result.error).trimmingCharacters(in: .whitespacesAndNewlines)
            if result.timedOut { output += "\nTimed out after 10 seconds." }
            if result.truncated { output += "\nOutput limited to 1 MB." }
            let failed = result.status != 0 || result.timedOut || result.truncated || result.cancelled
            if output.isEmpty { output = failed ? "Unavailable (exit \(result.status))." : "No entries reported." }
            return DevReport(title: title, command: ([executable] + arguments).map { String(reflecting: $0) }.joined(separator: " "), output: output, failed: failed)
        }
        let version = await report("Runtime version", executable: item.executable, arguments: item.language.versionArguments)
        inspection.version = version.failed ? "Unavailable" : version.output
        inspection.reports.append(version)
        func add(_ title: String, _ arguments: [String], companion: String? = nil) async {
            guard !Task.isCancelled else { return }
            let executable = companion.map { item.directory + "/" + $0 } ?? item.executable
            inspection.reports.append(await report(title, executable: executable, arguments: arguments))
        }
        switch item.language {
        case .python:
            await add("Paths and installed distributions", ["-I", "-c", #"""
            import sys, site, importlib.metadata as metadata
            print('Executable:', sys.executable)
            print('Prefix:', sys.prefix)
            print('Base prefix:', sys.base_prefix)
            print('Virtualenv:', sys.prefix != sys.base_prefix)
            print('User site (disabled in isolated probe):', site.getusersitepackages())
            print('Import paths:')
            print('\n'.join(sys.path))
            def show(distributions):
                print('\n'.join(sorted(
                    (d.metadata.get('Name') or '?') + '==' + d.version + '  ' + str(d.locate_file(''))
                    for d in distributions
                )))
            print('\nInstalled distributions (isolated interpreter):')
            show(metadata.distributions())
            print('\nUser-site distributions (not enabled in isolated probe):')
            show(metadata.distributions(path=[site.getusersitepackages()]))
            """#])
        case .ruby:
            await add("Gem paths and installed gems", ["-r", "rubygems", "-e", ##"puts 'Gem paths:', Gem.path, '\nInstalled gems:'; Gem::Specification.sort_by(&:name).each { |s| puts "#{s.name} (#{s.version})  #{s.full_gem_path}" }"##])
        case .node:
            await add("Global packages", [item.directory + "/npm", "ls", "--global", "--depth=0", "--json" ])
            await add("Runtime paths and ABI", ["-p", "JSON.stringify({executable:process.execPath,versions:process.versions,globalPaths:require('module').globalPaths},null,2)"])
        case .go:
            await add("SDK, workspace and module cache", ["env", "-json", "GOROOT", "GOPATH", "GOBIN", "GOMODCACHE", "GOCACHE", "GOOS", "GOARCH", "GOTOOLCHAIN"])
        case .rust:
            await add("Compiler, host and sysroot", ["-vV"])
            await add("Sysroot", ["--print", "sysroot"])
            await add("Installed Cargo binaries", ["install", "--list"], companion: "cargo")
        case .erlang:
            await add("OTP libraries and code paths", ["-noshell", "-noinput", "-eval", #"io:format("Root: ~s~nCode paths:~n~p~n", [code:root_dir(), code:get_path()]), halt()."#])
        case .elixir:
            await add("Runtime and code paths", ["-e", #"IO.inspect(System.build_info()); IO.inspect(:code.get_path(), label: "Code paths", limit: :infinity)"#])
        case .java:
            await add("JVM properties and paths", ["-XshowSettings:properties", "-version"])
            await add("JDK modules", ["--list-modules"])
        case .dotnet:
            await add("SDKs", ["--list-sdks"]); await add("Runtimes", ["--list-runtimes"])
        case .php: await add("Loaded extensions", ["-m"]); await add("Configuration paths", ["--ini"])
        case .perl: await add("Build and library paths", ["-V"])
        case .r:
            await add("Library paths and installed packages", ["--vanilla", "--slave", "-e", #"cat('Library paths:\n', .libPaths(), sep='\n'); p <- installed.packages(); write.table(p[,c('Package','Version','LibPath')], row.names=FALSE, quote=FALSE, sep='\t')"#])
        case .julia:
            await add("Load and depot paths", ["--startup-file=no", "-e", #"println("Load paths: ", LOAD_PATH); println("Depot paths: ", DEPOT_PATH); using Pkg; Pkg.status()"#])
        case .swift: await add("Toolchain and target paths", ["-print-target-info"])
        case .haskell: await add("Installed packages", ["list"], companion: "ghc-pkg")
        case .ocaml: await add("Standard library path", ["-where"])
        case .zig: await add("Compiler environment", ["env"])
        case .deno: await add("Cache paths", ["info", "--json"])
        case .lua, .luajit: await add("Module search paths", ["-e", "print(package.path); print(package.cpath)"])
        case .c:
            await add("Compiler and linker search paths", ["-print-search-dirs"])
            if item.executable.contains("clang") { await add("Compiler resource directory", ["-print-resource-dir"]) }
        case .bun, .kotlin, .scala, .dart, .clojure: break
        }
        return inspection
    }
}

@MainActor
final class DevEnvironmentMonitor: ObservableObject {
    @Published private(set) var snapshot: DevDiscovery?
    @Published private(set) var loading = false
    @Published private(set) var inspecting: String?
    @Published private(set) var inspections: [String: DevInspection] = [:]
    @Published private(set) var folders: [String] = []
    private var task: Task<Void, Never>?
    private var generation = 0
    private let collector: DevEnvironmentCollector
    private let discover: @Sendable ([String]) async -> DevDiscovery

    init(collector: DevEnvironmentCollector = DevEnvironmentCollector(),
         discover: @escaping @Sendable ([String]) async -> DevDiscovery = { folders in
             await Task.detached(priority: .utility) { DevEnvironmentCollector.discover(folders: folders) }.value
         }) {
        self.collector = collector
        self.discover = discover
    }

    func setVisible(_ visible: Bool) {
        task?.cancel()
        guard visible else { return }
        task = Task { [weak self] in
            guard let self else { return }
            if snapshot == nil || Date().timeIntervalSince(snapshot!.timestamp) > 300 { await refresh() }
        }
    }

    func addFolder(_ path: String) async {
        guard !folders.contains(path) else { return }
        folders.append(path)
        await refresh()
    }

    func refresh() async {
        guard !loading, !Capabilities.isSandboxed else { return }
        loading = true
        generation += 1
        defer { loading = false }
        let value = await discover(folders)
        guard !Task.isCancelled else { return }
        snapshot = value
        inspections = [:]
    }

    func inspect(_ item: DevEnvironment) async {
        guard inspections[item.id] == nil else { return }
        let started = generation
        inspecting = item.id
        defer { if inspecting == item.id { inspecting = nil } }
        let value = await collector.inspect(item)
        guard !Task.isCancelled else { return }
        guard started == generation else { return }
        inspections[item.id] = value
    }
}
