import SwiftUI

/// Root host view for the Smack system monitor panel containing top-level navigation,
/// route switching, glass background effects, and application lifecycle controls.
struct MonitorRootView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var nativeMenuBarStore: NativeMenuBarStore
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var titleBarLayout: TitleBarLayout
    var onClose: () -> Void
    /// Closure invoked when the user chooses Quit from the title bar controls.
    var onQuit: () -> Void = { _ = NSApplication.shared.sendAction(#selector(AppDelegate.requestQuit(_:)), to: nil, from: nil) }
    /// Indicates whether the title bar includes the expandable Quit control.
    var hasQuitButton: Bool { true }

    /// Initializes the root monitor view.
    /// - Parameters:
    ///   - store: Primary monitor store providing metrics and active navigation route.
    ///   - nativeMenuBarStore: Store governing native menu bar icon status items.
    ///   - onClose: Hides the panel while preserving background collection.
    ///   - onQuit: Termination callback invoked upon triggering application exit.
    init(store: MonitorStore, nativeMenuBarStore: NativeMenuBarStore, titleBarLayout: TitleBarLayout = TitleBarLayout(), onClose: @escaping () -> Void, onQuit: @escaping () -> Void = { _ = NSApplication.shared.sendAction(#selector(AppDelegate.requestQuit(_:)), to: nil, from: nil) }) {
        self.titleBarLayout = titleBarLayout
        self.store = store
        self.nativeMenuBarStore = nativeMenuBarStore
        self.onClose = onClose
        self.onQuit = onQuit
        settingsStore = store.settingsStore
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if titleBarLayout.showsSidebar {
                    MonitorSidebar(store: store, settingsStore: settingsStore)
                        .frame(minWidth: 168, idealWidth: 196, maxWidth: 224)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in if titleBarLayout.sidebarWidth != width { titleBarLayout.sidebarWidth = width } }
                }
                VStack(spacing: 0) {
                    if Capabilities.supportsNativeMenuBarIcons, settingsStore.settings.panel.showTopBarIcons {
                        HStack {
                            Spacer(minLength: 0)
                            NativeMenuBarView(menuBarStore: nativeMenuBarStore, settingsStore: settingsStore)
                        }
                        .padding(.horizontal, MonitorStyle.inset)
                        .padding(.vertical, 8)
                        Divider()
                    }
                    pageContent
                }
                    .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                    .background { if !settingsStore.settings.panel.glassMode { MonitorStyle.page } }
            }
        }
        .frame(minWidth: 720, minHeight: 340)
        .background {
            if settingsStore.settings.panel.glassMode {
                GlassBackground(opacity: settingsStore.settings.panel.glassOpacity).ignoresSafeArea()
            } else {
                MonitorStyle.page.ignoresSafeArea()
            }
        }
        .scrollContentBackground(settingsStore.settings.panel.glassMode ? .hidden : .automatic)
        .alert("Smack", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var pageContent: some View {
        VStack(spacing: 0) {
            if let warning = store.historyHealth.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .hoverHint(store.historyHealth.details)
                Divider()
            }
            if let banner = store.navigationFilters.banner, store.route == .applications {
                Text(banner).foregroundStyle(.secondary).padding(8)
            }
            Group {
                switch store.route {
                case .summary: SummaryView(store: store)
                case .resource(.storage): StorageView(store: store)
                case .resource(let resource): ResourceDetailView(store: store, resource: resource)
                case .applications: ApplicationListView(store: store)
                case .application(let id): ApplicationDetailView(store: store, id: id)
                case .process(let id): ProcessDetailView(store: store, id: id)
                case .devServers: DevServersView(store: store)
                case .networkPorts: NetworkPortsView(store: store)
                case .docker: DockerDetailView(model: store.dockerModel)
                case .homebrew: HomebrewDetailView(model: store.homebrewModel)
                case .devEnvironments: DevEnvironmentDetailView(model: store.devEnvironmentModel)
                case .agents: AgentDetailView(model: store.agentsModel, store: store)
                case .installedApps: InstalledAppsDetailView(model: store.installedAppsModel)
                case .userHome: UserHomeDetailView(model: store.userHomeModel)
                case .startupItems: StartupItemsView(model: store.startupItemsModel)
                case .timeline: TimelineView(store: store)
                case .history: HistoryView(store: store)
                case .settings: SettingsView(store: store)
                case .systemDetails: SystemDetailsView(store: store)
                case .baseline: BaselineView(store: store, model: store.baselines)
                case .security:
                    SecurityView(store: store)
                case .unavailable(let message):
                    ContentUnavailableView(message, systemImage: "lock")
                }
            }
            // Top-aligned and clipped so an oversized route never pushes the navigation header out of view.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
    }

    func titleBarControls(layout: TitleBarLayout, onWidthChange: @escaping (CGFloat) -> Void) -> some View {
        MonitorTitleBarControls(store: store, settingsStore: settingsStore, layout: layout,
                                onClose: onClose, onQuit: onQuit, onWidthChange: onWidthChange)
    }
}

/// Width the titlebar accessory may use without covering the window buttons and pin.
@MainActor
final class TitleBarLayout: ObservableObject {
    /// Height of a unified toolbar window header.
    nonisolated static let height: CGFloat = 52
    @Published var available: CGFloat = 560
    @Published var showsSidebar = true
    /// Window x where the accessory starts (after the traffic lights and pin button).
    @Published var leading: CGFloat = 100
    @Published var sidebarWidth: CGFloat = 0

    /// Width of the sidebar and back buttons, so the page title starts over the page, past the sidebar's edge.
    var navigationWidth: CGFloat {
        let buttons: CGFloat = 72
        guard showsSidebar, sidebarWidth > 0 else { return buttons }
        return max(buttons, sidebarWidth + MonitorStyle.spacing - leading)
    }
}

private struct MonitorTitleBarControls: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var layout: TitleBarLayout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var exitControlsState = ExitControlsState()
    let onClose: () -> Void
    let onQuit: () -> Void
    /// The accessory fills the titlebar space available beside the window controls.
    let onWidthChange: (CGFloat) -> Void

    private var options: TitleBarSettings { settingsStore.settings.panel.titleBar }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 0) {
                navigationButtons
                    .buttonStyle(.borderless)
                    .frame(width: layout.navigationWidth, alignment: .leading)
                Text(store.route.title).font(.title3.bold()).lineLimit(1)
                if let subject = store.routeSubject {
                    Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(.tertiary).padding(.horizontal, 6)
                    Text(subject).font(.title3.bold()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(subject)
                }
            }
            .frame(minWidth: 120, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                ForEach(0..<4) { content(shedding: $0) }
            }
        }
            .frame(width: layout.available, height: TitleBarLayout.height)
            .onChange(of: layout.available, initial: true) { _, width in onWidthChange(width) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
                exitControlsState.isExpanded = false
            }
            .onChange(of: store.route) { exitControlsState.isExpanded = false }
    }

    private var navigationButtons: some View {
        HStack(spacing: 4) {
            Button { layout.showsSidebar.toggle() } label: {
                Image(systemName: "sidebar.left").font(.system(size: 15)).frame(width: 32, height: 28)
            }
            .help(layout.showsSidebar ? "Hide sidebar" : "Show sidebar")
            .accessibilityLabel(layout.showsSidebar ? "Hide sidebar" : "Show sidebar")
            Button { store.goBack() } label: {
                Image(systemName: "chevron.left").font(.system(size: 15)).frame(width: 32, height: 28)
            }
            .disabled(store.previousRoute == nil)
            .help("Previous page")
            .accessibilityLabel("Previous page")
        }
    }

    /// `shedding` 1 drops uptime, load and battery; 2 also drops sponsor and thermal; 3 keeps only the clock.
    private func content(shedding: Int) -> some View {
        HStack(spacing: 12) {
            info(shedding: shedding).fixedSize()
            exitControls.fixedSize()
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 16)
    }

    @ViewBuilder private func info(shedding: Int) -> some View {
        if shedding < 2, options.showSponsor && Capabilities.flavor == .direct {
            Button { NSWorkspace.shared.open(TitleBarSettings.sponsorURL) } label: {
                Label { Text("Sponsor") } icon: { Image(systemName: "heart.fill").foregroundStyle(.pink) }
            }
            .buttonStyle(.borderless)
            .hoverHint("Enjoying Smack? Feed the vibes with a small tip :-]")
        }
        if shedding < 3, options.showHostname, let hostname = store.hostIdentity.hostname(options.hostnameStyle) {
            copyable(hostname, hint: hostname, weight: .medium)
        }
        if shedding < 3, options.showNetwork, let cidr = store.hostIdentity.cidr {
            copyable(cidr, hint: networkHint, weight: .regular).monospacedDigit()
        }
        if shedding < 1, options.showUptime, let boot = SystemInformation.bootTime {
            Text("up \(CPUReadings.uptime(Date().timeIntervalSince(boot)))").foregroundStyle(.secondary)
                .hoverHint("Uptime since \(boot.formatted(date: .abbreviated, time: .shortened))")
        }
        if shedding < 1, options.showLoadAverage, let load = SystemInformation.loadAverage {
            Label(load[0].formatted(.number.precision(.fractionLength(2))), systemImage: "gauge.with.dots.needle.33percent")
                .foregroundStyle(.secondary)
                .hoverHint("Load average (1, 5, 15 min): " + load.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: "  "))
        }
        if shedding < 1, options.showBattery, let battery = store.system?.battery, battery.isPresent, let percent = battery.chargePercent {
            Label("\(Int(percent.rounded()))%", systemImage: battery.isCharging ? "battery.100percent.bolt" : Self.batterySymbol(percent))
                .foregroundStyle(percent <= 20 && !battery.isCharging ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .monospacedDigit()
                .hoverHint(battery.isCharging ? "Battery charging" : "Battery")
        }
        if shedding < 2, options.showThermal, let thermal = store.system?.thermalCondition, thermal == .serious || thermal == .critical || thermal == .fair {
            Label(thermal.rawValue.capitalized, systemImage: "thermometer.high")
                .foregroundStyle(thermal == .fair ? .yellow : .orange)
                .hoverHint("The Mac is thermally constrained and may be slowing down.")
        }
        if options.showClock {
            Group {
                if options.clockShowsSeconds {
                    SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in clock(context.date) }
                } else {
                    SwiftUI.TimelineView(.everyMinute) { context in clock(context.date) }
                }
            }
        }
    }

    private func clock(_ date: Date) -> some View {
        Text(options.clockText(date)).monospacedDigit().foregroundStyle(.secondary)
    }

    private func copyable(_ text: String, hint: String, weight: Font.Weight) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: { Text(text).fontWeight(weight) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .hoverHint(hint + "\nClick to copy.")
    }

    private var networkHint: String {
        let identity = store.hostIdentity
        let addresses = identity.addresses.map { address in address.prefix.map { "\(address.address)/\($0)" } ?? address.address }
        return ([identity.primaryInterface.map { "Primary interface \($0)" }].compactMap { $0 } + addresses).joined(separator: "\n")
    }

    private static func batterySymbol(_ percent: Double) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private var exitControls: some View {
        HStack(spacing: 6) {
            if exitControlsState.isExpanded {
                Button {
                    exitControlsState.isExpanded = false
                    onClose()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .tint(.accentColor)
                .hoverHint("Hide the panel. Smack keeps collecting data using your background settings.\nReopen it from the menu bar.")
                .accessibilityHint("Hides the panel and keeps collecting in the background")

                Button(role: .destructive, action: onQuit) {
                    Label("Quit", systemImage: "power")
                }
                .tint(.red)
                .hoverHint("Quit Smack and stop all data collection until you launch it again.\nSaved history is kept. (⌘Q)")
                .accessibilityHint("Quits Smack and stops collecting data")
            } else {
                Button { exitControlsState.isExpanded = true } label: {
                    Image(systemName: "power")
                }
                .hoverHint("Show options to quit Smack or close the panel and keep collecting in the background")
                .accessibilityLabel("Close or quit Smack")
            }
        }
        .buttonStyle(.bordered)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: exitControlsState.isExpanded)
    }
}

@MainActor
private final class ExitControlsState: ObservableObject {
    @Published var isExpanded = false
}
