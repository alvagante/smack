import SwiftUI
import AppKit

/// One sidebar entry of Settings. Order here is sidebar order; `groups` adds the visual gaps.
/// One pane per feature, mirroring the Summary tiles, so everything that drives one feature's cost sits together.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general = "General"
    case appearance = "Appearance"
    case performance = "Performance"
    case system = "System"
    case processes = "Processes"
    case network = "Network"
    case security = "Security"
    case development = "Development"
    case docker = "Docker"
    case agents = "AI Agents"
    case otherPages = "Other Pages"
    case alerts = "Alerts"
    case activity = "Activity Timeline"
    case history = "Historical Data"
    case automation = "Automation"
    case helper = "Privileged Helper"
    case about = "About"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "circle.lefthalf.filled"
        case .performance: "gauge.with.dots.needle.67percent"
        case .system: "cpu"
        case .processes: "square.stack.3d.up.fill"
        case .network: "network"
        case .security: "shield.fill"
        case .development: "hammer.fill"
        case .docker: "shippingbox.fill"
        case .agents: "sparkles"
        case .otherPages: "square.grid.2x2.fill"
        case .alerts: "bell.badge.fill"
        case .activity: "list.bullet.rectangle.fill"
        case .history: "clock.arrow.circlepath"
        case .automation: "terminal.fill"
        case .helper: "lock.shield.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general, .about, .otherPages: .gray
        case .appearance: Color(white: 0.2)
        case .performance: .orange
        case .system, .network: .blue
        case .processes: .green
        case .security, .automation, .helper: .indigo
        case .development, .docker: .brown
        case .agents, .activity, .alerts: .purple
        case .history: .teal
        }
    }

    var isAvailable: Bool {
        switch self {
        case .security: Capabilities.supportsPostureChecks || Capabilities.supportsPersistenceWatching || Capabilities.supportsStartupItems
        case .development, .docker, .agents, .otherPages: !Capabilities.isSandboxed
        case .helper: Capabilities.supportsPrivilegedSampling
        default: true
        }
    }

    /// Sidebar groups, separated by a gap as in System Settings; unavailable panes are dropped.
    /// Panel, monitored resources, local environment pages, stored data, integrations.
    static var groups: [[SettingsPane]] {
        [[.general, .appearance, .performance], [.system, .processes, .network, .security],
         [.development, .docker, .agents, .otherPages], [.alerts, .activity, .history], [.automation, .helper], [.about]]
            .map { $0.filter(\.isAvailable) }
            .filter { !$0.isEmpty }
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    /// Kept here, not in view state, so returning to Settings reopens the last pane.
    @Published var pane: SettingsPane = .general
    @Published var confirmDelete = false
    @Published var exportError: String?
    @Published var includeEvents = false
    @Published var usage: StorageUsage?
    @Published var isMeasuring = false
    @Published var usageError: String?
    @Published var confirmCompact = false
    @Published var isCompacting = false
    @Published var lastCompacted: Date?
    @Published var compactError: String?
}

/// Settings in the System Settings layout: a sidebar of panes and a grouped form per pane.
///
/// Adding a setting: store it in `CollectionSettings` (default, clamp in `validate()`, decode with a default),
/// then add one row to the pane of the feature it serves (see "Where a Setting goes" in CONTEXT.md) using the building
/// blocks at the end of this file:
/// `Toggle` with a `SettingsLabel` for switches, `Picker` for choices, `StepperRow` for counts and durations,
/// `IntervalRow` for optional intervals, `FolderListRows` for folder lists. Put explanations in `help:` (shown on
/// the ⓘ) and consequences in a section footer. Gate rows with `Capabilities`, never show a control that does
/// nothing in this build. Bind with `binding(_:)` only for settings the scheduler reads (it restarts sampling);
/// everything else uses `localBinding(_:)`, and `MonitorStore` pushes it to the page monitors. Event switches go in the
/// pane's `timelineSection`, environment page master switches are `summaryToggle(_:)`.
struct SettingsView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var model: SettingsViewModel
    /// Action invoked when requesting full application shutdown from settings.
    var onQuit: () -> Void = { _ = NSApplication.shared.sendAction(#selector(AppDelegate.requestQuit(_:)), to: nil, from: nil) }

    /// Initializes the settings view.
    /// - Parameters:
    ///   - store: Primary monitor store providing settings and view model references.
    ///   - onQuit: Callback invoked upon clicking a Quit control.
    init(store: MonitorStore, onQuit: @escaping () -> Void = { _ = NSApplication.shared.sendAction(#selector(AppDelegate.requestQuit(_:)), to: nil, from: nil) }) {
        self.store = store
        settings = store.settingsStore
        model = store.settingsViewModel
        self.onQuit = onQuit
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            Form { pane(model.pane) }
                .formStyle(.grouped)
                .toggleStyle(.switch)
                .id(model.pane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog("Delete all Historical Data?", isPresented: $model.confirmDelete) {
            Button("Delete History", role: .destructive) { Task { try? await store.history.deleteAll() } }
        }
        .confirmationDialog("Compact the history database now?", isPresented: $model.confirmCompact) {
            Button("Compact") { compact() }
        } message: {
            Text("History writes wait until it finishes, and it temporarily needs free disk space about the size of the database.")
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { model.pane }, set: { if let pane = $0 { model.pane = pane } })) {
            ForEach(Array(SettingsPane.groups.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group) { pane in
                        Label { Text(pane.rawValue) } icon: { SettingsIcon(systemImage: pane.systemImage, tint: pane.tint) }
                            .tag(pane)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private func pane(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: generalPane
        case .appearance: appearancePane
        case .performance: performancePane
        case .system: systemPane
        case .processes: processesPane
        case .network: networkPane
        case .security: securityPane
        case .development: developmentPane
        case .docker: dockerPane
        case .agents: agentsPane
        case .otherPages: otherPagesPane
        case .alerts:
            Section {
                Toggle(isOn: localBinding(\.alertsEnabled)) {
                    SettingsLabel("Enable alerts", help: "Stops rule evaluation and new alert delivery when off. Saved rules are kept. Pause and snooze only suppress delivery.",
                        subtitle: "CPU grows with enabled rules and matching processes; no extra sampling. Production CPU budget remains unverified.")
                }
            }
            AlertsSettingsView(store: store, rules: store.alertRules).disabled(!settings.settings.alertsEnabled)
            timelineSection {
                Toggle(isOn: binding(\.recordAlertEvents)) {
                    SettingsLabel("Alerts", help: "Fired alerts, including suppressed notifications.")
                }
            }
        case .activity: activityPane
        case .history: historyPane
        case .automation: automationPane
        case .helper:
            if let controller = store.privilegedSampling {
                Section { PrivilegedSamplingSection(controller: controller, settings: settings, onChange: { store.settingsChanged() }) }
            }
        case .about: aboutPane
        }
    }

    // MARK: Panes

    @ViewBuilder private var generalPane: some View {
        Section {
            Picker(selection: binding(\.trigger)) {
                ForEach(PanelTrigger.allCases) { Text($0.rawValue).tag($0) }
            } label: { SettingsLabel("Open the panel with", help: "How the camera hot zone opens the panel.") }
            if settings.settings.trigger == .hover {
                LabeledContent("Hover delay") { NumberField(value: binding(\.hoverDelay), unit: "s") }
            }
            Picker(selection: soundSelectionBinding) {
                ForEach(PanelSound.allCases) { Text($0.displayName).tag($0) }
            } label: { SettingsLabel("Sound", help: "Played when the panel opens. Choosing one plays a preview.") }
        }
        Section {
            Toggle("Launch at Login", isOn: binding(\.launchAtLogin))
        }
        Section {
            LabeledContent {
                Button("Quit Smack", role: .destructive, action: onQuit)
            } label: {
                SettingsLabel("Quit", subtitle: "Stops all collection until Smack is opened again. Saved history is kept.")
            }
        }
    }

    @ViewBuilder private var appearancePane: some View {
        Section {
            Toggle(isOn: appearanceBinding(\.glassMode)) {
                SettingsLabel("Glass mode", help: "Translucent panel background that shows the desktop through it.")
            }
            if settings.settings.glassMode {
                LabeledContent {
                    HStack {
                        Slider(value: appearanceBinding(\.glassOpacity), in: CollectionSettings.glassOpacityRange).frame(width: 160)
                        Text(settings.settings.glassOpacity.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                } label: {
                    SettingsLabel("Opacity", subtitle: "Lower shows more of the desktop; higher is easier to read.")
                }
            }
        }
        Section("Charts") {
            Toggle(isOn: binding(\.showEventsOnCharts)) {
                SettingsLabel("Show events on history charts", help: "Draws event markers on the history graphs. Display only; does not change what is recorded.")
            }
        }
    }

    @ViewBuilder private var performancePane: some View {
        let preset = PerformancePreset.matching(settings.settings)
        Section {
            Picker(selection: presetBinding) {
                ForEach(PerformancePreset.allCases) { Text($0.rawValue).tag(Optional($0)) }
                if preset == nil { Text("Custom").tag(nil as PerformancePreset?) }
            } label: {
                SettingsLabel("Performance preset", help: "Sets the Settings listed in the footer at once. Choose Standard to return to the defaults.",
                              subtitle: preset?.summary ?? "Custom: settings changed by hand in this or the feature panes.")
            }
        } footer: {
            SettingsFooter("A preset sets live refresh, Network Rate, background System, Process and listening-port intervals, the battery slowdown, process history, the Memory Budget and Docker statistics. Each also appears in its own pane; changing one there shows Custom. Security and Activity Timeline settings are never changed by a preset.")
        }
        Section {
            Picker(selection: binding(\.liveRefreshSeconds)) {
                ForEach(CollectionSettings.liveRefreshChoices, id: \.self) { Text("Every \(Int($0)) s").tag($0) }
            } label: {
                SettingsLabel("Refresh", help: "How often system and process metrics update while the panel is visible. Slower refresh uses less CPU, especially with the panel pinned.")
            }
        } header: {
            Text("While the panel is open")
        } footer: {
            SettingsFooter("Faster refresh increases CPU use. Hardware sensors are read only on relevant pages. CPU cost depends on process count.")
        }
        Section {
            Picker(selection: binding(\.constrainedPowerMultiplier)) {
                ForEach(CollectionSettings.constrainedPowerChoices, id: \.self) { Text($0 == 1 ? "Off" : "\($0)× slower").tag($0) }
            } label: {
                SettingsLabel("On battery or Low Power Mode", help: "Stretches every background interval (System, Processes, Network) while the Mac runs on battery or in Low Power Mode, to save energy. History becomes coarser during that time.")
            }
        } header: {
            Text("While the panel is closed")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let warning = settings.settings.warning {
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                SettingsFooter("System/process/port sampling costs grow with frequency and process count. Off stops the corresponding background loop; visible pages still collect live data.")
            }
        }
        Section {
            Picker(selection: localBinding(\.memoryBudget)) {
                ForEach(MemoryBudget.allCases) { Text($0.rawValue).tag($0) }
            } label: {
                SettingsLabel("Memory budget", help: "Caps memory held by caches and on-demand reports: profiling output, development runtime inspections, application icons and process signature facts.",
                              subtitle: memoryBudgetSummary)
            }
        } header: {
            Text("Memory")
        } footer: {
            SettingsFooter("Lower budgets evict cached results sooner, so pages may reload them. Changes apply to new results.")
        }
        if !Capabilities.isSandboxed {
            Section {
                Picker(selection: localBinding(\.inventoryCache)) {
                    ForEach(InventoryCachePreset.allCases) { Text($0.label).tag($0) }
                } label: {
                    SettingsLabel("Reuse inventories", help: "How long Docker, Homebrew, development runtime and AI agent results are reused before they are collected again. Refresh buttons always collect immediately.")
                }
            } header: {
                Text("Caching")
            }
        }
    }

    private var memoryBudgetSummary: String {
        let budget = settings.settings.memoryBudget
        return "Profiling \(Formatting.bytes(UInt64(budget.profileOutputBytes))) · \(budget.iconCount) icons · \(budget.fileFactsEntries) signatures"
    }

    @ViewBuilder private var systemPane: some View {
        Section {
            IntervalRow(title: "System metrics", help: "CPU, memory, disk and network samples taken while the panel is closed. They feed the history graphs and system events. Approximate storage per hour at full resolution; compacted to about a tenth after the full-resolution window.", estimate: StorageEstimate.system, seconds: optionalBinding(\.backgroundSystemInterval), minimum: 1)
        } header: {
            Text("While the panel is closed")
        } footer: {
            SettingsFooter("While the panel is open, metrics follow Refresh in Performance. Temperatures, fans and per-process GPU time are read only while a page showing them is open.")
        }
        timelineSection {
            Toggle(isOn: binding(\.recordSystemEvents)) {
                SettingsLabel("System", help: "Volumes, sleep/wake, power source, thermal and memory pressure.", subtitle: "<1 KB/h")
            }
        }
    }

    @ViewBuilder private var processesPane: some View {
        Section {
            Toggle(isOn: binding(\.showBackgroundProcesses)) {
                SettingsLabel("Show background processes", help: "Lists processes that are not user-facing applications next to applications.")
            }
        }
        Section {
            IntervalRow(title: "Process metrics", help: "Per-process samples taken while the panel is closed. They feed process history and process start/exit events. Approximate storage per hour on a Mac with about 500 processes; idle processes are stored sparsely.", estimate: StorageEstimate.processes, seconds: optionalBinding(\.backgroundProcessInterval), minimum: 1)
            if !Capabilities.isSandboxed {
                IntervalRow(title: "Process inventories", help: "Collects open files, ports and memory maps for every process on a schedule, so the process detail views are already populated. Expensive; unrelated to history graphs and the timeline. Kept in memory only, never stored on disk.", estimate: { _ in "no storage" }, seconds: optionalBinding(\.backgroundInventoryInterval), minimum: 10)
            }
        } header: {
            Text("While the panel is closed")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                SettingsFooter(Capabilities.isSandboxed
                    ? "Scheduled inventories are unavailable in the App Sandbox; use the on-demand inventory button on a process."
                    : "Process inventories are on demand unless scheduled.")
                SettingsFooter("Scheduled inventories can be expensive: they inspect each process and retain results in memory. Process metrics off also stops background agent sessions, process events and process alerts while the panel is closed.")
            }
        }
        Section("Process history") {
            Toggle(isOn: binding(\.recordProcessHistory)) {
                SettingsLabel("Record process history", help: "Per-process CPU, memory and disk history. The largest storage consumer. Turn off to keep only system history and timeline events.")
            }
            if settings.settings.recordProcessHistory {
                StepperRow(
                    title: "Busiest processes only",
                    help: "Store only the N busiest processes (by CPU or memory) in each snapshot. 0 stores every process. Lower values shrink process history substantially.",
                    text: settings.settings.processHistoryTopCount == 0 ? "All" : "\(settings.settings.processHistoryTopCount)",
                    value: binding(\.processHistoryTopCount), range: CollectionSettings.processTopCountRange, step: 10
                )
                StepperRow(title: "Per-minute process data", help: "How long one-minute process rows are kept. Never longer than Retention. This is usually the biggest part of the database.", text: "\(settings.settings.processMinuteRetentionDays) days", value: binding(\.processMinuteRetentionDays), range: CollectionSettings.processMinuteRetentionRange)
            }
        }
        timelineSection {
            Toggle(isOn: binding(\.recordProcessEvents)) {
                SettingsLabel("Processes", help: "Process started and exited. About 300 bytes per event; a build-heavy Mac can reach 1 MB per hour, a quiet one a few tens of KB.", subtitle: "~30 KB-1 MB/h")
            }
        }
        if Capabilities.supportsProfiling {
            Section {
                Picker(selection: localBinding(\.fileActivitySeconds)) {
                    ForEach(CollectionSettings.fileActivityChoices, id: \.self) { Text("\($0) seconds").tag($0) }
                } label: {
                    SettingsLabel("File Activity trace", help: "Length of a File Activity capture on application and process pages, taken through the Privileged Helper. Longer traces are taken as consecutive five-second segments, with short gaps between them.")
                }
            } header: {
                Text("Inspection")
            }
        }
    }

    @ViewBuilder private var networkPane: some View {
        if !Capabilities.isSandboxed {
            Section {
                Toggle(isOn: binding(\.processNetworkRateEnabled)) {
                    SettingsLabel("Per-process network rates", help: "Receive and send rates for each process and application, from a separate sampler that runs only while the panel is visible. Off shows Off instead of a rate.")
                }
                if settings.settings.processNetworkRateEnabled {
                    StepperRow(title: "Network rate interval", text: "\(Int(settings.settings.processNetworkRateSeconds)) s",
                               value: Binding(get: { Int(settings.settings.processNetworkRateSeconds) }, set: { value in binding(\.processNetworkRateSeconds).wrappedValue = TimeInterval(value) }),
                               range: Int(CollectionSettings.processNetworkRateRange.lowerBound)...Int(CollectionSettings.processNetworkRateRange.upperBound))
                }
            } header: {
                Text("While the panel is open")
            } footer: {
                SettingsFooter("Per-process network rates run an additional sampler while visible; disabling rates stops it.")
            }
        }
        if Capabilities.supportsNetworkPortInspection {
            Section {
                IntervalRow(title: "Listening ports", help: "Samples listening ports (and connections, if enabled) while the panel is closed. Feeds network timeline events; only the resulting events are stored.", estimate: { _ in "<10 KB/h" }, seconds: optionalBinding(\.backgroundNetworkInterval), minimum: 5)
            } header: {
                Text("While the panel is closed")
            } footer: {
                SettingsFooter("Dev servers can also keep port sampling running in the background; see Development.")
            }
        }
        timelineSection {
            Toggle(isOn: binding(\.recordNetworkEvents)) {
                SettingsLabel("Network", help: "Listening ports opened or closed, interface and address changes.", subtitle: "<10 KB/h")
            }
            if settings.settings.recordNetworkEvents {
                Toggle(isOn: binding(\.recordConnectionEvents)) {
                    SettingsLabel("Include connections", help: "Adds opened/closed events for every non-listening socket, outbound or inbound. Can be noisy and grows the event store faster.", subtitle: "~0.1-1 MB/h")
                }
            }
        } warning: {
            if settings.settings.recordNetworkEvents && settings.settings.recordConnectionEvents {
                Label("Connection events can be very frequent on busy machines. Event rows are capped, so older events drop sooner.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var securityPane: some View {
        if Capabilities.supportsPostureChecks {
            Section {
                IntervalRow(title: "Posture checks", help: "Offline checks of security settings. First check runs after 60 seconds. Off cancels collection; the last cached result is kept.",
                    estimate: { _ in "Brief CPU and file/tool activity per run; serial probes capped at 5 s each and 20 s combined. Total resource budget unverified." },
                    seconds: localBinding(\.postureCheckInterval), minimum: 60, defaultSeconds: 21_600)
            } header: { Text("Scheduled checks") }
            footer: { SettingsFooter("Expected brief CPU and disk activity per check cycle. Actual total CPU, wall time and energy are unmeasured; command deadlines are limits, not measured resource usage.") }
        }
        if Capabilities.supportsPersistenceWatching {
            Section {
                Toggle(isOn: localBinding(\.watchPersistence)) {
                    SettingsLabel("Watch persistence", help: "Launch agents, daemons and selected SSH, shell and system files. Off stops the watcher, pending rescans and scheduled persistence polls.",
                        subtitle: "Expected low idle CPU; file changes trigger hashing and rescans after a 2 s debounce. File reads capped at 1 MiB each. Production CPU/energy impact unmeasured.")
                }
                Toggle(isOn: localBinding(\.persistenceEnrichmentEnabled)) {
                    SettingsLabel("Enrich changed items", help: "Offline signature verification, quarantine and location details. Off keeps file hashes and change detection.",
                        subtitle: "Extra CPU and file reads during changes; at most 20 items per scan, 3 s per item within the scan deadline.")
                }.disabled(!settings.settings.watchPersistence)
                IntervalRow(title: "Scheduled persistence scans", help: "Polls crontab and, with an enabled v2 helper, background tasks and configuration profiles. No password prompts. Off leaves file watching active.",
                    estimate: { _ in "Periodic tool/helper CPU and I/O; commands have 5 s deadlines. CPU/energy impact unmeasured." },
                    seconds: localBinding(\.persistencePollInterval), minimum: 3600, defaultSeconds: 3600)
                    .disabled(!settings.settings.watchPersistence)
            } header: { Text("Persistence monitoring") }
            footer: { SettingsFooter("Scheduled scans add periodic tool/helper work. File changes can cause CPU and disk bursts, especially with enrichment enabled; production impact is unmeasured. Collection switches stop work. Activity Timeline recording switches only control stored events. Cached results remain available when collection is off.") }
        }
        timelineSection {
            if Capabilities.supportsPostureChecks || Capabilities.supportsPersistenceWatching {
                Toggle(isOn: binding(\.recordSecurityEvents)) {
                    SettingsLabel("Security", help: "Security posture and persistence file changes.")
                }
            }
            if Capabilities.supportsStartupItems {
                Toggle(isOn: binding(\.recordStartupEvents)) {
                    SettingsLabel("Startup items", help: "Login items, launch agents and daemons added, removed or changed.", subtitle: "<1 KB/h")
                }
            }
        }
    }

    @ViewBuilder private var developmentPane: some View {
        if Capabilities.supportsNetworkPortInspection {
            Section("Dev servers") {
                summaryToggle(.devServers)
                Toggle(isOn: binding(\.backgroundDevServersEnabled)) {
                    SettingsLabel("Collect dev servers in background", help: "Keeps listening-port sampling and dev server detection running while the panel is closed, even with Listening ports off in Network.")
                }
                Picker("Terminal", selection: binding(\.terminalApp)) {
                    ForEach(ProjectApplications.installed(ProjectApplications.terminals), id: \.id) { app in
                        Text(app.name).tag(app.id)
                    }
                }
                Picker("Editor", selection: binding(\.editorApp)) {
                    Text("None").tag(nil as String?)
                    ForEach(ProjectApplications.installed(ProjectApplications.editors), id: \.id) { app in
                        Text(app.name).tag(Optional(app.id))
                    }
                }
            }
        }
        Section {
            summaryToggle(.devEnvironments)
            StepperRow(title: "Project scan depth", help: "Directory levels searched below each project folder for virtual environments and project-local runtimes.",
                       text: "\(settings.settings.devScanDepth) levels", value: localBinding(\.devScanDepth), range: CollectionSettings.devScanDepthRange)
            FolderListRows(folders: localBinding(\.devProjectFolders), addTitle: "Add Project Folder…", empty: "No project folders")
        } header: {
            Text("Development environments")
        }
        Section {
            summaryToggle(.homebrew)
        } header: {
            Text("Homebrew")
        } footer: {
            SettingsFooter("How long Development environment and Homebrew results are reused is set by Reuse inventories in Performance.")
        }
    }

    @ViewBuilder private var dockerPane: some View {
        Section {
            summaryToggle(.docker)
            Picker(selection: localBinding(\.dockerRefreshSeconds)) {
                ForEach(CollectionSettings.dockerRefreshChoices, id: \.self) { Text($0 == 0 ? "Only on request" : "Every \($0) s").tag($0) }
            } label: {
                SettingsLabel("Auto-refresh", help: "How often container state updates while the panel is open.")
            }
            Toggle(isOn: localBinding(\.dockerLiveStats)) {
                SettingsLabel("Live container statistics", help: "CPU, memory, network and block I/O per container. The most expensive Docker query; off shows container state only.")
            }
        } footer: {
            SettingsFooter("Expected CPU and daemon work on each refresh; live statistics add per-container queries. Only on request stops automatic refresh. Hiding Docker from Summary stops its discovery, unless Dev servers need container names. Production CPU/energy costs vary with container count.")
        }
    }

    @ViewBuilder private var agentsPane: some View {
        Section {
            summaryToggle(.agents)
        }
        Section {
            ForEach(AgentDefinition.catalog, id: \.id) { agent in
                Toggle(agent.name, isOn: agentBinding(agent.id))
            }
        } header: {
            Text("Agents to look for")
        } footer: {
            SettingsFooter("Turned-off agents are not looked for. Agents are listed only when they are installed.")
        }
        Section {
            FolderListRows(folders: localBinding(\.customAgentFolders), addTitle: "Add Agent Folder…", empty: "No custom agent folders")
        } header: {
            Text("Custom agent folders")
        } footer: {
            SettingsFooter("Each folder appears as its own agent, browsed for the configuration, skills, memory, logs and sessions files known agents use.")
        }
        Section {
            Toggle(isOn: binding(\.showAgentCommandLines)) {
                SettingsLabel("Allow per-session command line reveal", help: "Shows a button that reveals a running session's command line, which can contain secrets.")
            }
        } header: {
            Text("Sessions")
        } footer: {
            SettingsFooter("Running sessions are tracked on every process sample only while AI Agents is on Summary, session events are recorded, or an enabled alert rule uses agent sessions. Otherwise tracking stops, and the sessions list, the CLI, dev server links and listener event attribution show none.")
        }
        timelineSection {
            Toggle(isOn: binding(\.recordAgentEvents)) {
                SettingsLabel("Agent sessions", help: "Agent session started and ended. Also keeps session tracking running while AI Agents is hidden from Summary.")
            }
        }
    }

    @ViewBuilder private var otherPagesPane: some View {
        Section {
            summaryToggle(.installedApps)
            summaryToggle(.userHome)
        } footer: {
            SettingsFooter("Installed Apps lists application bundles in /Applications and ~/Applications. User Home browses dotfiles, configuration, preferences, launch agents and containers.")
        }
    }

    @ViewBuilder private var activityPane: some View {
        Section {
            Toggle(isOn: binding(\.recordActivity)) {
                SettingsLabel("Record activity", help: "Master switch. When off, no timeline events are stored or shown. Metric history is unaffected.")
            }
        } footer: {
            SettingsFooter("Smack records events only while it is running. Recording adds disk writes, roughly 335 bytes per event before retention/compaction. Off stops event storage, while collectors and enabled alert rules keep running. Which events are recorded is chosen in each feature's pane: System, Processes, Network, Security, AI Agents and Alerts.")
        }
        if settings.settings.recordActivity {
            Section {
                StepperRow(title: "Event retention", help: "How long timeline events are kept. Events are also capped in number.", text: "\(settings.settings.eventRetentionDays) days", value: binding(\.eventRetentionDays), range: CollectionSettings.eventRetentionRange)
                StepperRow(title: "Maximum events", help: "The newest events kept regardless of retention; older ones are deleted first. About 335 bytes each on disk.",
                           text: settings.settings.maximumEventRows.formatted(), value: binding(\.maximumEventRows), range: CollectionSettings.maximumEventRowsRange, step: 10_000)
            }
        }
    }

    @ViewBuilder private var automationPane: some View {
        if Capabilities.supportsControlSocket {
            Section {
                Toggle(isOn: localBinding(\.controlSocketEnabled)) {
                    SettingsLabel("CLI and local control socket", help: "Accepts same-user cached queries and delivery-only alert controls. Off closes the listener and connected followers immediately.",
                        subtitle: "Expected low idle overhead; requests use cached data/history. Follow adds per-client buffering and 2 s heartbeats. Production budget unverified.")
                }
            }
        }
        Section {
            Toggle(isOn: localBinding(\.appIntentsEnabled)) {
                SettingsLabel("Shortcuts and App Intents", help: "Off rejects intent execution and entity queries. Packaged intents may remain listed in Shortcuts.",
                    subtitle: "No periodic collection; CPU and bounded cached/history reads on invocation. Cold invocation may launch Smack.")
            }
            Toggle(isOn: localBinding(\.urlNavigationEnabled)) {
                SettingsLabel("URL navigation", help: "Allows smack:// navigation from launchers, CLI, Shortcuts and notification Open actions. Off ignores URL opens.",
                    subtitle: "No idle polling. Opening a page starts its normal visible-page work.")
            }
        }
    }

    @ViewBuilder private var historyPane: some View {
        Section {
            StepperRow(title: "Retention", text: "\(settings.settings.retentionDays) days", value: binding(\.retentionDays), range: 1...365)
            StepperRow(title: "Full resolution", help: "Older samples are kept as one-minute averages and peaks.", text: "\(settings.settings.fullResolutionHours) hours", value: binding(\.fullResolutionHours), range: 1...168)
            StepperRow(title: "Storage limit", help: "When reached, process history older than an hour is compacted to one-minute points, then the oldest process history is deleted; system history is deleted only as a last resort.", text: "\(settings.settings.historyStorageLimitMB) MB", value: binding(\.historyStorageLimitMB), range: 25...10_000, step: 25)
        } footer: {
            SettingsFooter("Process history, usually the largest part, is set in Processes.")
        }
        Section {
            if let usage = model.usage {
                ForEach(usage.categories) { category in
                    LabeledContent {
                        Text(Formatting.bytes(UInt64(category.bytes))).monospacedDigit()
                    } label: {
                        SettingsLabel(
                            category.kind.rawValue, help: "\(category.rows.formatted()) rows, including indexes.",
                            subtitle: category.bytesPerHour(now: usage.measuredAt).map { "~\(Formatting.bytes(UInt64($0)))/h" } ?? "Rate needs at least an hour of data"
                        )
                    }
                }
                LabeledContent("Database file") { Text(Formatting.bytes(UInt64(usage.fileBytes))).monospacedDigit() }
            }
            LabeledContent {
                HStack {
                    if model.isMeasuring { ProgressView().controlSize(.small) }
                    Button(model.usage == nil ? "Calculate" : "Recalculate") { measureUsage() }.disabled(model.isMeasuring)
                }
            } label: {
                SettingsLabel("History database", subtitle: model.usage.map { "Measured \($0.measuredAt.formatted(date: .omitted, time: .shortened))" } ?? "Not measured yet")
            }
            LabeledContent {
                HStack {
                    if model.isCompacting { ProgressView().controlSize(.small) }
                    Button("Compact…") { model.confirmCompact = true }.disabled(model.isCompacting)
                }
            } label: {
                SettingsLabel("Compact database", help: "Rewrites the database file to give space left by deleted history back to the disk. Smack also compacts automatically when the storage limit is reached.",
                              subtitle: model.lastCompacted.map { "Last compacted \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not compacted manually yet")
            }
        } header: {
            Text("Storage Usage")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let error = model.usageError ?? model.compactError { Text(error).foregroundStyle(.red) }
                SettingsFooter("Measures what each collection occupies in the local history database. Rates are averages over the stored span, so they reflect real usage including compaction.")
            }
        }
        .task { model.lastCompacted = try? await store.history.lastCompacted() }
        Section {
            Toggle(isOn: $model.includeEvents) {
                SettingsLabel("Include activity events", help: "Adds events to the JSON export, or an extra -events.csv file. Default exports contain metrics only.")
            }
            LabeledContent("Export") {
                HStack {
                    Button("JSON…") { export(.json) }
                    Button("CSV…") { export(.csv) }
                }
            }
            LabeledContent {
                Button("Delete…", role: .destructive) { model.confirmDelete = true }
            } label: {
                SettingsLabel("Delete all Historical Data", subtitle: "Metric samples and timeline events. Cannot be undone.")
            }
        } header: {
            Text("Export and delete")
        } footer: {
            if let error = settings.errorMessage ?? model.exportError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// The Activity Timeline switches a feature owns, under one header in every feature pane. They depend on the
    /// Record activity master switch, so they are hidden (keeping their values) while it is off.
    @ViewBuilder private func timelineSection<Rows: View, Warning: View>(@ViewBuilder _ rows: () -> Rows,
                                                                         @ViewBuilder warning: () -> Warning = { EmptyView() }) -> some View {
        if settings.settings.recordActivity {
            Section {
                rows()
            } header: {
                Text("Record on the Activity Timeline")
            } footer: {
                warning()
            }
        } else {
            Section {
                LabeledContent("Record activity is off") {
                    Button("Activity Timeline") { model.pane = .activity }
                }
            } header: {
                Text("Record on the Activity Timeline")
            }
        }
    }

    /// The master switch of an environment page: off drops its Summary tile and stops its discovery and refresh.
    private func summaryToggle(_ page: SummaryPage) -> some View {
        Toggle(isOn: pageBinding(page)) {
            SettingsLabel("Show on Summary", help: "Off removes the \(page.rawValue) tile from Summary and skips its discovery and background refresh, saving the commands and file scans it would run.")
        }
    }

    private var presetBinding: Binding<PerformancePreset?> {
        Binding(get: { PerformancePreset.matching(settings.settings) }, set: { preset in
            guard let preset else { return }
            settings.update { preset.apply(to: &$0) }
            store.settingsChanged()
        })
    }

    @ViewBuilder private var aboutPane: some View {
        Section {
            LabeledContent("Version", value: Self.appVersion)
            LabeledContent("Author") {
                HStack(spacing: 0) {
                    Text("Alessandro Franceschi (")
                    Link("Alvagante", destination: URL(string: "https://www.alvagante.com")!)
                    Text(") / ")
                    Link("Lab42", destination: URL(string: "https://www.lab42.it")!)
                }
            }
            LabeledContent("Source code") {
                Link("github.com/alvagante/smack", destination: URL(string: "https://github.com/alvagante/smack")!)
            }
            LabeledContent("License", value: "MIT")
        } footer: {
            SettingsFooter("AI engineered by Alessandro Franceschi.")
        }
    }

    /// Read from the bundle's Info.plist so it always matches the shipped build; unbundled debug runs have none.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "development build" }
        guard let build = info?["CFBundleVersion"] as? String else { return version }
        return "\(version) (\(build))"
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<CollectionSettings, Value>) -> Binding<Value> {
        Binding(get: { settings.settings[keyPath: keyPath] }, set: { value in
            settings.update { $0[keyPath: keyPath] = value }
            store.settingsChanged()
        })
    }

    /// Two-way binding for panel sound selection that persists user choices and triggers preview playback.
    var soundSelectionBinding: Binding<PanelSound> {
        Binding(
            get: { settings.settings.panelSound },
            set: { sound in
                settings.update { $0.panelSound = sound }
                store.settingsChanged()
                SmackSound().play(sound: sound)
            }
        )
    }

    /// Appearance changes only need saving; `settingsChanged()` would restart sampling on every slider tick.
    private func appearanceBinding<Value>(_ keyPath: WritableKeyPath<CollectionSettings, Value>) -> Binding<Value> {
        Binding(get: { settings.settings[keyPath: keyPath] }, set: { value in
            settings.update { $0[keyPath: keyPath] = value }
        })
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<CollectionSettings, TimeInterval?>) -> Binding<TimeInterval?> {
        binding(keyPath)
    }

    private func measureUsage() {
        model.isMeasuring = true
        model.usageError = nil
        Task {
            do { model.usage = try await store.history.storageUsage() }
            catch { model.usageError = error.localizedDescription }
            model.isMeasuring = false
        }
    }

    private func compact() {
        model.isCompacting = true
        model.compactError = nil
        Task {
            do {
                model.lastCompacted = try await store.history.compactNow()
                if model.usage != nil { measureUsage() }
            } catch { model.compactError = error.localizedDescription }
            model.isCompacting = false
        }
    }

    /// For settings only page monitors read: saved without restarting sampling.
    private func localBinding<Value>(_ keyPath: WritableKeyPath<CollectionSettings, Value>) -> Binding<Value> {
        appearanceBinding(keyPath)
    }

    private func pageBinding(_ page: SummaryPage) -> Binding<Bool> {
        Binding(get: { settings.settings.shows(page) }, set: { show in
            settings.update { settings in
                settings.hiddenPages.removeAll { $0 == page }
                if !show { settings.hiddenPages.append(page) }
            }
        })
    }

    private func agentBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !settings.settings.excludedAgents.contains(id) }, set: { include in
            settings.update { settings in
                settings.excludedAgents.removeAll { $0 == id }
                if !include { settings.excludedAgents.append(id) }
            }
        })
    }

    private func export(_ format: HistoryExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Smack-history.\(format == .json ? "json" : "csv")"
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let includeEvents = model.includeEvents
        Task {
            do { try await store.history.export(to: url, format: format, includeEvents: includeEvents) }
            catch { model.exportError = error.localizedDescription }
        }
    }
}

struct PrivilegedSamplingSection: View {
    @ObservedObject var controller: PrivilegedSamplingController
    @ObservedObject var settings: SettingsStore
    let onChange: () -> Void
    var toggleTitle = "Sample other users' processes"

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { settings.settings.privilegedSampling },
            set: { enabled in
                settings.update { $0.privilegedSampling = enabled }
                onChange()
                controller.setEnabled(enabled)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(toggleTitle)
                Spacer(minLength: 8)
                Toggle(toggleTitle, isOn: isEnabled).labelsHidden().toggleStyle(.switch).disabled(controller.isWorking)
            }
            SettingsFooter("Uses a root helper for process metrics, open-file and connection inventory, listening ports, optional full-disk size scans, and scheduled BTM/profile inventory. Those inventory commands are fixed and bounded. Expected CPU/I/O grows with sampling frequency and scan size; helper energy cost is not yet measured. Off stops app requests; removing the helper also removes the installed daemon. \(setupHint)")
            if settings.settings.privilegedSampling {
                HStack(spacing: 8) {
                    Image(systemName: statusImage)
                        .foregroundStyle(statusColor)
                    Text(controller.statusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if controller.isWorking { ProgressView().controlSize(.small) }
                    RefreshButton { Task { await controller.refresh() } }
                }
                HStack(spacing: 8) {
                    if controller.mode == .legacyInstall {
                        switch controller.state {
                        case .notInstalled:
                            Button("Install Helper…") { Task { await controller.install() } }
                        case .notResponding:
                            Button("Reinstall Helper…") { Task { await controller.install() } }
                        case .running(updateAvailable: true):
                            Button("Update Helper…") { Task { await controller.install() } }
                        default:
                            EmptyView()
                        }
                    }
                    if controller.state == .requiresApproval || controller.state == .notResponding {
                        Button("Open Login Items") { controller.openLoginItemsSettings() }
                    }
                }
                .disabled(controller.isWorking)
                if controller.mode == .legacyInstall, controller.state != .running(updateAvailable: false) {
                    terminalFallback(.install)
                }
            } else if controller.legacyInstallPresent {
                HStack(spacing: 8) {
                    Text("The helper is still installed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Remove Helper…") { Task { await controller.remove() } }
                        .disabled(controller.isWorking)
                }
                terminalFallback(.uninstall)
            }
            if let error = controller.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .controlSize(.small)
        .task { await controller.refresh() }
    }

    private var setupHint: String {
        switch controller.mode {
        case .serviceManagement:
            return "macOS asks you to approve Smack Helper in Login Items."
        case .legacyInstall:
            return "macOS asks for an administrator password to install it, and again to remove it."
        case .unsupported:
            return "Requires a build signed with a certificate."
        }
    }

    /// The same script the password prompt runs, for users who prefer Terminal.
    private func terminalFallback(_ action: HelperScriptAction) -> some View {
        DisclosureGroup("Or run in Terminal") {
            HStack(alignment: .top, spacing: 8) {
                Text(controller.terminalCommand(for: action))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy") { controller.copyTerminalCommand(for: action) }
            }
        }
        .font(.caption)
    }

    private var statusImage: String {
        switch controller.state {
        case .running(let updateAvailable): return updateAvailable ? "exclamationmark.shield" : "checkmark.shield"
        case .requiresApproval, .notResponding: return "exclamationmark.shield"
        default: return "shield.slash"
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .running(let updateAvailable): return updateAvailable ? .orange : .green
        case .requiresApproval, .notResponding: return .orange
        default: return .secondary
        }
    }
}

// MARK: Building blocks

/// White symbol on a rounded colored square, as in the System Settings sidebar.
private struct SettingsIcon: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Row title with an optional ⓘ tooltip and an optional secondary line below it.
struct SettingsLabel: View {
    let title: String
    var help: String?
    var subtitle: String?

    init(_ title: String, help: String? = nil, subtitle: String? = nil) {
        self.title = title
        self.help = help
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(title)
                if let help {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help(help)
                        .accessibilityLabel(help)
                }
            }
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

/// Section footer text: small, secondary, wrapping.
private struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct NumberField: View {
    @Binding var value: Double
    let unit: String
    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 56)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}

/// A count or duration: current value on the right of the label, then a stepper.
private struct StepperRow: View {
    let title: String
    var help: String?
    let text: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(text).monospacedDigit()
                Stepper(title, value: $value, in: range, step: step).labelsHidden()
            }
        } label: { SettingsLabel(title, help: help) }
    }
}

/// A switch that enables an interval, with the interval field and its storage estimate shown only while enabled.
private struct IntervalRow: View {
    let title: String
    var help: String?
    var estimate: ((TimeInterval) -> String)?
    @Binding var seconds: TimeInterval?
    let minimum: Double
    var defaultSeconds: TimeInterval = 5

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if seconds != nil {
                    NumberField(value: Binding(get: { seconds ?? minimum }, set: { seconds = $0 }), unit: "s")
                }
                Toggle(title, isOn: Binding(get: { seconds != nil }, set: { seconds = $0 ? max(minimum, defaultSeconds) : nil }))
                    .labelsHidden().toggleStyle(.switch)
            }
        } label: {
            SettingsLabel(title, help: help, subtitle: seconds.flatMap { estimate?($0) } ?? "Off")
        }
    }
}

/// One row per folder with a remove button, then an add button that opens a folder picker.
private struct FolderListRows: View {
    @Binding var folders: [String]
    let addTitle: String
    let empty: String

    var body: some View {
        if folders.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        }
        ForEach(folders, id: \.self) { folder in
            LabeledContent {
                Button(role: .destructive) { folders.removeAll { $0 == folder } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove")
            } label: {
                Text((folder as NSString).abbreviatingWithTildeInPath).truncationMode(.middle).lineLimit(1)
            }
        }
        LabeledContent("") {
            Button(addTitle) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = true
                guard panel.runModal() == .OK else { return }
                folders += panel.urls.map(\.path).filter { !folders.contains($0) }
            }
        }
    }
}
