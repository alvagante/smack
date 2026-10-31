import Foundation

enum BrewKind: String, CaseIterable, Sendable {
    case formula, cask
    var flag: String { "--\(rawValue)" }
    var label: String { self == .formula ? "Tool" : "App" }
}

struct BrewPackage: Identifiable, Sendable {
    let name: String
    let fullName: String
    let kind: BrewKind
    let description: String
    let installedVersion: String
    let availableVersion: String?
    let pinned: Bool
    var id: String { "\(kind.rawValue):\(fullName)" }
    var isOutdated: Bool { availableVersion != nil }
    func arguments(_ verb: String) -> [String] { [verb, kind.flag, fullName] }
}

enum BrewPackageAction: String, CaseIterable {
    case upgrade, reinstall, uninstall, pin, unpin

    var title: String { self == .upgrade ? "Update" : rawValue.capitalized }

    func isAvailable(for package: BrewPackage) -> Bool {
        switch self {
        case .upgrade: package.isOutdated && !package.pinned
        case .pin: package.kind == .formula && !package.pinned
        case .unpin: package.kind == .formula && package.pinned
        case .reinstall, .uninstall: true
        }
    }

    func operation(for package: BrewPackage) -> BrewOperation {
        var operation = BrewOperation(title: "\(title) \(package.name)?", arguments: package.arguments(rawValue))
        operation.confirmationLabel = title
        operation.destructive = self == .uninstall
        switch self {
        case .uninstall:
            operation.explanation = "Homebrew will remove this package and run its uninstall steps. Files are not moved to the Trash. Homebrew may refuse removal if installed packages depend on it."
        case .reinstall:
            operation.explanation = "Homebrew will uninstall and reinstall this package. It may download software, update dependents and clean up old versions."
        case .pin:
            operation.explanation = "Hold this tool at its current version during Homebrew upgrades."
        case .unpin:
            operation.explanation = "Allow Homebrew to upgrade this tool again."
        case .upgrade: break
        }
        return operation
    }
}

enum BrewPackageRead: String, CaseIterable, Identifiable, Sendable {
    case info = "Info", files = "Installed files"
    var id: String { rawValue }

    func arguments(for package: BrewPackage) -> [String] {
        switch self {
        case .info: package.arguments("info")
        case .files: ["list", "--verbose", package.kind.flag, package.fullName]
        }
    }
}

struct BrewService: Decodable, Identifiable, Sendable {
    let name: String
    let status: String
    let user: String?
    var id: String { name }
}

struct BrewSnapshot: Sendable {
    var packages: [BrewPackage]?
    var updatesKnown = false
    var services: [BrewService]?
    var cleanup: String?
    var managedBytes: UInt64?
    var warnings: [String] = []
    var timestamp = Date()
    var updateCount: Int? { updatesKnown ? packages?.filter(\.isOutdated).count : nil }
}

struct BrewCollector: Sendable {
    typealias Runner = @Sendable (String, [String]) async -> CommandRunner.Result
    var run: Runner = { executable, arguments in
        // GUI apps inherit a minimal PATH. Disable background network refresh and analytics.
        let readOnly = ["info", "list", "outdated", "search", "--prefix"].contains(arguments.first ?? "") ||
            arguments.contains("--dry-run") || arguments.prefix(2) == ["services", "list"] || executable == "/usr/bin/du"
        return await CommandRunner.run("/usr/bin/env", [
            "HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_ANALYTICS=1",
            "HOMEBREW_NO_ENV_HINTS=1", "HOMEBREW_NO_ASK=1", "HOMEBREW_NO_COLOR=1",
            "PATH=\(URL(fileURLWithPath: executable).deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            executable
        ] + arguments, timeout: readOnly ? 90 : nil, outputLimit: 16_000_000, cancellable: readOnly)
    }

    static func executable() -> String? {
        guard !Capabilities.isSandboxed else { return nil }
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/brew" }
        return (["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] + path)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func checked(_ result: CommandRunner.Result) throws -> String {
        guard result.status == 0, !result.timedOut, !result.truncated, !result.cancelled else {
            let message = result.timedOut ? "Homebrew timed out." :
                result.truncated ? "Homebrew output exceeded the collection limit." :
                result.cancelled ? "Homebrew command cancelled." : result.error + result.output
            throw BrewError(message: message.isEmpty ? "Homebrew exited with status \(result.status)." : message)
        }
        return result.output
    }

    private struct Info: Decodable {
        struct Formula: Decodable {
            struct Version: Decodable { let version: String }
            let name: String
            let full_name: String
            let desc: String?
            let installed: [Version]
            let pinned: Bool?
        }
        struct Cask: Decodable {
            let token: String
            let full_token: String?
            let tap: String?
            let desc: String?
            let installed: String?
        }
        let formulae: [Formula]
        let casks: [Cask]
    }

    private struct Outdated: Decodable {
        struct Entry: Decodable {
            let name: String
            let current_version: String
            let pinned: Bool?
        }
        let formulae: [Entry]
        let casks: [Entry]
    }

    static func packages(info: String, outdated: String?) throws -> [BrewPackage] {
        let info = try JSONDecoder().decode(Info.self, from: Data(info.utf8))
        let updates = try outdated.map { try JSONDecoder().decode(Outdated.self, from: Data($0.utf8)) }
        let formulae = info.formulae.map { formula in
            let update = updates?.formulae.first { $0.name == formula.full_name }
            return BrewPackage(name: formula.name, fullName: formula.full_name, kind: .formula,
                               description: formula.desc ?? "", installedVersion: formula.installed.map(\.version).joined(separator: ", "),
                               availableVersion: update?.current_version, pinned: formula.pinned ?? false)
        }
        let casks = info.casks.map { cask in
            let update = updates?.casks.first { $0.name == cask.token || $0.name == cask.full_token }
            let qualified = cask.full_token ?? cask.tap.map { "\($0)/\(cask.token)" } ?? cask.token
            return BrewPackage(name: cask.token, fullName: qualified, kind: .cask,
                               description: cask.desc ?? "", installedVersion: cask.installed ?? "Unknown",
                               availableVersion: update?.current_version, pinned: update?.pinned ?? false)
        }
        return (formulae + casks).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func collect(executable: String, details: Bool, section: BrewSection = .installed) async -> BrewSnapshot {
        var snapshot = BrewSnapshot()
        var outdated: String?
        do { outdated = try Self.checked(await run(executable, ["outdated", "--json=v2"])) }
        catch { snapshot.warnings.append("Updates unavailable: \(error.localizedDescription)") }
        do {
            let info = try Self.checked(await run(executable, ["info", "--json=v2", "--installed"]))
            do {
                snapshot.packages = try Self.packages(info: info, outdated: outdated)
                snapshot.updatesKnown = outdated != nil
            } catch {
                snapshot.packages = try Self.packages(info: info, outdated: nil)
                snapshot.warnings.append("Updates unavailable: \(error.localizedDescription)")
            }
        } catch { snapshot.warnings.append("Installed packages unavailable: \(error.localizedDescription)") }
        guard details, !Task.isCancelled else { return snapshot }
        if section == .services {
            do {
                let output = try Self.checked(await run(executable, ["services", "list", "--json"]))
                snapshot.services = try JSONDecoder().decode([BrewService].self, from: Data(output.utf8))
            } catch { snapshot.warnings.append("Services unavailable: \(error.localizedDescription)") }
        }
        if section == .cleanup {
            do { snapshot.cleanup = try Self.checked(await run(executable, ["cleanup", "--dry-run"])) }
            catch { snapshot.warnings.append("Cleanup estimate unavailable: \(error.localizedDescription)") }
            do {
                let prefix = try Self.checked(await run(executable, ["--prefix"])).trimmingCharacters(in: .whitespacesAndNewlines)
                guard prefix.hasPrefix("/") else { throw BrewError(message: "Invalid Homebrew prefix.") }
                let sizes = try Self.checked(await run("/usr/bin/du", ["-sk", "\(prefix)/Cellar"]))
                if let kilobytes = sizes.split(whereSeparator: \.isWhitespace).first.flatMap({ UInt64($0) }),
                   kilobytes <= UInt64.max / 1024 {
                    snapshot.managedBytes = kilobytes * 1024
                }
            } catch { snapshot.warnings.append("Tool storage unavailable: \(error.localizedDescription)") }
        }
        return snapshot
    }

    func inspect(executable: String, package: BrewPackage, read: BrewPackageRead) async throws -> String {
        try Self.checked(await run(executable, read.arguments(for: package)))
    }

    func search(executable: String, query: String, kind: BrewKind) async throws -> [BrewPackage] {
        let output = try Self.checked(await run(executable, ["search", kind.flag, "--", query]))
        // Non-interactive search returns one package name per line.
        return output.split(whereSeparator: \.isNewline).map(String.init).filter {
            !$0.isEmpty && !$0.contains(where: \.isWhitespace) && !$0.hasPrefix("==>")
        }.map { BrewPackage(name: $0, fullName: $0, kind: kind, description: "", installedVersion: "",
                            availableVersion: nil, pinned: false) }
    }
}

private struct BrewError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct BrewOperation: Identifiable {
    var id: String { arguments.joined(separator: " ") }
    let title: String
    let arguments: [String]
    var confirmationLabel = "Run"
    var destructive = false
    var explanation: String?
}

@MainActor
final class HomebrewMonitor: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var snapshot: BrewSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published private(set) var searching = false
    @Published private(set) var results: [BrewPackage] = []
    @Published var operation: BrewOperation?
    @Published var output = ""
    @Published var failed = false
    private var task: Task<Void, Never>?
    private let collector: BrewCollector
    private let locate: () -> String?
    var detailsWanted = false
    var section = BrewSection.installed
    private var source: String?
    private var detailDates: [BrewSection: Date] = [:]

    init(collector: BrewCollector = BrewCollector(), locate: @escaping () -> String? = BrewCollector.executable) {
        self.collector = collector
        self.locate = locate
    }

    func setVisible(_ visible: Bool) {
        task?.cancel()
        guard visible else { return }
        task = Task { [weak self] in
            guard let self else { return }
            // Brew queries are expensive. Cache between panel opens for five minutes.
            if snapshot == nil || Date().timeIntervalSince(snapshot!.timestamp) > 300 {
                await refresh(automatic: true)
            }
        }
    }

    func showDetails() async {
        detailsWanted = true
        while loading || busy || searching {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        let current = snapshot
        let cached = section == .services ? current?.services != nil : section == .cleanup ? current?.cleanup != nil && current?.managedBytes != nil : current?.packages != nil
        let date = [.services, .cleanup].contains(section) ? detailDates[section] : current?.timestamp
        if cached, let date, Date().timeIntervalSince(date) < 300, source == locate() { return }
        await refresh()
    }

    func refresh(automatic: Bool = false) async {
        guard !loading, !busy, !searching else { return }
        let executable = locate()
        installed = executable != nil
        guard let executable else { snapshot = nil; return }
        loading = true
        defer { loading = false }
        if source != executable { snapshot = nil; detailDates = [:]; source = executable }
        let requested = section
        var value = await collector.collect(executable: executable, details: detailsWanted && !automatic, section: requested)
        guard !Task.isCancelled else { return }
        if detailsWanted && !automatic { detailDates[requested] = Date() }
        if requested != .services || automatic { value.services = snapshot?.services }
        if requested != .cleanup || automatic { value.cleanup = snapshot?.cleanup; value.managedBytes = snapshot?.managedBytes }
        snapshot = value
    }

    func search(_ query: String, kind: BrewKind) async {
        guard !loading, !busy, !searching, let executable = locate() else { return }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { results = []; return }
        searching = true
        defer { searching = false }
        do { results = try await collector.search(executable: executable, query: query, kind: kind) }
        catch { results = []; output = error.localizedDescription; failed = true; operation = nil }
    }

    func inspect(_ package: BrewPackage, read: BrewPackageRead) async throws -> String {
        while loading || busy || searching {
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        guard let executable = locate() else { throw BrewError(message: "Homebrew CLI unavailable.") }
        loading = true
        defer { loading = false }
        return try await collector.inspect(executable: executable, package: package, read: read)
    }

    func perform(_ action: BrewOperation) async {
        while (loading || searching) && !busy {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard !Task.isCancelled, !busy, let executable = locate() else { return }
        busy = true
        operation = action
        output = ""
        failed = false
        let result = await collector.run(executable, action.arguments)
        do {
            _ = try BrewCollector.checked(result)
            output = result.output + result.error
            if output.isEmpty { output = "Completed successfully." }
        } catch { output = error.localizedDescription; failed = true }
        busy = false
        snapshot = nil
        detailDates = [:]
        await refresh()
    }
}
