import AppKit

enum StartupCategory: String, CaseIterable, Identifiable, Sendable {
    case loginItems = "Open at Login"
    case backgroundItems = "App Background Items"
    case agents = "Launch Agents"
    case daemons = "Launch Daemons"
    case scheduled = "Scheduled Jobs"
    case apple = "Apple"
    var id: Self { self }
}

enum LaunchdDomain: Equatable, Sendable {
    case user
    case system
}

enum StartupControl: Equatable, Sendable {
    case launchd(LaunchdDomain, label: String)
    case loginItem(path: String)
    case cron(line: String)
    case readOnly
}

struct StartupItem: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var detail: String
    var category: StartupCategory
    var path: String?
    var program: String?
    var trigger: String?
    var developer: String?
    var isEnabled: Bool
    var pid: Int32?
    var note: String?
    var control: StartupControl

    var requiresAdministrator: Bool {
        if case .launchd(.system, _) = control { return true }
        return false
    }

    var isReadOnly: Bool { control == .readOnly }

    /// Labels identify launchd jobs far better than display names, which are often just an executable.
    var searchTerm: String {
        switch control {
        case .launchd, .readOnly: return detail
        case .loginItem, .cron: return name
        }
    }
}

struct StartupInventory: Sendable {
    var timestamp: Date
    var items: [StartupItem]
    var warnings: [String]
    /// Open at Login apps and app background items come only from the password-gated BTM dump.
    var includesBackgroundTasks: Bool
    /// Categories this scan actually covered. A partial scan leaves out the categories that come only from the
    /// background task dump, so change detection must not read their absence as removal.
    var includedCategories: Set<StartupCategory> = Set(StartupCategory.allCases)

    static let backgroundTaskCategories: Set<StartupCategory> = [.loginItems, .backgroundItems]
}

/// One `sfltool dumpbtm` record: the Background Task Management view of login items,
/// app-registered agents and daemons, and legacy launchd plists.
struct BTMRecord: Equatable, Sendable {
    var uid: Int
    var name: String?
    var developer: String?
    var type: String
    var disposition: Set<String>
    var identifier: String
    var url: String?
    var executablePath: String?
    var bundleIdentifier: String?
    var parentIdentifier: String?

    /// Identifiers carry the numeric type as a prefix, e.g. `8.com.example.agent`.
    var label: String {
        guard let dot = identifier.firstIndex(of: "."), Int(identifier[..<dot]) != nil else { return identifier }
        return String(identifier[identifier.index(after: dot)...])
    }

    var isAllowed: Bool { !disposition.contains("disallowed") }
    var isEnabled: Bool { disposition.contains("enabled") }
}

enum LaunchdLocation: CaseIterable, Sendable {
    case userAgents
    case globalAgents
    case globalDaemons
    case appleAgents
    case appleDaemons

    var directory: String {
        switch self {
        case .userAgents: return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents").path
        case .globalAgents: return "/Library/LaunchAgents"
        case .globalDaemons: return "/Library/LaunchDaemons"
        case .appleAgents: return "/System/Library/LaunchAgents"
        case .appleDaemons: return "/System/Library/LaunchDaemons"
        }
    }

    var domain: LaunchdDomain {
        switch self {
        case .userAgents, .globalAgents, .appleAgents: return .user
        case .globalDaemons, .appleDaemons: return .system
        }
    }

    var category: StartupCategory {
        switch self {
        case .userAgents, .globalAgents: return .agents
        case .globalDaemons: return .daemons
        case .appleAgents, .appleDaemons: return .apple
        }
    }

    var scope: String {
        switch self {
        case .userAgents: return "Current user"
        case .globalAgents: return "All users"
        case .globalDaemons: return "System"
        case .appleAgents: return "Apple agent"
        case .appleDaemons: return "Apple daemon"
        }
    }
}

struct LaunchdPlist: Equatable, Sendable {
    var path: String
    var location: LaunchdLocation
    var label: String
    var program: String?
    var trigger: String
    var disabled: Bool

    static func parse(_ data: Data, path: String, location: LaunchdLocation) -> LaunchdPlist? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String else { return nil }
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        return LaunchdPlist(
            path: path,
            location: location,
            label: label,
            program: program,
            trigger: trigger(plist),
            disabled: plist["Disabled"] as? Bool ?? false
        )
    }

    static func trigger(_ plist: [String: Any]) -> String {
        var triggers: [String] = []
        if plist["RunAtLoad"] as? Bool == true { triggers.append("At load") }
        if let keepAlive = plist["KeepAlive"], keepAlive as? Bool != false { triggers.append("Kept alive") }
        if let interval = plist["StartInterval"] as? Int, interval > 0 { triggers.append("Every \(intervalText(interval))") }
        if plist["StartCalendarInterval"] != nil { triggers.append("Calendar schedule") }
        if plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil || plist["StartOnMount"] as? Bool == true {
            triggers.append("On file change")
        }
        return triggers.isEmpty ? "On demand" : triggers.joined(separator: " · ")
    }

    private static func intervalText(_ seconds: Int) -> String {
        if seconds % 3600 == 0 { return "\(seconds / 3600)h" }
        if seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }
}

/// Parsers for undocumented but stable `launchctl` and `sfltool` text output.
enum StartupParsers {
    static func btmRecords(_ output: String) -> [BTMRecord] {
        var records: [BTMRecord] = []
        var uid = 0
        var fields: [String: String]?

        func flush() {
            guard let current = fields, let type = current["Type"], let identifier = current["Identifier"] else { return }
            records.append(BTMRecord(
                uid: uid,
                name: value(current["Name"]),
                developer: value(current["Developer Name"]),
                type: type.components(separatedBy: " (").first ?? type,
                disposition: disposition(current["Disposition"] ?? ""),
                identifier: identifier,
                url: value(current["URL"]),
                executablePath: value(current["Executable Path"]),
                bundleIdentifier: value(current["Bundle Identifier"]),
                parentIdentifier: value(current["Parent Identifier"])
            ))
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID ") {
                flush()
                fields = nil
                let number = line.dropFirst("Records for UID ".count).prefix { $0 == "-" || $0.isNumber }
                uid = Int(number) ?? uid
            } else if line.hasPrefix("#"), line.hasSuffix(":"), Int(line.dropFirst().dropLast()) != nil {
                flush()
                fields = [:]
            } else if fields != nil, let colon = line.range(of: ": ") {
                fields?[String(line[..<colon.lowerBound])] = String(line[colon.upperBound...])
            }
        }
        flush()
        return records
    }

    /// `launchctl print-disabled` reports `=> disabled`/`=> enabled`, or `=> true`/`=> false` on older systems.
    static func disabledOverrides(_ output: String) -> [String: Bool] {
        var overrides: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            overrides[label] = state == "disabled" || state == "true"
        }
        return overrides
    }

    /// Running PIDs from the `services = { … }` block of `launchctl print <domain>`.
    static func runningServices(_ output: String) -> [String: Int32] {
        var running: [String: Int32] = [:]
        var inServices = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "services = {" { inServices = true; continue }
            guard inServices else { continue }
            if trimmed == "}" { break }
            let columns = trimmed.split(whereSeparator: \.isWhitespace)
            guard columns.count == 3, let pid = Int32(columns[0]), pid > 0 else { continue }
            running[String(columns[2])] = pid
        }
        return running
    }

    static let cronDisabledMarker = "#smack-disabled# "

    /// Job lines from `crontab -l`, including ones Smack commented out; environment assignments are skipped.
    static func cronJobs(_ crontab: String) -> [(line: String, enabled: Bool)] {
        crontab.split(separator: "\n").compactMap { raw in
            let line = String(raw)
            if line.hasPrefix(cronDisabledMarker) { return (line, false) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\s*="#, options: .regularExpression) == nil else { return nil }
            return (line, true)
        }
    }

    static func crontab(_ crontab: String, setting line: String, enabled: Bool) -> String? {
        var lines = crontab.components(separatedBy: "\n")
        guard let index = lines.firstIndex(of: enabled ? cronDisabledMarker + line : line) else { return nil }
        lines[index] = enabled ? line : cronDisabledMarker + line
        var result = lines.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    private static func value(_ raw: String?) -> String? {
        guard let raw, raw != "(null)", !raw.isEmpty else { return nil }
        return raw
    }

    private static func disposition(_ raw: String) -> Set<String> {
        guard let open = raw.firstIndex(of: "["), let close = raw.firstIndex(of: "]") else { return [] }
        return Set(raw[raw.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }
}

struct StartupSources: Sendable {
    var plists: [LaunchdPlist] = []
    var btm: [BTMRecord] = []
    var userOverrides: [String: Bool] = [:]
    var systemOverrides: [String: Bool] = [:]
    var userRunning: [String: Int32] = [:]
    var systemRunning: [String: Int32] = [:]
    var runningApplications: [String: Int32] = [:]
    var crontab = ""
    var removedLoginItems: [String] = []
    var uid = Int(getuid())
    var ownBundlePath = Bundle.main.bundleURL.path
}

enum StartupItemCollector {
    static func collect(includeBackgroundTasks: Bool, removedLoginItems: [String]) async -> StartupInventory {
        let uid = getuid()
        // `sfltool dumpbtm` always shows an administrator password prompt, so it only runs on request.
        async let btm = includeBackgroundTasks
            ? StartupCommand.run("/usr/bin/sfltool", ["dumpbtm"])
            : StartupCommand.Output(status: 0, output: "", error: "")
        async let userDisabled = StartupCommand.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"])
        async let systemDisabled = StartupCommand.run("/bin/launchctl", ["print-disabled", "system"])
        async let userServices = StartupCommand.run("/bin/launchctl", ["print", "gui/\(uid)"])
        async let systemServices = StartupCommand.run("/bin/launchctl", ["print", "system"])
        async let crontab = StartupCommand.run("/usr/bin/crontab", ["-l"])
        async let plists = Task.detached(priority: .utility) { readPlists() }.value

        var warnings: [String] = []
        let btmOutput = await btm
        let includesBackgroundTasks = includeBackgroundTasks && btmOutput.status == 0
        if includeBackgroundTasks && !includesBackgroundTasks {
            let reason = btmOutput.error.trimmingCharacters(in: .whitespacesAndNewlines)
            warnings.append("The full scan was cancelled or failed\(reason.isEmpty ? "" : " (\(reason))"). Showing only items visible without a password.")
        }
        let sources = StartupSources(
            plists: await plists,
            btm: StartupParsers.btmRecords(btmOutput.output),
            userOverrides: StartupParsers.disabledOverrides(await userDisabled.output),
            systemOverrides: StartupParsers.disabledOverrides(await systemDisabled.output),
            userRunning: StartupParsers.runningServices(await userServices.output),
            systemRunning: StartupParsers.runningServices(await systemServices.output),
            runningApplications: Dictionary(
                NSWorkspace.shared.runningApplications.compactMap { app in app.bundleURL.map { ($0.standardizedFileURL.path, app.processIdentifier) } },
                uniquingKeysWith: { first, _ in first }
            ),
            crontab: await crontab.output,
            removedLoginItems: includesBackgroundTasks ? removedLoginItems : []
        )
        return StartupInventory(
            timestamp: Date(),
            items: items(from: sources),
            warnings: warnings,
            includesBackgroundTasks: includesBackgroundTasks,
            includedCategories: includesBackgroundTasks
                ? Set(StartupCategory.allCases)
                : Set(StartupCategory.allCases).subtracting(StartupInventory.backgroundTaskCategories)
        )
    }

    static func items(from sources: StartupSources) -> [StartupItem] {
        var items: [StartupItem] = []
        let btmByPath = Dictionary(sources.btm.compactMap { record in record.url.flatMap { URL(string: $0)?.path }.map { ($0, record) } }, uniquingKeysWith: { first, _ in first })
        let btmByIdentifier = Dictionary(sources.btm.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })

        func overrides(_ domain: LaunchdDomain) -> [String: Bool] { domain == .user ? sources.userOverrides : sources.systemOverrides }
        func running(_ domain: LaunchdDomain) -> [String: Int32] { domain == .user ? sources.userRunning : sources.systemRunning }
        func blockedNote(_ record: BTMRecord?) -> String? {
            record?.isAllowed == false ? "Not allowed to run in the background (System Settings › Login Items)" : nil
        }

        var plistLabels = Set<String>()
        for plist in sources.plists {
            let domain = plist.location.domain
            plistLabels.insert(plist.label)
            let record = btmByPath[plist.path]
            items.append(StartupItem(
                id: "launchd:\(plist.path)",
                name: record?.name ?? plist.label,
                detail: plist.label,
                category: plist.location.category,
                path: plist.path,
                program: plist.program,
                trigger: "\(plist.location.scope) · \(plist.trigger)",
                developer: record?.developer,
                isEnabled: !(overrides(domain)[plist.label] ?? plist.disabled),
                pid: running(domain)[plist.label],
                note: blockedNote(record),
                control: plist.location.category == .apple ? .readOnly : .launchd(domain, label: plist.label)
            ))
        }

        for record in sources.btm {
            let isDaemon = record.type == "daemon"
            guard isDaemon || (record.uid == sources.uid && ["login item", "agent"].contains(record.type)),
                  !plistLabels.contains(record.label) else { continue }
            let domain: LaunchdDomain = isDaemon ? .system : .user
            let parent = record.parentIdentifier.flatMap { btmByIdentifier[$0] }
            let parentPath = parent?.url.flatMap { URL(string: $0)?.path }
            // Bundled items report paths relative to their parent application.
            let program = (record.executablePath ?? record.url?.removingPercentEncoding).map { path in
                guard !path.hasPrefix("/"), let parentPath else { return path }
                return URL(fileURLWithPath: parentPath).appendingPathComponent(path).path
            }
            items.append(StartupItem(
                id: "btm:\(record.uid):\(record.identifier)",
                name: parent?.name ?? record.name ?? record.label,
                detail: record.label,
                category: .backgroundItems,
                path: parentPath,
                program: program,
                trigger: record.type.capitalized,
                developer: record.developer ?? parent?.developer,
                isEnabled: !(overrides(domain)[record.label] ?? false),
                pid: running(domain)[record.label],
                note: blockedNote(record) ?? (record.isEnabled ? nil : "Turned off by its application"),
                control: .launchd(domain, label: record.label)
            ))
        }

        var loginPaths = Set<String>()
        for record in sources.btm where record.uid == sources.uid && record.type == "app" && record.isEnabled {
            guard let path = record.url.flatMap({ URL(string: $0)?.standardizedFileURL.path }),
                  path != URL(fileURLWithPath: sources.ownBundlePath).standardizedFileURL.path else { continue }
            loginPaths.insert(path)
            items.append(loginItem(path: path, name: record.name, developer: record.developer, enabled: true, pid: sources.runningApplications[path]))
        }
        for path in sources.removedLoginItems where !loginPaths.contains(path) {
            items.append(loginItem(path: path, name: nil, developer: nil, enabled: false, pid: sources.runningApplications[path]))
        }

        for (index, job) in StartupParsers.cronJobs(sources.crontab).enumerated() {
            let line = job.enabled ? job.line : String(job.line.dropFirst(StartupParsers.cronDisabledMarker.count))
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            let isMacro = line.hasPrefix("@")
            let schedule = isMacro ? String(fields.first ?? "") : fields.prefix(5).joined(separator: " ")
            let command = isMacro ? fields.dropFirst().joined(separator: " ") : (fields.count > 5 ? String(fields[5]) : line)
            items.append(StartupItem(
                id: "cron:\(index):\(line)",
                name: command,
                detail: schedule,
                category: .scheduled,
                trigger: "crontab · \(schedule)",
                isEnabled: job.enabled,
                control: .cron(line: line)
            ))
        }

        return items.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func loginItem(path: String, name: String?, developer: String?, enabled: Bool, pid: Int32?) -> StartupItem {
        StartupItem(
            id: "login:\(path)",
            name: name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            detail: path,
            category: .loginItems,
            path: path,
            trigger: "At login",
            developer: developer,
            isEnabled: enabled,
            pid: pid,
            control: .loginItem(path: path)
        )
    }

    private static func readPlists() -> [LaunchdPlist] {
        LaunchdLocation.allCases.flatMap { location -> [LaunchdPlist] in
            let directory = URL(fileURLWithPath: location.directory, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "plist" }.compactMap { url in
                (try? Data(contentsOf: url)).flatMap { LaunchdPlist.parse($0, path: url.path, location: location) }
            }
        }
    }
}

enum StartupToggleResult: Equatable, Sendable {
    case completed
    case cancelled
    case failed(String)
}

/// Changes only what starts at the next login or boot; running processes are left alone.
enum StartupItemController {
    static func setEnabled(_ enabled: Bool, control: StartupControl) async -> StartupToggleResult {
        let action = enabled ? "enable" : "disable"
        switch control {
        case .launchd(.user, let label):
            return result(await StartupCommand.run("/bin/launchctl", [action, "gui/\(getuid())/\(label)"]))
        case .launchd(.system, let label):
            let prompt = "Smack wants to \(action) the launch daemon \(label) at startup."
            return result(await StartupCommand.run("/usr/bin/osascript", script([
                "on run argv",
                "do shell script \"/bin/launchctl \" & (quoted form of item 1 of argv) & \" \" & (quoted form of item 2 of argv) with prompt \(appleScriptString(prompt)) with administrator privileges",
                "end run"
            ], arguments: [action, "system/\(label)"])))
        case .loginItem(let path):
            let command = enabled
                ? "tell application \"System Events\" to make login item at end with properties {path:(item 1 of argv), hidden:false}"
                : "tell application \"System Events\" to delete (every login item whose path is (item 1 of argv))"
            return result(await StartupCommand.run("/usr/bin/osascript", script(["on run argv", command, "end run"], arguments: [path])))
        case .cron(let line):
            let current = await StartupCommand.run("/usr/bin/crontab", ["-l"])
            guard current.status == 0, let updated = StartupParsers.crontab(current.output, setting: line, enabled: enabled) else {
                return .failed("The crontab changed since it was read. Refresh and try again.")
            }
            return result(await StartupCommand.run("/usr/bin/crontab", ["-"], input: updated))
        case .readOnly:
            return .failed("This item cannot be changed from Smack.")
        }
    }

    static func result(_ output: StartupCommand.Output) -> StartupToggleResult {
        if output.status == 0 { return .completed }
        // AppleScript reports a dismissed password prompt as error -128.
        if output.error.contains("(-128)") { return .cancelled }
        if output.error.contains("(-1743)") {
            return .failed("Smack is not allowed to control System Events. Allow it in System Settings › Privacy & Security › Automation.")
        }
        let message = output.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? "The command exited with status \(output.status)." : message)
    }

    private static func script(_ lines: [String], arguments: [String]) -> [String] {
        lines.flatMap { ["-e", $0] } + arguments
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

enum StartupCommand {
    struct Output: Sendable {
        var status: Int32
        var output: String
        var error: String
    }

#if SMACK_APP_STORE
    static func run(_ executable: String, _ arguments: [String], input: String? = nil) async -> Output {
        Output(status: -1, output: "", error: "Unavailable in the App Store build.")
    }
#else
    /// Pipe reads block, so they run on GCD rather than the cooperative thread pool.
    static func run(_ executable: String, _ arguments: [String], input: String? = nil) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(executable, arguments, input: input))
            }
        }
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], input: String?) -> Output {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Output(status: -1, output: "", error: error.localizedDescription)
        }
        if let inputPipe, let input {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }
        // Drain stderr concurrently so a full pipe cannot stall the child while stdout is read.
        nonisolated(unsafe) var errorData = Data()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self),
            error: String(decoding: errorData, as: UTF8.self)
        )
    }
#endif
}

@MainActor
final class StartupItemsModel: ObservableObject {
    @Published private(set) var inventory: StartupInventory?
    @Published private(set) var isLoading = false
    @Published private(set) var pending: Set<String> = []
    @Published var query = ""
    @Published var showApple = false
    @Published var error: String?
    /// Called after every successful scan, including partial ones.
    var onInventory: ((StartupInventory) -> Void)?
    private let defaults: UserDefaults
    private var loadTask: Task<Void, Never>?
    static let removedLoginItemsKey = "startupItems.removedLoginItems"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var removedLoginItems: [String] { defaults.stringArray(forKey: Self.removedLoginItemsKey) ?? [] }

    /// Refreshing repeats the last kind of scan, so a full scan stays full.
    func load(includeBackgroundTasks: Bool? = nil) {
        guard !isLoading else { return }
        let includeBackgroundTasks = includeBackgroundTasks ?? inventory?.includesBackgroundTasks ?? false
        isLoading = true
        loadTask = Task {
            let result = await StartupItemCollector.collect(
                includeBackgroundTasks: includeBackgroundTasks,
                removedLoginItems: removedLoginItems
            )
            guard !Task.isCancelled else { return }
            inventory = result
            isLoading = false
            onInventory?(result)
        }
    }

    func setEnabled(_ enabled: Bool, for item: StartupItem) {
        guard !pending.contains(item.id) else { return }
        pending.insert(item.id)
        Task {
            let result = await StartupItemController.setEnabled(enabled, control: item.control)
            pending.remove(item.id)
            switch result {
            case .completed:
                if case .loginItem(let path) = item.control {
                    var removed = removedLoginItems.filter { $0 != path }
                    if !enabled { removed.append(path) }
                    defaults.set(removed, forKey: Self.removedLoginItemsKey)
                }
                if let index = inventory?.items.firstIndex(where: { $0.id == item.id }) {
                    inventory?.items[index].isEnabled = enabled
                }
            case .cancelled:
                break
            case .failed(let message):
                error = "\(item.name) could not be \(enabled ? "enabled" : "disabled"): \(message)"
            }
        }
    }
}
