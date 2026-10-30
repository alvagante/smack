import SwiftUI

/// Root host view for the Smack system monitor panel containing top-level navigation,
/// route switching, glass background effects, and application lifecycle controls.
struct MonitorRootView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var nativeMenuBarStore: NativeMenuBarStore
    @ObservedObject var settingsStore: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var exitControlsState = ExitControlsState()
    var onClose: () -> Void
    /// Closure invoked when the user chooses Quit from the top navigation controls.
    var onQuit: () -> Void = { _ = NSApplication.shared.sendAction(#selector(AppDelegate.requestQuit(_:)), to: nil, from: nil) }
    /// Indicates whether the header navigation bar includes the expandable Quit control.
    var hasQuitButton: Bool { true }

    /// Initializes the root monitor view.
    /// - Parameters:
    ///   - store: Primary monitor store providing metrics and active navigation route.
    ///   - nativeMenuBarStore: Store governing native menu bar icon status items.
    ///   - onClose: Hides the panel while preserving background collection.
    ///   - onQuit: Termination callback invoked upon triggering application exit.
    init(store: MonitorStore, nativeMenuBarStore: NativeMenuBarStore, onClose: @escaping () -> Void, onQuit: @escaping () -> Void = { _ = NSApplication.shared.sendAction(#selector(AppDelegate.requestQuit(_:)), to: nil, from: nil) }) {
        self.store = store
        self.nativeMenuBarStore = nativeMenuBarStore
        self.onClose = onClose
        self.onQuit = onQuit
        settingsStore = store.settingsStore
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if store.route == .advancedSystemDetails {
                    Button { store.route = .systemDetails } label: { Label("System Details", systemImage: "chevron.left") }
                } else if store.route != .summary {
                    Button { store.route = .summary } label: { Label("Summary", systemImage: "chevron.left") }
                } else {
                    Label("Smack", systemImage: "waveform.path.ecg").font(.headline)
                }
                if Capabilities.supportsNativeMenuBarIcons {
                    NativeMenuBarView(menuBarStore: nativeMenuBarStore, settingsStore: store.settingsStore)
                }
                Spacer()
                if let date = store.system?.timestamp {
                    Text(date, style: .time).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                ThermalDot(condition: store.system?.thermalCondition ?? .unavailable) { store.route = .resource(.thermal) }
                Button { store.route = .history } label: { Image(systemName: "clock.arrow.circlepath") }
                    .hoverHint("Historical Data")
                    .accessibilityLabel("Historical Data")
                Button { store.route = .settings } label: { Image(systemName: "gear") }
                    .hoverHint("Settings")
                    .accessibilityLabel("Settings")
                Button { store.route = .systemDetails } label: { Image(systemName: "info.circle") }
                    .hoverHint("System Details")
                    .accessibilityLabel("System Details")
                exitControls
            }.padding(.horizontal).padding(.vertical, 10)
            Divider()
            if let warning = store.historyHealth.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .hoverHint(store.historyHealth.details)
                Divider()
            }
            Group {
                switch store.route {
                case .summary: SummaryView(store: store)
                case .resource(.storage): StorageView(store: store)
                case .resource(let resource): ResourceDetailView(store: store, resource: resource)
                case .applications: ApplicationListView(store: store)
                case .application(let id): ApplicationDetailView(store: store, id: id)
                case .process(let id): ProcessDetailView(store: store, id: id)
                case .networkPorts: NetworkPortsView(store: store)
                case .startupItems: StartupItemsView(model: store.startupItemsModel)
                case .timeline: TimelineView(store: store)
                case .history: HistoryView(store: store)
                case .settings: SettingsView(store: store)
                case .systemDetails: SystemDetailsView(store: store)
                case .advancedSystemDetails: AdvancedSystemDetailsView(store: store)
                }
            }
            // Top-aligned and clipped so an oversized route never pushes the navigation header out of view.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .frame(minWidth: 400, minHeight: 340)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            exitControlsState.isExpanded = false
        }
        .onChange(of: store.route) { exitControlsState.isExpanded = false }
        // Lists draw opaque backgrounds that would hide the glass.
        .scrollContentBackground(settingsStore.settings.glassMode ? .hidden : .automatic)
        .background { if settingsStore.settings.glassMode { GlassBackground(opacity: settingsStore.settings.glassOpacity).ignoresSafeArea() } }
        .alert("Smack", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
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
