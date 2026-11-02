import SwiftUI
import AppKit

struct AgentsSummaryTile: View {
    @ObservedObject var model: AgentMonitor
    var open: () -> Void

    var body: some View {
        if !Capabilities.isSandboxed {
            SummaryNavigationRow(route: .agents,
                value: model.snapshot.map { "\($0.agents.count) detected" } ?? (model.loading ? "Discovering…" : "Explore agents"),
                detail: "Configuration, logs, memory and skills", open: open)
                .background(MonitorStyle.page)
        .task { if model.snapshot == nil { await model.refresh() } }
        }
    }
}

struct AgentDetailView: View {
    @ObservedObject var model: AgentMonitor
    @ObservedObject var store: MonitorStore
    @State private var selectedAgent: String?
    @State private var category: AgentCategory = .configuration
    @State private var selectedArtifact: String?
    @State private var query = ""
    @State private var showingSessions = false
    @StateObject private var browser = UserHomeMonitor()
    @AppStorage(FileContentsScrollView<EmptyView>.wrapKey) private var wrap = false

    private var agents: [InstalledAgent] {
        (model.snapshot?.agents ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var current: InstalledAgent? { agents.first { $0.id == selectedAgent } ?? agents.first }
    private var artifacts: [AgentArtifact] { current?.artifacts.filter { $0.category == category } ?? [] }
    private var artifact: AgentArtifact? { artifacts.first { $0.id == selectedArtifact } ?? artifacts.first }

    private var overview: some View {
        ResourceStatsRow(headline: model.snapshot.map { String($0.agents.count) } ?? "–", unit: "agents", stats: [
            ResourceStat(title: "Executables", systemImage: "terminal", value: model.snapshot.map { String($0.agents.filter { $0.executable != nil }.count) } ?? "Unavailable"),
            ResourceStat(title: "Artifacts", systemImage: "doc.text", value: model.snapshot.map { String($0.agents.reduce(0) { $0 + $1.artifacts.count }) } ?? "Unavailable")
        ], headlineWidth: 120)
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailPageHeader {
                ResourceTitle(title: "Agents", systemImage: "sparkles", color: .purple,
                              subtitle: model.snapshot.map { "Checked \($0.timestamp.formatted(date: .omitted, time: .shortened))" })
            } actions: {
                if model.loading { ProgressView().controlSize(.small) }
                RefreshButton { Task { await model.refresh() } }.disabled(model.loading)
            } overview: {
                overview
            }
            Divider()
            DisclosureGroup(isExpanded: $showingSessions) {
                AgentSessionsView(model: model, store: store)
                    .frame(height: 220)
            } label: {
                Label("Live sessions (\(model.sessions.filter { $0.endedAt == nil }.count))", systemImage: "terminal")
                    .font(.callout.weight(.semibold))
            }
            .padding(.horizontal, MonitorStyle.inset)
            .padding(.vertical, 12)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Filter agents", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 10)
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(agents) { agent in
                                Button {
                                    selectedAgent = agent.id
                                    selectedArtifact = nil
                                } label: {
                                    HStack {
                                        Text(agent.name)
                                        Spacer(minLength: 0)
                                    }
                                }.buttonStyle(DetailNavigationStyle(selected: current?.id == agent.id))
                            }
                        }.padding(12)
                    }
                }.padding(.top, 10).frame(width: 184)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if let agent = current {
                        Text(agent.name).font(.headline)
                        Text(agent.executable.map { "Executable: " + $0 } ?? "Detected from local agent directories; executable not found on inherited PATH.")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        ForEach(agent.roots, id: \.path) { root in
                            Text(root.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text("Discovery uses known user paths and inherited PATH. Existing directories may remain after uninstalling. File previews load on selection, up to 1 MiB.")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(AgentCategory.allCases) { item in
                                    let count = agent.artifacts.filter { $0.category == item }.count
                                    Button { category = item } label: {
                                        Text("\(item.rawValue) (\(count))").font(.callout)
                                            .foregroundStyle(count == 0 && category != item ? .secondary : .primary)
                                            .padding(.horizontal, 10).padding(.vertical, 5)
                                            .background(category == item ? Color.accentColor.opacity(0.15) : .clear,
                                                        in: RoundedRectangle(cornerRadius: 6))
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        if artifacts.isEmpty {
                            ContentUnavailableView("No \(category.rawValue.lowercased()) found", systemImage: "folder",
                                description: Text("No existing paths for this category were found in the known locations."))
                        } else {
                            Picker("Location", selection: Binding(get: { artifact?.id ?? "" }, set: { selectedArtifact = $0 })) {
                                ForEach(artifacts) { item in Text(item.url.path).tag(item.id) }
                            }
                            if let item = artifact {
                                HStack {
                                    Text(item.url.path).font(.caption.monospaced()).textSelection(.enabled)
                                    Spacer()
                                    if !item.isDirectory { WrapToggle(wrap: $wrap) }
                                    ToolbarIconButton(title: "Reveal in Finder", systemImage: "folder", color: .blue) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                }
                                if item.isDirectory {
                                    UserHomeDetailView(model: browser, rootDirectory: item.url).id(item.id)
                                } else {
                                    FileContentsScrollView(wrap: wrap) {
                                        VStack(alignment: .leading, spacing: 10) {
                                            if browser.inspecting { ProgressView("Reading contents…") }
                                            if let preview = browser.preview {
                                                if let message = preview.message { Text(message).foregroundStyle(.secondary) }
                                                Text(preview.text).font(.caption.monospaced()).textSelection(.enabled)
                                                    .fixedSize(horizontal: !wrap, vertical: false)
                                            }
                                        }.padding()
                                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView(model.loading ? "Discovering agents" : "No matching agents", systemImage: "sparkles",
                            description: Text("Detects AI tools from their user directories or executables on inherited PATH."))
                    }
                }.padding(MonitorStyle.inset).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .task { if model.snapshot == nil { await model.refresh() } }
        .task(id: artifact?.id) {
            browser.clearPreview()
            if let item = artifact, !item.isDirectory { await browser.inspect(item.url) }
        }
        .onChange(of: category) { selectedArtifact = nil }
    }
}
