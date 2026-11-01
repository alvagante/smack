import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class BaselineModel: ObservableObject {
    @Published var rows: [(URL, BaselineDocument)] = []
    @Published var progress: [String: String] = [:]
    @Published var capturing = false
    @Published var name = ""
    @Published var note = ""
    @Published var selectedSections = Set(BaselineDiff.rules.keys)
    @Published var baseID = ""
    @Published var againstID = "now"
    @Published var current: BaselineDocument?
    @Published var diff: BaselineDiffResult?
    @Published var message: String?
    var task: Task<Void, Never>?
    let repository: BaselineRepository
    init(repository: BaselineRepository = BaselineRepository()) { self.repository = repository }

    func refresh() async {
        do {
            rows = try await repository.list()
            let ids = Set(rows.map { $0.0.lastPathComponent })
            if !ids.contains(baseID) { baseID = rows.first?.0.lastPathComponent ?? "" }
            if againstID != "now", !ids.contains(againstID) { againstID = "now" }
        } catch { message = error.localizedDescription }
    }
    func save(_ document: BaselineDocument, settings: CollectionSettings) async throws -> URL {
        let path = try await repository.save(document, retention: settings.baselineRetentionCount, golden: settings.goldenBaselineID)
        await refresh()
        return path
    }
}

struct BaselineView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var model: BaselineModel
    @ObservedObject var settingsStore: SettingsStore
    init(store: MonitorStore, model: BaselineModel) {
        self.store = store; self.model = model; self.settingsStore = store.settingsStore
    }
    @State private var importing = false
    @State private var pinned = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Baselines").font(.title2)
                TextField("Name", text: $model.name)
                TextField("Note", text: $model.note)
                Toggle("Pin capture", isOn: $pinned)
                Stepper("Keep \(settingsStore.settings.baselineRetentionCount) unpinned baselines", value: Binding(
                    get: { settingsStore.settings.baselineRetentionCount },
                    set: { value in settingsStore.update { $0.baselineRetentionCount = value } }), in: 1...1000)
                DisclosureGroup("Sections") {
                    ForEach(BaselineDiff.rules.keys.sorted(), id: \.self) { id in
                        Toggle(id, isOn: Binding(get: { model.selectedSections.contains(id) }, set: {
                            if $0 { model.selectedSections.insert(id) } else { model.selectedSections.remove(id) }
                        }))
                    }
                }
                HStack {
                    Button("Capture and save") { capture(save: true) }
                        .disabled(model.capturing || model.selectedSections.isEmpty)
                    Button("Import") { importing = true }
                    if model.capturing { Button("Cancel") { model.task?.cancel() } }
                }
                if model.capturing {
                    ProgressView(value: Double(model.progress.count), total: Double(max(1, model.selectedSections.count)))
                    ForEach(model.progress.keys.sorted(), id: \.self) { id in Text(id + ": " + model.progress[id]!).font(.caption) }
                }
                Picker("Base", selection: $model.baseID) {
                    Text("Choose baseline").tag("")
                    ForEach(model.rows, id: \.0) { url, doc in
                        Text(doc.name + " (" + doc.capturedAt.ISO8601Format() + ")").tag(url.lastPathComponent)
                    }
                }
                HStack {
                    Button("Load metadata") {
                        run {
                            let doc = try await model.repository.load(model.baseID)
                            model.name = doc.name; model.note = doc.note; pinned = doc.pinned
                        }
                    }
                    Button("Save metadata") {
                        run {
                            try await model.repository.update(model.baseID, name: model.name, note: model.note, pinned: pinned)
                            await model.refresh()
                        }
                    }
                }.disabled(model.baseID.isEmpty)
                Picker("Against", selection: $model.againstID) {
                    Text("Now (fresh, unsaved)").tag("now")
                    ForEach(model.rows, id: \.0) { url, doc in Text(doc.name).tag(url.lastPathComponent) }
                }
                HStack {
                    Button("Compare") { compare() }.disabled(model.baseID.isEmpty || model.capturing)
                    Button("Export baseline") {
                        run {
                            let doc = try await model.repository.load(model.baseID)
                            try export(doc.encoded(), name: model.baseID, type: .json)
                        }
                    }.disabled(model.baseID.isEmpty)
                    if let current = model.current {
                        Button("Save current") { run { _ = try await model.save(current, settings: settingsStore.settings) } }
                    }
                }
                HStack {
                    Button("Use as golden") {
                        settingsStore.update { $0.goldenBaselineID = model.baseID }
                    }.disabled(model.baseID.isEmpty)
                    Toggle("Daily drift check", isOn: Binding(
                        get: { settingsStore.settings.scheduledDriftCheck },
                        set: { value in settingsStore.update { $0.scheduledDriftCheck = value } }))
                }
                if let diff = model.diff {
                    HStack {
                        Button("JSON report") { run { try export(diff.encoded(), name: "drift.json", type: .json) } }
                        Button("Markdown report") { run { try export(Data(diff.markdown.utf8), name: "drift.md", type: .plainText) } }
                    }
                    Text(diff.markdown).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
            }.padding()
        }
        .task { await model.refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            run {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let document = try await Task.detached { try BaselineDocument.read(url) }.value
                _ = try await model.save(document, settings: settingsStore.settings)
            }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await action() } catch { model.message = error.localizedDescription } }
    }
    private func capture(save: Bool) {
        model.task = Task {
            model.capturing = true
            model.progress = [:]
            defer { model.capturing = false }
            do {
                var doc = try await store.captureBaseline(name: model.name, sections: model.selectedSections.sorted())
                doc.note = model.note
                doc.pinned = pinned
                model.current = doc
                if save { _ = try await model.save(doc, settings: settingsStore.settings) }
            } catch { model.message = error.localizedDescription }
        }
    }
    private func compare() {
        model.task = Task {
            model.capturing = true
            model.progress = [:]
            defer { model.capturing = false }
            do {
                let base = try await model.repository.load(model.baseID)
                let against: BaselineDocument
                if model.againstID == "now" {
                    against = try await store.captureBaseline(name: "Now", sections: base.sections.keys.sorted())
                    model.current = against
                } else { against = try await model.repository.load(model.againstID) }
                model.diff = BaselineDiff.compare(base, against)
            } catch { model.message = error.localizedDescription }
        }
    }
    private func export(_ data: Data, name: String, type: UTType) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        if panel.runModal() == .OK, let url = panel.url { try data.write(to: url, options: .atomic) }
    }
}
