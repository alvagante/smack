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
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("A baseline is an offline snapshot of this Mac's configuration: system version, security posture, startup items, listening ports, apps, Homebrew, runtimes, agents, profiles, system extensions and Docker. Capture one when the Mac is in a known good state, then compare it with now or with another baseline to see what was added, removed or changed. Mark one as golden to check drift against it every day.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        captureCard
                        manageCard
                    }
                    compareCard
                    if let diff = model.diff { reportCard(diff) }
                    if let message = model.message {
                        Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding([.horizontal, .bottom])
            }
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

    private var header: some View {
        HStack(spacing: 16) {
            ResourceTitle(title: "Baselines", systemImage: "arrow.triangle.branch", color: .indigo,
                          subtitle: "Snapshot configuration, detect drift", status: status)
            DetailStatsGrid(stats: stats, color: .indigo)
            Spacer(minLength: 0)
            if model.capturing { ProgressView().controlSize(.small) }
            ToolbarIconButton(title: "Import baseline", systemImage: "square.and.arrow.down", color: .indigo,
                              hint: "Import a baseline JSON file") { importing = true }
            RefreshButton(hint: "Reload saved baselines") { Task { await model.refresh() } }
        }
        .padding()
    }

    private var status: ResourceStatus? {
        if let diff = model.diff {
            return diff.drift
                ? ResourceStatus(title: "Drift", color: .orange, help: "The last comparison found differences.")
                : ResourceStatus(title: "No drift", color: .green, help: "The last comparison found no differences.")
        }
        if settingsStore.settings.scheduledDriftCheck, goldenName != nil {
            return ResourceStatus(title: "Watching", color: .blue, help: "Daily drift check against the golden baseline is on.")
        }
        return nil
    }

    private var goldenName: String? {
        guard let id = settingsStore.settings.goldenBaselineID else { return nil }
        return model.rows.first { $0.0.lastPathComponent == id }?.1.name ?? id
    }

    private var stats: [ResourceStat] {
        [
            ResourceStat(title: "Saved", systemImage: "tray.full", value: String(model.rows.count),
                         detail: "keep \(settingsStore.settings.baselineRetentionCount)",
                         help: "Saved baselines. Pinned ones are never pruned."),
            ResourceStat(title: "Golden", systemImage: "star.fill", value: goldenName.map { $0.isEmpty ? "Unnamed" : $0 } ?? "None",
                         help: "Baseline used for the daily drift check.", color: .yellow),
            ResourceStat(title: "Drift check", systemImage: "clock.arrow.circlepath",
                         value: settingsStore.settings.scheduledDriftCheck ? "Daily" : "Off", color: .blue),
        ]
    }

    private var captureCard: some View {
        BaselineCard(title: "Capture", systemImage: "camera.viewfinder", color: .indigo,
                     caption: "Record the current state of this Mac as a new baseline.") {
            TextField("Name, e.g. Post-onboarding", text: $model.name).textFieldStyle(.roundedBorder)
            TextField("Note", text: $model.note).textFieldStyle(.roundedBorder)
            Toggle("Pin (never pruned by retention)", isOn: $pinned)
            DisclosureGroup("Sections (\(model.selectedSections.count) of \(BaselineDiff.rules.count))") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(BaselineDiff.rules.keys.sorted(), id: \.self) { id in
                        Toggle(id, isOn: Binding(get: { model.selectedSections.contains(id) }, set: {
                            if $0 { model.selectedSections.insert(id) } else { model.selectedSections.remove(id) }
                        }))
                    }
                }
            }
            HStack {
                Button { capture(save: true) } label: { Label("Capture and save", systemImage: "camera") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.capturing || model.selectedSections.isEmpty)
                if model.capturing { Button("Cancel", role: .cancel) { model.task?.cancel() } }
            }
            if model.capturing {
                ProgressView(value: Double(model.progress.count), total: Double(max(1, model.selectedSections.count)))
                ForEach(model.progress.keys.sorted(), id: \.self) { id in
                    Text(id + ": " + model.progress[id]!).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var manageCard: some View {
        BaselineCard(title: "Saved baselines", systemImage: "tray.full", color: .teal,
                     caption: "Rename, pin, export or promote a saved baseline to golden.") {
            basePicker
            HStack {
                Button { run {
                    let doc = try await model.repository.load(model.baseID)
                    model.name = doc.name; model.note = doc.note; pinned = doc.pinned
                } } label: { Label("Edit details", systemImage: "pencil") }
                    .help("Load name, note and pin into the Capture fields")
                Button { run {
                    try await model.repository.update(model.baseID, name: model.name, note: model.note, pinned: pinned)
                    await model.refresh()
                } } label: { Label("Save details", systemImage: "checkmark") }
                    .help("Write the Capture name, note and pin to the selected baseline")
            }.disabled(model.baseID.isEmpty)
            HStack {
                Button { run {
                    let doc = try await model.repository.load(model.baseID)
                    try export(doc.encoded(), name: model.baseID, type: .json)
                } } label: { Label("Export", systemImage: "square.and.arrow.up") }
                Button { settingsStore.update { $0.goldenBaselineID = model.baseID } } label: {
                    Label("Use as golden", systemImage: "star")
                }.disabled(settingsStore.settings.goldenBaselineID == model.baseID)
            }.disabled(model.baseID.isEmpty)
            Divider()
            Toggle("Daily drift check against golden", isOn: Binding(
                get: { settingsStore.settings.scheduledDriftCheck },
                set: { value in settingsStore.update { $0.scheduledDriftCheck = value } }))
            Stepper("Keep \(settingsStore.settings.baselineRetentionCount) unpinned baselines", value: Binding(
                get: { settingsStore.settings.baselineRetentionCount },
                set: { value in settingsStore.update { $0.baselineRetentionCount = value } }), in: 1...1000)
        }
    }

    private var basePicker: some View {
        Picker("Baseline", selection: $model.baseID) {
            Text("Choose baseline").tag("")
            ForEach(model.rows, id: \.0) { url, doc in
                Text(doc.name + " (" + doc.capturedAt.formatted(date: .abbreviated, time: .shortened) + ")").tag(url.lastPathComponent)
            }
        }
    }

    private var compareCard: some View {
        BaselineCard(title: "Compare", systemImage: "arrow.left.arrow.right", color: .orange,
                     caption: "Diff the selected baseline against a fresh capture of now or another saved baseline.") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { basePicker; againstPicker; compareButtons }
                VStack(alignment: .leading) { basePicker; againstPicker; compareButtons }
            }
        }
    }

    private var againstPicker: some View {
        Picker("Against", selection: $model.againstID) {
            Text("Now (fresh, unsaved)").tag("now")
            ForEach(model.rows, id: \.0) { url, doc in Text(doc.name).tag(url.lastPathComponent) }
        }
    }

    private var compareButtons: some View {
        HStack {
            Button { compare() } label: { Label("Compare", systemImage: "arrow.left.arrow.right") }
                .buttonStyle(.borderedProminent)
                .disabled(model.baseID.isEmpty || model.capturing)
            if let current = model.current {
                Button { run { _ = try await model.save(current, settings: settingsStore.settings) } } label: {
                    Label("Save current", systemImage: "square.and.arrow.down.on.square")
                }.help("Save the last fresh capture as a new baseline")
            }
        }
    }

    private func reportCard(_ diff: BaselineDiffResult) -> some View {
        let changes = diff.sections.values.reduce(0) { $0 + $1.count }
        return BaselineCard(title: "Drift report", systemImage: diff.drift ? "exclamationmark.triangle.fill" : "checkmark.seal.fill",
                            color: diff.drift ? .orange : .green,
                            caption: diff.drift ? "\(changes) \(changes == 1 ? "difference" : "differences") found." : "No differences found.") {
            HStack {
                Button { run { try export(diff.encoded(), name: "drift.json", type: .json) } } label: {
                    Label("JSON report", systemImage: "curlybraces")
                }
                Button { run { try export(Data(diff.markdown.utf8), name: "drift.md", type: .plainText) } } label: {
                    Label("Markdown report", systemImage: "doc.text")
                }
            }
            Text(diff.markdown).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
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

/// Titled card grouping one task of the Baselines page.
private struct BaselineCard<Content: View>: View {
    let title: String
    let systemImage: String
    let color: Color
    let caption: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ResourceIcon(systemImage: systemImage, color: color, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08), lineWidth: 1) }
    }
}
