import SwiftUI
import AppKit

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var confirmDelete = false
    @Published var exportError: String?
}

struct SettingsView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var model: SettingsViewModel

    init(store: MonitorStore) {
        self.store = store
        settings = store.settingsStore
        model = store.settingsViewModel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "Panel")
                Picker("Open camera hot zone with", selection: binding(\.trigger)) {
                    ForEach(PanelTrigger.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                intervalField("Hover delay", value: binding(\.hoverDelay), unit: "seconds")
                Toggle("Show background processes", isOn: binding(\.showBackgroundProcesses))
                Toggle("Launch at Login", isOn: binding(\.launchAtLogin))

                SectionHeader(title: "Background Collection")
                OptionalIntervalField(title: "System metrics", seconds: optionalBinding(\.backgroundSystemInterval), minimum: 1)
                OptionalIntervalField(title: "Process metrics", seconds: optionalBinding(\.backgroundProcessInterval), minimum: 1)
                if Capabilities.isSandboxed {
                    Text("Scheduled inventories are unavailable in the App Sandbox. Use the on-demand inventory button on a process.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    OptionalIntervalField(title: "Expensive inventories", seconds: optionalBinding(\.backgroundInventoryInterval), minimum: 10)
                }
                Text("Visible metrics update every second. Expensive inventories are on-demand unless explicitly scheduled.")
                    .font(.caption).foregroundStyle(.secondary)
                if let warning = settings.settings.warning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }

                if Capabilities.supportsPrivilegedSampling, let controller = store.privilegedSampling {
                    SectionHeader(title: "Privileges")
                    PrivilegedSamplingSection(
                        controller: controller,
                        settings: settings,
                        onChange: { store.settingsChanged() }
                    )
                }

                SectionHeader(title: "Historical Data")
                Stepper("Retention: \(settings.settings.retentionDays) days", value: binding(\.retentionDays), in: 1...365)
                Stepper("Full resolution: \(settings.settings.fullResolutionHours) hours", value: binding(\.fullResolutionHours), in: 1...168)
                Stepper("Storage limit: \(settings.settings.historyStorageLimitMB) MB", value: binding(\.historyStorageLimitMB), in: 25...10_000, step: 25)
                HStack {
                    Button("Export JSON") { export(.json) }
                    Button("Export CSV") { export(.csv) }
                    Button("Delete History…", role: .destructive) { model.confirmDelete = true }
                }

                if let error = settings.errorMessage ?? model.exportError { Text(error).foregroundStyle(.red).font(.caption) }
                SectionHeader(title: "Application")
                Button("Quit Smack") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                Text("Closing the panel only hides it. Quit Smack to stop monitoring and background collection completely.")
                    .font(.caption).foregroundStyle(.secondary)
                SectionHeader(title: "Process Visibility")
                if Capabilities.isSandboxed {
                    Text("Smack runs in the App Sandbox. Network Ports, native menu-bar icons, and click forwarding are unavailable, and memory, disk, and energy details are limited for other processes.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Standard sampling limits open-file and port inspection to processes owned by you. Superuser sampling extends metrics, inventory, and ports to other users; some Apple system processes remain hidden.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SectionHeader(title: "Privacy")
                Text("All metrics and settings remain on this Mac. Smack has no analytics. Exports contain metrics only, never file paths or connection inventories.").font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
        .confirmationDialog("Delete all Historical Data?", isPresented: $model.confirmDelete) {
            Button("Delete History", role: .destructive) { Task { try? await store.history.deleteAll() } }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<CollectionSettings, Value>) -> Binding<Value> {
        Binding(get: { settings.settings[keyPath: keyPath] }, set: { value in
            settings.update { $0[keyPath: keyPath] = value }
            store.settingsChanged()
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
        Task {
            do { try await store.history.export(to: url, format: format) }
            catch { model.exportError = error.localizedDescription }
        }
    }
}

private struct PrivilegedSamplingSection: View {
    @ObservedObject var controller: PrivilegedSamplingController
    @ObservedObject var settings: SettingsStore
    let onChange: () -> Void

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
            Toggle("Sample processes owned by other users", isOn: isEnabled)
                .disabled(controller.isWorking)
            Text("Uses a root helper for process metrics, open-file and connection inventory, and listening ports. It cannot read file contents or run commands. \(setupHint)")
                .font(.caption)
                .foregroundStyle(.secondary)
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

private struct OptionalIntervalField: View {
    let title: String
    @Binding var seconds: TimeInterval?
    let minimum: Double
    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(get: { seconds != nil }, set: { seconds = $0 ? max(minimum, 5) : nil }))
            Spacer()
            if seconds != nil {
                TextField("Seconds", value: Binding(get: { seconds ?? minimum }, set: { seconds = $0 }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                Text("sec").foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private func intervalField(_ title: String, value: Binding<Double>, unit: String) -> some View {
    HStack {
        Text(title)
        Spacer()
        TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
        Text(unit).foregroundStyle(.secondary)
    }
}
