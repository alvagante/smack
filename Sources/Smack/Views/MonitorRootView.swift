import SwiftUI

/// Root host view for the Smack system monitor panel containing top-level navigation,
/// route switching, glass background effects, and application lifecycle controls.
struct MonitorRootView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var nativeMenuBarStore: NativeMenuBarStore
    @ObservedObject var settingsStore: SettingsStore
    /// Closure invoked when the user activates the top navigation Quit button or presses ⌘Q.
    var onQuit: () -> Void = { NSApplication.shared.terminate(nil) }
    /// Indicates whether the header navigation bar includes a prominent Quit button.
    var hasQuitButton: Bool { true }

    /// Initializes the root monitor view.
    /// - Parameters:
    ///   - store: Primary monitor store providing metrics and active navigation route.
    ///   - nativeMenuBarStore: Store governing native menu bar icon status items.
    ///   - onQuit: Termination callback invoked upon triggering application exit.
    init(store: MonitorStore, nativeMenuBarStore: NativeMenuBarStore, onQuit: @escaping () -> Void = { NSApplication.shared.terminate(nil) }) {
        self.store = store
        self.nativeMenuBarStore = nativeMenuBarStore
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
                Button { store.route = .history } label: { Image(systemName: "clock.arrow.circlepath") }.help("Historical Data")
                Button { store.route = .settings } label: { Image(systemName: "gear") }.help("Settings")
                Button(action: onQuit) {
                    Image(systemName: "power")
                }
                .help("Quit Smack (⌘Q)")
                .accessibilityLabel("Quit Smack")
                .keyboardShortcut("q", modifiers: .command)
            }.padding(.horizontal).padding(.vertical, 10)
            Divider()
            Group {
                switch store.route {
                case .summary: SummaryView(store: store)
                case .resource(let resource): ResourceDetailView(store: store, resource: resource)
                case .applications: ApplicationListView(store: store)
                case .application(let id): ApplicationDetailView(store: store, id: id)
                case .process(let id): ProcessDetailView(store: store, id: id)
                case .networkPorts: NetworkPortsView(store: store)
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
        .frame(minWidth: 400, minHeight: 420)
        // Lists draw opaque backgrounds that would hide the glass.
        .scrollContentBackground(settingsStore.settings.glassMode ? .hidden : .automatic)
        .background { if settingsStore.settings.glassMode { GlassBackground(opacity: settingsStore.settings.glassOpacity).ignoresSafeArea() } }
        .alert("Smack", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}
