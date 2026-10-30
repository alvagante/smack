import SwiftUI
import AppKit

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var confirmDelete = false
    @Published var exportError: String?
    @Published var includeEvents = false
}

/// Settings management view displaying configuration cards for panel triggers, sound feedback,
/// appearance glass styling, background collection intervals, and application termination controls.
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
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 560), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                panelCard
                aboutCard
                appearanceCard
                collectionCard
                historyCard
                activityCard
                if Capabilities.supportsPrivilegedSampling, let controller = store.privilegedSampling {
                    SettingsCard(title: "Superuser Sampling", systemImage: "lock.shield") {
                        PrivilegedSamplingSection(controller: controller, settings: settings, onChange: { store.settingsChanged() })
                    }
                }
            }
            .padding()
        }
        .confirmationDialog("Delete all Historical Data?", isPresented: $model.confirmDelete) {
            Button("Delete History", role: .destructive) { Task { try? await store.history.deleteAll() } }
        }
    }

    // MARK: Cards

    private var panelCard: some View {
        SettingsCard(title: "Panel", systemImage: "macwindow") {
            SettingsRow("Open with", help: "How the camera hot zone opens the panel.") {
                Picker("Open with", selection: binding(\.trigger)) {
                    ForEach(PanelTrigger.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if settings.settings.trigger == .hover {
                SettingsRow("Hover delay") { NumberField(value: binding(\.hoverDelay), unit: "s") }
            }
            SettingsRow("Sound", help: "Auditory feedback played when opening the panel.") {
                Picker("Sound", selection: soundSelectionBinding) {
                    ForEach(PanelSound.allCases) { sound in
                        Text(sound.displayName).tag(sound)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow("Show background processes") { SettingsSwitch(isOn: binding(\.showBackgroundProcesses)) }
            SettingsRow("Launch at Login") { SettingsSwitch(isOn: binding(\.launchAtLogin)) }
        }
    }

    private var appearanceCard: some View {
        SettingsCard(title: "Appearance", systemImage: "paintpalette") {
            SettingsRow("Glass mode", help: "Translucent panel background that shows the desktop through it.") {
                SettingsSwitch(isOn: appearanceBinding(\.glassMode))
            }
            if settings.settings.glassMode {
                SettingsRow("Opacity", help: "Lower shows more of the desktop; higher is more frosted and easier to read.") {
                    Slider(value: appearanceBinding(\.glassOpacity), in: CollectionSettings.glassOpacityRange).frame(width: 140)
                    Text(settings.settings.glassOpacity.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    private var collectionCard: some View {
        SettingsCard(title: "Background Collection", systemImage: "timer") {
            OptionalIntervalRow(title: "System metrics", seconds: optionalBinding(\.backgroundSystemInterval), minimum: 1)
            OptionalIntervalRow(title: "Process metrics", seconds: optionalBinding(\.backgroundProcessInterval), minimum: 1)
            if Capabilities.isSandboxed {
                SettingsCaption("Scheduled inventories are unavailable in the App Sandbox. Use the on-demand inventory button on a process.")
            } else {
                OptionalIntervalRow(title: "Expensive inventories", seconds: optionalBinding(\.backgroundInventoryInterval), minimum: 10)
            }
            SettingsCaption("While the panel is open, metrics update every second. Expensive inventories are on demand unless scheduled.")
            if let warning = settings.settings.warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var historyCard: some View {
        SettingsCard(title: "Historical Data", systemImage: "clock.arrow.circlepath") {
            SettingsRow("Retention") {
                StepperValue(text: "\(settings.settings.retentionDays) days", value: binding(\.retentionDays), range: 1...365)
            }
            SettingsRow("Full resolution", help: "Older samples are kept as one-minute averages and peaks.") {
                StepperValue(text: "\(settings.settings.fullResolutionHours) hours", value: binding(\.fullResolutionHours), range: 1...168)
            }
            SettingsRow("Storage limit", help: "When reached, process history older than an hour is compacted to one-minute points, then the oldest process history is deleted; system history is deleted only as a last resort.") {
                StepperValue(text: "\(settings.settings.historyStorageLimitMB) MB", value: binding(\.historyStorageLimitMB), range: 25...10_000, step: 25)
            }
            SettingsRow("Include activity events in export", help: "Adds events to the JSON export, or an extra -events.csv file. Default exports contain metrics only.") {
                SettingsSwitch(isOn: $model.includeEvents)
            }
            HStack {
                Button("Export JSON") { export(.json) }
                Button("Export CSV") { export(.csv) }
                Spacer()
                Button(role: .destructive) { model.confirmDelete = true } label: {
                    Label("Delete…", systemImage: "trash").foregroundStyle(.red)
                }
                .help("Delete all Historical Data")
            }
            .controlSize(.small)
            .padding(.top, 2)
            if let error = settings.errorMessage ?? model.exportError {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
    }

    private var activityCard: some View {
        SettingsCard(title: "Activity", systemImage: "list.bullet.rectangle") {
            SettingsRow("Event retention", help: "How long Activity Timeline events are kept. Events are also capped in number.") {
                StepperValue(text: "\(settings.settings.eventRetentionDays) days", value: binding(\.eventRetentionDays), range: CollectionSettings.eventRetentionRange)
            }
            SettingsRow("Record outbound connections", help: "Adds an event for each new outbound connection. Can be noisy and grows the event store faster.") {
                SettingsSwitch(isOn: binding(\.recordConnectionEvents))
            }
            if settings.settings.recordConnectionEvents {
                Label {
                    SettingsCaption("Outbound connection events can be very frequent on busy machines. Event rows are capped, so older events drop sooner.")
                } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).frame(width: 18) }
            }
            SettingsRow("Show events on charts") { SettingsSwitch(isOn: binding(\.showEventsOnCharts)) }
            SettingsCaption("Smack records events only while it is running.")
        }
    }

    private var aboutCard: some View {
        SettingsCard(title: "Privacy & Visibility", systemImage: "hand.raised") {
            HStack {
                SettingsCaption("Closing the panel only hides it; quit to stop all collection.")
                Spacer()
                Button("Quit Smack", action: onQuit)
                    .keyboardShortcut("q")
                    .controlSize(.small)
            }
            Label {
                SettingsCaption("All metrics and settings stay on this Mac; no analytics. Exports contain metrics only, never file paths or connection inventories.")
            } icon: { Image(systemName: "lock").foregroundStyle(.secondary).frame(width: 18) }
            Label {
                SettingsCaption(Capabilities.isSandboxed
                    ? "Smack runs in the App Sandbox. Network Ports, native menu-bar icons, and click forwarding are unavailable, and memory, disk, and energy details are limited for other processes."
                    : "Standard sampling limits open-file and port inspection to your own processes. Superuser sampling extends metrics, inventory, and ports to other users; some Apple system processes remain hidden.")
            } icon: { Image(systemName: "eye").foregroundStyle(.secondary).frame(width: 18) }
        }
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
            SettingsRow(toggleTitle) {
                SettingsSwitch(isOn: isEnabled).disabled(controller.isWorking)
            }
            SettingsCaption("Uses a root helper for process metrics, open-file and connection inventory, listening ports, and optional full-disk directory size scans. It cannot read file contents or run commands. \(setupHint)")
            if settings.settings.privilegedSampling {
                HStack(spacing: 8) {
                    Image(systemName: statusImage)
                        .foregroundStyle(statusColor)
                    Text(controller.statusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if controller.isWorking { ProgressView().controlSize(.small) }
                    Button("Check Again") { Task { await controller.refresh() } }
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

/// A titled card in the Summary style; the grid gives every card in a row the same height.
private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        MetricCard(title: title, systemImage: systemImage) {
            VStack(alignment: .leading, spacing: 10) { content }
        }
    }
}

/// Title on the left, control on the right.
private struct SettingsRow<Control: View>: View {
    let title: String
    var help: String?
    @ViewBuilder let control: Control

    init(_ title: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.help = help
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            if help != nil {
                Image(systemName: "questionmark.circle").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            control
        }
        .font(.callout)
        .help(help ?? "")
    }
}

private struct SettingsSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
}

private struct SettingsCaption: View {
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

private struct StepperValue: View {
    let text: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1

    var body: some View {
        HStack(spacing: 4) {
            Text(text).monospacedDigit()
            Stepper("", value: $value, in: range, step: step).labelsHidden()
        }
    }
}

/// A switch that enables an interval, with the interval field shown only while enabled.
private struct OptionalIntervalRow: View {
    let title: String
    @Binding var seconds: TimeInterval?
    let minimum: Double

    var body: some View {
        SettingsRow(title) {
            if seconds != nil {
                NumberField(value: Binding(get: { seconds ?? minimum }, set: { seconds = $0 }), unit: "s")
            }
            SettingsSwitch(isOn: Binding(get: { seconds != nil }, set: { seconds = $0 ? max(minimum, 5) : nil }))
        }
    }
}
