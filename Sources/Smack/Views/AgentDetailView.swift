import SwiftUI
import AppKit

struct AgentsSummaryTile: View {
    @ObservedObject var model: AgentMonitor
    var open: () -> Void

    var body: some View {
        if !Capabilities.isSandboxed {
            Button(action: open) {
                MetricCard(title: "Agents", systemImage: "sparkles") {
                    Text(model.snapshot.map { "\($0.agents.count) agents detected" } ?? (model.loading ? "Discovering…" : "Explore AI agents"))
                        .font(.title3.weight(.semibold))
                    Text(model.snapshot.map { $0.agents.isEmpty ? "No local agent installations found" : $0.agents.map(\.name).joined(separator: ", ") }
                         ?? "Configuration, logs, memory and skills")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task { if model.snapshot == nil { await model.refresh() } }
        }
    }
}

struct AgentDetailView: View {
    @ObservedObject var model: AgentMonitor
    @State private var selectedAgent: String?
    @State private var category: AgentCategory = .configuration
    @State private var selectedArtifact: String?
    @State private var query = ""
    @StateObject private var browser = UserHomeMonitor()
    @AppStorage(FileContentsScrollView<EmptyView>.wrapKey) private var wrap = false

    private var agents: [InstalledAgent] {
        (model.snapshot?.agents ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var current: InstalledAgent? { agents.first { $0.id == selectedAgent } ?? agents.first }
    private var artifacts: [AgentArtifact] { current?.artifacts.filter { $0.category == category } ?? [] }
    private var artifact: AgentArtifact? { artifacts.first { $0.id == selectedArtifact } ?? artifacts.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Agents", systemImage: "sparkles").font(.title2.weight(.semibold))
                    if let snapshot = model.snapshot {
                        Text("\(snapshot.agents.count) detected · Checked \(snapshot.timestamp.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await model.refresh() } }.disabled(model.loading)
            }.padding()
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
                                    .font(.callout).padding(8)
                                    .background(current?.id == agent.id ? Color.accentColor.opacity(0.15) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(10)
                    }
                }.padding(.top, 10).frame(width: 180)
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
                                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
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
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
