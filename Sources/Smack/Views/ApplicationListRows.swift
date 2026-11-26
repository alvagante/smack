import AppKit
import SwiftUI

/// One row of the Applications list, an application or a background process, reduced to what the columns show and sort by.
struct ApplicationListEntry: Identifiable {
    enum Kind { case application, process }

    var id: String
    var kind: Kind
    var name: String
    var bundleIdentifier: String?
    var executablePath: String?
    var processCount: Int
    /// User of the main process when it is not the current user ("root", "_windowserver").
    var owner: String?
    var cpuUsage: Double
    var memoryBytes: UInt64
    var diskRate: Double
    var energyImpact: Double?
    var wakeupsPerSecond: Double
    var threads: Int
    var network: ProcessNetworkThroughput?
    /// Oldest process of the row: how long the application has been running.
    var startTime: Date
    var identities: [ProcessIdentity]
    /// TCP ports the row's processes listen on; nil when ports have not been read or cannot be in this build.
    var listeningPorts: [UInt16]?
    /// Signature of the executable; nil until it has been read.
    var signature: CodeSignatureInfo?
    /// What started the main process: a launchd job, a login item, Launch Services or a parent process.
    var launchSource: LaunchSource?

    init(application: ApplicationMetrics, currentUser: String, context: ApplicationListContext = ApplicationListContext()) {
        let main = ApplicationReadings.mainProcess(application)
        id = application.id
        kind = .application
        name = application.name
        bundleIdentifier = application.bundleIdentifier
        executablePath = application.executablePath ?? main?.executablePath
        processCount = application.processes.count
        owner = main?.userName.flatMap { $0 == currentUser ? nil : $0 }
        cpuUsage = application.cpuUsage
        memoryBytes = application.memoryBytes
        diskRate = application.diskReadRate + application.diskWriteRate
        energyImpact = application.energyImpact
        wakeupsPerSecond = application.wakeupsPerSecond
        threads = application.processes.reduce(0) { $0 + $1.threadCount }
        network = application.networkThroughput
        startTime = ApplicationReadings.startTime(application) ?? .distantFuture
        identities = application.processes.map(\.identity)
        listeningPorts = context.listeningPorts(identities)
        signature = executablePath.flatMap { context.signatures[$0] }
        launchSource = main.flatMap { ApplicationListReadings.launchSource(of: $0, context: context) }
    }

    init(process: ProcessMetrics, currentUser: String, context: ApplicationListContext = ApplicationListContext()) {
        id = process.id
        kind = .process
        name = process.name
        bundleIdentifier = process.bundleIdentifier
        executablePath = process.executablePath
        processCount = 1
        owner = process.userName.flatMap { $0 == currentUser ? nil : $0 }
        cpuUsage = process.cpuUsage
        memoryBytes = process.memoryBytes
        diskRate = process.diskReadRate + process.diskWriteRate
        energyImpact = process.energyImpact
        wakeupsPerSecond = process.wakeupsPerSecond
        threads = process.threadCount
        network = process.networkThroughput
        startTime = process.identity.startTime
        identities = [process.identity]
        listeningPorts = context.listeningPorts(identities)
        signature = executablePath.flatMap { context.signatures[$0] }
        launchSource = ApplicationListReadings.launchSource(of: process, context: context)
    }

    var route: AppRoute { kind == .application ? .application(id) : .process(id) }
}

/// What started a process, for the row caption, with a longer explanation for its hover hint.
struct LaunchSource: Equatable {
    var title: String
    var detail: String
}

/// How a signature reads in a row: who signed it, in a word, and how much to trust that at a glance.
struct SignerBadge: Equatable {
    enum Tone { case apple, trusted, caution, danger }
    var title: String
    var systemImage: String
    var tone: Tone
    var detail: String
}

/// Facts read outside the process snapshot, gathered once per render and handed to every row.
struct ApplicationListContext {
    /// Listening TCP ports by pid, from the network port snapshot; nil when there is none.
    var portsByPID: [Int32: [UInt16]]?
    var signatures: [String: CodeSignatureInfo] = [:]
    /// Startup items whose job is running, by its pid.
    var startupByPID: [Int32: StartupItem] = [:]
    /// launchd jobs by program path, for jobs whose pid the startup scan did not see.
    var launchdIndex: [String: LaunchdMatch] = [:]
    var processesByPID: [Int32: ProcessMetrics] = [:]
    /// Application names of application processes, so a helper's parent reads "Xcode", not "Xcode Helper".
    var applicationNames: [Int32: String] = [:]

    init() {}

    init(snapshot: ProcessSnapshot?, ports: NetworkPortSnapshot?, signatures: [String: CodeSignatureInfo],
         startup: StartupInventory?, launchdIndex: [String: LaunchdMatch]) {
        portsByPID = ports.map { ports in
            ports.ports.reduce(into: [Int32: [UInt16]]()) { $0[$1.pid, default: []].append($1.port) }
        }
        self.signatures = signatures
        startupByPID = (startup?.items ?? []).reduce(into: [:]) { result, item in
            if let pid = item.pid, pid > 1 { result[pid] = item }
        }
        self.launchdIndex = launchdIndex
        for application in snapshot?.applications ?? [] {
            for process in application.processes {
                processesByPID[process.identity.pid] = process
                applicationNames[process.identity.pid] = application.name
            }
        }
        for process in snapshot?.backgroundProcesses ?? [] { processesByPID[process.identity.pid] = process }
    }

    /// Distinct ports, sorted; the same port is often bound once for IPv4 and once for IPv6.
    func listeningPorts(_ identities: [ProcessIdentity]) -> [UInt16]? {
        guard let portsByPID else { return nil }
        return Array(Set(identities.flatMap { portsByPID[$0.pid] ?? [] })).sorted()
    }
}

/// Pure helpers behind the Applications list, kept apart from the views so they can be tested.
enum ApplicationListReadings {
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "ksh", "nu", "login", "sudo", "tmux", "screen", "env", "nohup"]

    /// A running startup item first, then a launchd job running the same program, then the parent process.
    /// Shells are walked through, so a process started from a terminal reads "Shell in iTerm2".
    static func launchSource(of process: ProcessMetrics, context: ApplicationListContext) -> LaunchSource? {
        if let item = context.startupByPID[process.identity.pid] {
            switch item.category {
            case .loginItems: return LaunchSource(title: "Login item", detail: "Opens at login: \(item.name)")
            case .backgroundItems: return LaunchSource(title: "Background item", detail: "App background item \(item.detail)")
            case .agents: return LaunchSource(title: "Launch agent", detail: "launchd agent \(item.detail)")
            case .daemons: return LaunchSource(title: "Launch daemon", detail: "launchd daemon \(item.detail)")
            case .apple: return LaunchSource(title: "macOS service", detail: "Apple launchd job \(item.detail)")
            case .scheduled: return LaunchSource(title: "Scheduled job", detail: item.trigger ?? item.detail)
            }
        }
        if let path = process.executablePath, let match = context.launchdIndex[path] {
            return LaunchSource(title: match.isDaemon ? "Launch daemon" : "Launch agent", detail: "launchd job \(match.label)")
        }
        guard let parent = process.parentPID, parent > 0 else { return nil }
        if parent == 1 {
            return process.isApplication
                ? LaunchSource(title: "Launch Services", detail: "Opened through Launch Services: Dock, Finder, Spotlight, open, or restored at login")
                : LaunchSource(title: "launchd", detail: "Started by launchd, typically as an XPC service or on demand")
        }
        var pid = parent
        var throughShell = false
        for _ in 0..<12 {
            guard let ancestor = context.processesByPID[pid] else {
                return LaunchSource(title: throughShell ? "Shell" : "PID \(pid)", detail: "Parent PID \(pid) is not visible or has exited")
            }
            guard shells.contains(ancestor.name), let next = ancestor.parentPID, next > 1 else {
                let name = context.applicationNames[pid] ?? ancestor.name
                if shells.contains(ancestor.name) { return LaunchSource(title: "Shell", detail: "Started from \(ancestor.name) (PID \(pid))") }
                return throughShell
                    ? LaunchSource(title: "Shell in \(name)", detail: "Started from a shell in \(name) (PID \(pid))")
                    : LaunchSource(title: name, detail: "Started by \(name) (PID \(pid))")
            }
            throughShell = true
            pid = next
        }
        return LaunchSource(title: "Shell", detail: "Started from a chain of shells")
    }

    /// Who signed an executable; nil while unread or when it cannot be read. Notarization needs a full
    /// verification or a network lookup, so it is left to the Gatekeeper check on the process page.
    static func signer(_ info: CodeSignatureInfo?) -> SignerBadge? {
        guard let info else { return nil }
        let runtime = info.hardenedRuntime ? ", hardened runtime" : ""
        switch info.trust {
        case .unavailable:
            return nil
        case .unsigned:
            return SignerBadge(title: "Unsigned", systemImage: "xmark.shield.fill", tone: .danger, detail: "The executable has no code signature.")
        case .adHoc:
            return SignerBadge(title: "Ad-hoc signed", systemImage: "exclamationmark.shield.fill", tone: .caution,
                               detail: "Signed without a certificate: no developer identity\(runtime).")
        case .signed:
            let certificate = info.certificateName ?? ""
            let team = info.teamIdentifier.map { " (\($0))" } ?? ""
            if info.teamIdentifier == nil, certificate == "Software Signing" || info.identifier?.hasPrefix("com.apple.") == true {
                return SignerBadge(title: "Apple", systemImage: "apple.logo", tone: .apple, detail: "Signed by Apple as part of macOS\(runtime).")
            }
            if certificate == "Apple Mac OS Application Signing" {
                return SignerBadge(title: "Mac App Store", systemImage: "checkmark.seal.fill", tone: .trusted,
                                   detail: "Signed by the Mac App Store, team\(team.isEmpty ? " unknown" : team)\(runtime).")
            }
            if certificate.hasPrefix("Apple Development:") {
                return SignerBadge(title: "Development build", systemImage: "hammer.fill", tone: .caution,
                                   detail: "\(certificate): runs only on registered Macs\(runtime).")
            }
            let developer = developerName(certificate: certificate) ?? info.teamIdentifier ?? "Signed"
            return SignerBadge(title: developer, systemImage: "checkmark.seal.fill", tone: .trusted,
                               detail: "\(certificate.isEmpty ? "Signed" : certificate)\(team.isEmpty || certificate.contains(team) ? "" : team)\(runtime).")
        }
    }

    /// "Developer ID Application: Google LLC (EQHXZ8M8AV)" → "Google LLC".
    static func developerName(certificate: String) -> String? {
        guard let colon = certificate.range(of: ": ") else { return nil }
        var name = certificate[colon.upperBound...]
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") { name = name[..<open] }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "3000 5173 +2": the first ports, then how many more.
    static func portsSummary(_ ports: [UInt16]?, shown: Int = 2) -> String {
        guard let ports else { return "–" }
        let head = ports.prefix(shown).map(String.init).joined(separator: " ")
        return ports.count > shown ? "\(head) +\(ports.count - shown)" : head
    }

    /// Rows for the scope: Apps keeps applications with their own icon, All adds every other application and the
    /// background processes. `userApplications` is read once per render from `UserApplications.processIdentifiers()`.
    static func entries(_ snapshot: ProcessSnapshot?, scope: ProcessScope, userApplications: Set<Int32>, currentUser: String,
                        context: ApplicationListContext = ApplicationListContext()) -> (applications: [ApplicationListEntry], background: [ApplicationListEntry]) {
        guard let snapshot else { return ([], []) }
        let applications = scope == .apps
            ? snapshot.applications.filter { UserApplications.contains($0, in: userApplications) }
            : snapshot.applications
        let background = scope == .apps ? [] : snapshot.backgroundProcesses
        return (applications.map { ApplicationListEntry(application: $0, currentUser: currentUser, context: context) },
                background.map { ApplicationListEntry(process: $0, currentUser: currentUser, context: context) })
    }

    static func matches(_ entry: ApplicationListEntry, query: String) -> Bool {
        query.isEmpty || entry.name.localizedCaseInsensitiveContains(query)
            || entry.bundleIdentifier?.localizedCaseInsensitiveContains(query) == true
            || entry.identities.contains { String($0.pid) == query }
    }

    static func sorted(_ entries: [ApplicationListEntry], by sort: ProcessSort, ascending: Bool) -> [ApplicationListEntry] {
        entries.sorted { lhs, rhs in
            if sort == .name {
                let result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
            let (a, b) = (value(lhs, sort), value(rhs, sort))
            if a == b { return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
            return ascending ? a < b : a > b
        }
    }

    /// Sort key of a column; a missing reading sorts below zero. Running time grows as the start time recedes.
    static func value(_ entry: ApplicationListEntry, _ sort: ProcessSort) -> Double {
        switch sort {
        case .cpu: entry.cpuUsage
        case .memory: Double(entry.memoryBytes)
        case .disk: entry.diskRate
        case .network: entry.network?.total ?? -.infinity
        case .energy: entry.energyImpact ?? -.infinity
        case .wakeups: entry.wakeupsPerSecond
        case .threads: Double(entry.threads)
        case .ports: entry.listeningPorts.map { Double($0.count) } ?? -.infinity
        case .uptime: -entry.startTime.timeIntervalSince1970
        case .name: 0
        }
    }

    /// "3 d 4 h", "4 h 12 m", "12 m", or "< 1 m" for a process that just started.
    static func runningTime(since start: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(start)
        guard interval >= 60 else { return interval >= 0 ? "< 1 m" : "–" }
        return CPUReadings.uptime(interval)
    }

    /// "7 apps · 76 other": how many sampled entries the Apps scope hides.
    static func scopeCounts(_ snapshot: ProcessSnapshot, userApplications: Set<Int32>) -> String {
        let apps = snapshot.applications.filter { UserApplications.contains($0, in: userApplications) }.count
        let other = snapshot.applications.count - apps + snapshot.backgroundProcesses.count
        return "\(apps) apps · \(other) other"
    }
}

/// Value columns of the Applications list, shared by the flat list and the tree so headers and rows line up.
/// The panel can be 720 pt wide, so secondary columns appear only as the list widens.
struct ApplicationListLayout: Equatable {
    static let spacing: CGFloat = 12
    static let trendWidth: CGFloat = 64
    /// FileLookupLinks.width (64) plus the kill icon.
    static let actionsWidth: CGFloat = 88

    var columns: [ProcessSort]
    var showsTrend: Bool

    init(width: CGFloat) {
        switch width {
        case 1180...:
            columns = [.cpu, .memory, .disk, .network, .energy, .wakeups, .threads, .ports, .uptime]
            showsTrend = true
        case 940...:
            columns = [.cpu, .memory, .disk, .energy, .wakeups, .ports, .uptime]
            showsTrend = false
        default:
            // Width is zero before the first layout pass; start compact rather than overflow.
            columns = [.cpu, .memory, .energy, .uptime]
            showsTrend = false
        }
    }
}

extension ProcessSort {
    var columnTitle: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .energy: "Energy"
        case .wakeups: "Wakeups"
        case .threads: "Threads"
        case .ports: "Ports"
        case .uptime: "Running"
        case .name: "Name"
        }
    }

    var columnWidth: CGFloat {
        switch self {
        case .cpu: 64
        case .memory: 80
        case .disk: 90
        case .network: 90
        case .energy: 60
        case .wakeups: 72
        case .threads: 60
        case .ports: 80
        case .uptime: 76
        case .name: 0
        }
    }

    var columnHelp: String {
        switch self {
        case .cpu: "CPU summed over the row's processes; one core is 100%."
        case .memory: "Physical footprint summed over the row's processes."
        case .disk: "Disk read plus write rate."
        case .network: "Receive and send rate of observable TCP and UDP traffic."
        case .energy: "Energy impact as macOS estimates it; higher drains the battery faster."
        case .wakeups: "Times per second a core was woken from idle."
        case .threads: "Threads summed over the row's processes."
        case .ports: "TCP ports the row's processes listen on, refreshed every 30 seconds while this page is open."
        case .uptime: "How long the oldest process of the row has been running."
        case .name: "Sort by name"
        }
    }
}

/// One value cell of a row: the column's reading, or a dash where the build cannot read it.
struct ApplicationListCell: View {
    let entry: ApplicationListEntry
    let column: ProcessSort

    var body: some View {
        Group {
            if column == .network {
                VStack(alignment: .trailing, spacing: 0) {
                    if let network = entry.network {
                        Text("↓ \(Formatting.rate(network.receiveRate))")
                        Text("↑ \(Formatting.rate(network.sendRate))")
                    } else {
                        Text("–")
                    }
                }
                .font(.caption)
            } else {
                Text(text).font(.callout)
            }
        }
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(width: column.columnWidth, alignment: .trailing)
    }

    private var text: String {
        switch column {
        case .cpu: return Formatting.percent(entry.cpuUsage)
        case .memory: return Capabilities.isSandboxed && entry.memoryBytes == 0 ? "—" : Formatting.bytes(entry.memoryBytes)
        case .disk: return Capabilities.isSandboxed && entry.diskRate == 0 ? "—" : Formatting.rate(entry.diskRate)
        case .energy: return Formatting.energy(entry.energyImpact)
        case .wakeups: return ApplicationListView.wakeups(entry.wakeupsPerSecond)
        case .threads: return entry.threads.formatted()
        case .ports: return ApplicationListReadings.portsSummary(entry.listeningPorts)
        case .uptime: return ApplicationListReadings.runningTime(since: entry.startTime)
        case .network, .name: return ""
        }
    }
}

/// Trailing icons of a row: Finder, Google and VirusTotal for the executable, then Kill. Kept outside the row's
/// navigation button so their clicks are not swallowed by it.
struct ApplicationListActions: View {
    let entry: ApplicationListEntry
    let kill: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let path = entry.executablePath {
                // The executable, not the bundle: VirusTotal hashes a file, and the Google term already names the bundle.
                // No stat per render: rows redraw on every snapshot.
                FileLookupLinks(path: path, checksFileOnDisk: false,
                                revealPath: entry.kind == .application ? ApplicationReadings.bundleURL(executablePath: path)?.path : nil)
            } else {
                Color.clear.frame(width: FileLookupLinks.width, height: 1)
            }
            if Capabilities.supportsProcessTermination {
                Button(action: kill) { Image(systemName: "xmark.octagon").foregroundStyle(.red) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .hoverHint("Kill \(entry.name)…")
                    .accessibilityLabel("Kill \(entry.name)")
            }
        }
        .frame(width: ApplicationListLayout.actionsWidth, alignment: .leading)
    }
}

/// Copy and search shortcuts that do not earn a column.
struct ApplicationListContextMenu: View {
    let entry: ApplicationListEntry
    let open: () -> Void
    let kill: () -> Void

    var body: some View {
        Button("Open Details", action: open)
        Divider()
        if let path = entry.executablePath {
            Button("Copy Executable Path") { copy(path) }
        }
        if let bundle = entry.bundleIdentifier {
            Button("Copy Bundle Identifier") { copy(bundle) }
            if let url = FileLookup.googleURL(searching: bundle) {
                Button("Search Google for Bundle Identifier") { NSWorkspace.shared.open(url) }
            }
        }
        Button(entry.identities.count == 1 ? "Copy PID" : "Copy PIDs") {
            copy(entry.identities.map { String($0.pid) }.joined(separator: " "))
        }
        if Capabilities.supportsProcessTermination {
            Divider()
            Button("Kill \(entry.name)…", role: .destructive, action: kill)
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

/// What the user asked to kill; identities are captured when the confirmation opens.
struct KillRequest: Equatable {
    var entryID: String
    var kind: ApplicationListEntry.Kind
    var name: String
    var targets: [ProcessIdentity]
}

/// Confirmation and outcome of a kill, shown inside the window instead of a modal alert.
struct KillBanner: View {
    let name: String?
    let processCount: Int
    let message: String?
    let terminate: () -> Void
    let forceKill: () -> Void
    let cancel: () -> Void
    let dismiss: () -> Void

    var body: some View {
        if let name {
            VStack(alignment: .leading, spacing: 8) {
                Label("Kill \(name)?", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.red)
                Text("This affects \(processCount) process\(processCount == 1 ? "" : "es"). Terminate asks the application to quit as the Dock does, so it can offer to save (processes without an application get SIGTERM). Force Kill ends them all immediately (SIGKILL) and unsaved work is lost.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Terminate", action: terminate)
                    Button("Force Kill", role: .destructive, action: forceKill)
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                }
                .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.red.opacity(0.4)))
        } else if let message {
            HStack {
                Text(message).font(.callout).textSelection(.enabled)
                Spacer()
                Button("Dismiss", action: dismiss).buttonStyle(.link).font(.caption)
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
