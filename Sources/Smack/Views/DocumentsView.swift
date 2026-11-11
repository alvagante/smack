import AppKit
import SwiftUI

struct DocumentsView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject private var model: DocumentsModel
    @ObservedObject private var state: DocumentsPresentation
    @ObservedObject private var visibility: PanelVisibility
    @State private var revision = 0

    init(store: MonitorStore, model: DocumentsModel? = nil) {
        self.store = store
        let model = model ?? store.documentsModel
        self.model = model
        state = model.presentation
        visibility = store.panelVisibility
    }

    private var entries: [DocumentRecord] {
        DocumentOrder.sorted(model.listing.entries.filter {
            $0.matches(state.query) && (state.kind.isEmpty || $0.kind == state.kind) &&
            (state.location.isEmpty || $0.location == state.location)
        }, by: state.sort, ascending: state.ascending)
    }
    private var loadID: String { "\(state.scope):\(state.days):\(revision):\(visibility.visible):\(state.mode)" }
    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    var body: some View {
        VStack(spacing: 0) {
            DetailPageHeader {
                ResourceTitle(title: "Documents", systemImage: "doc.on.doc", color: AppRoute.documents.tint,
                    subtitle: state.mode == .browse ? "Browse folders and preview files"
                        : model.checkedAt.map { "Checked " + $0.formatted(date: .omitted, time: .shortened) }
                        ?? "Recently modified saved files")
                    .frame(minWidth: 240, alignment: .leading)
            } actions: {
                ToolbarIconButton(title: "Choose folder…", systemImage: "folder.badge.plus", color: .blue, action: chooseFolder)
                RefreshButton { model.invalidate(); revision += 1 }.disabled(model.loading && state.mode == .recent)
            } overview: {
                if state.mode == .recent {
                    ResourceStatsRow(headline: model.checkedAt == nil ? "Unavailable" : String(model.listing.entries.count),
                        unit: "files", stats: [
                            ResourceStat(title: "Locations", systemImage: "folder",
                                value: model.checkedAt == nil ? "Unavailable" : String(Set(model.listing.entries.map(\.location)).count)),
                            ResourceStat(title: "Kinds", systemImage: "doc",
                                value: model.checkedAt == nil ? "Unavailable" : String(Set(model.listing.entries.map(\.kind)).count)),
                            ResourceStat(title: "Known size", systemImage: "internaldrive", value: knownSize)
                        ], headlineWidth: 150)
                }
            }
            Divider()
            HStack {
                Picker("View", selection: $state.mode) {
                    ForEach(DocumentsMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MonitorStyle.inset).padding(.top, 12)
            if state.mode == .recent {
                filters.padding(MonitorStyle.inset)
                recentList
            } else {
                DocumentBrowserView(store: store, state: state, revision: revision)
            }
        }
        .background(MonitorStyle.page)
        .task(id: loadID) {
            guard visibility.visible, !Capabilities.isSandboxed, state.mode == .recent else { return }
            await model.refresh(scope: state.scope, days: state.days,
                cacheInterval: store.settingsStore.settings.devTools.inventoryCache.slowInventory)
        }
    }

    private var recentList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = model.listing.error {
                    ContentUnavailableView("Documents unavailable", systemImage: "magnifyingglass", description: Text(error))
                } else if model.loading {
                    ProgressView("Finding indexed files…").frame(maxWidth: .infinity).padding()
                } else if entries.isEmpty {
                    ContentUnavailableView("No matching files", systemImage: "doc.on.doc",
                        description: Text("Try another folder, date range or filter. Spotlight exclusions, indexing delays and permissions can hide files."))
                } else {
                    ViewThatFits(in: .horizontal) {
                        table.frame(minWidth: DocumentsTableView.minimumWidth)
                        ScrollView(.horizontal) { table.frame(width: DocumentsTableView.minimumWidth) }
                    }
                }
                if let warning = model.listing.warning {
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Text("Spotlight metadata. Modified is the indexed content-change date; Last opened is separate. Click a document for details. Browse shows folders directly, including files outside the recent sample.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(MonitorStyle.inset)
        }
    }

    private var table: some View {
        DocumentsTableView(entries: entries, sort: $state.sort, ascending: $state.ascending) { store.route = .document($0.path) }
    }

    private var knownSize: String {
        let sizes = model.listing.entries.compactMap(\.bytes)
        return sizes.isEmpty ? "Unavailable" : Formatting.bytes(UInt64(max(0, sizes.reduce(0, +))))
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Filter names, paths, authors or tags", text: $state.query).textFieldStyle(.roundedBorder)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                Menu {
                    Button("Home") { state.scope = home }
                    ForEach(["Documents", "Desktop", "Downloads", "Pictures"], id: \.self) { name in
                        Button(name) { state.scope = home + "/" + name }
                    }
                    Button("iCloud Drive") { state.scope = home + "/Library/Mobile Documents/com~apple~CloudDocs" }
                    Divider()
                    Button("Choose folder…", action: chooseFolder)
                } label: { Label(state.scope == home ? "Home" : URL(fileURLWithPath: state.scope).lastPathComponent, systemImage: "folder") }
                .help(state.scope)
                Picker("Modified within", selection: $state.days) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }.fixedSize()
                Picker("Kind", selection: $state.kind) {
                    Text("All kinds").tag("")
                    ForEach(Array(Set(model.listing.entries.map(\.kind))).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 220)
                Picker("Location", selection: $state.location) {
                    Text("All locations").tag("")
                    ForEach(Array(Set(model.listing.entries.map(\.location))).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 220)
            }.font(.caption)
            Text("\(entries.count) shown · " + state.scope).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .onChange(of: state.scope) { _, _ in state.kind = ""; state.location = ""; state.browserDirectory = nil }
        .onChange(of: state.days) { _, _ in state.kind = ""; state.location = "" }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = state.mode == .browse ? "Browse" : "Search Documents"
        if panel.runModal() == .OK, let url = panel.url {
            state.scope = url.path
            state.browserDirectory = url
        }
    }
}

struct DocumentsTableView: View {
    static let minimumWidth: CGFloat = 1120
    let entries: [DocumentRecord]
    @Binding var sort: DocumentSort
    @Binding var ascending: Bool
    var open: (DocumentRecord) -> Void

    private let columns: [DocumentSort] = [.name, .kind, .location, .modified, .created, .lastUsed, .size]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ForEach(columns) { column in
                    Button {
                        if sort == column { ascending.toggle() }
                        else { sort = column; ascending = column.startsAscending }
                    } label: {
                        HStack(spacing: 4) {
                            Text(column.rawValue)
                            if sort == column { Image(systemName: ascending ? "chevron.up" : "chevron.down") }
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(sort == column ? Color.primary : .secondary)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: column == .size ? .trailing : .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: width(column), alignment: .leading)
                    .accessibilityLabel("Sort by " + column.rawValue)
                    .accessibilityValue(sort == column ? (ascending ? "Ascending" : "Descending") : "Not selected")
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    Button { open(entry) } label: {
                        HStack(spacing: 12) {
                            Label(entry.name, systemImage: DocumentFileType.systemImage(path: entry.path, contentType: entry.contentType))
                                .font(.callout.weight(.medium)).frame(width: width(.name), alignment: .leading)
                            cell(entry.kind, column: .kind)
                            cell(entry.location, column: .location)
                            cell(date(entry.modified), column: .modified)
                            cell(date(entry.created), column: .created)
                            cell(date(entry.lastUsed), column: .lastUsed)
                            cell(entry.bytes.map { Formatting.bytes(UInt64(max(0, $0))) } ?? "Unavailable", column: .size)
                        }
                        .lineLimit(1).truncationMode(.middle).padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(entry.path).accessibilityHint("Open document details")
                    Divider().padding(.leading, 12)
                }
            }
        }.monitorSurface()
    }

    private func width(_ column: DocumentSort) -> CGFloat {
        switch column {
        case .name: 270
        case .kind: 140
        case .location: 140
        case .modified, .created, .lastUsed: 120
        case .size: 90
        }
    }
    private func cell(_ value: String, column: DocumentSort) -> some View {
        Text(value).font(.caption).foregroundStyle(.secondary)
            .frame(width: width(column), alignment: column == .size ? .trailing : .leading)
    }
    private func date(_ value: Date?) -> String {
        value?.formatted(date: .abbreviated, time: .omitted) ?? "Unavailable"
    }
}
