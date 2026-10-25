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
                OptionalIntervalField(title: "Expensive inventories", seconds: optionalBinding(\.backgroundInventoryInterval), minimum: 10)
                Text("Visible metrics update every second. Expensive inventories are on-demand unless explicitly scheduled.")
                    .font(.caption).foregroundStyle(.secondary)
                if let warning = settings.settings.warning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }

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

private func intervalField(_ title: String, value: Binding<Double>, unit: String) -> some View {
    HStack {
        Text(title)
        Spacer()
        TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
        Text(unit).foregroundStyle(.secondary)
    }
}
