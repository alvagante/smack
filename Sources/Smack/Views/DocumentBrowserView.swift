import AppKit
import SwiftUI

struct DocumentBrowserView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var state: DocumentsPresentation
    @StateObject private var inspector: UserHomeMonitor
    @StateObject private var model: DocumentBrowserModel
    @ObservedObject private var visibility: PanelVisibility
    var revision = 0
    @State private var selected: String?
    @State private var query = ""
    @State private var previewing: URL?
    @State private var openError: String?

    init(store: MonitorStore, state: DocumentsPresentation, revision: Int = 0, model: DocumentBrowserModel = DocumentBrowserModel(), selection: String? = nil, inspector: UserHomeMonitor = UserHomeMonitor()) {
        self.store = store
        self.state = state
        self.revision = revision
        _model = StateObject(wrappedValue: model)
        _inspector = StateObject(wrappedValue: inspector)
        visibility = store.panelVisibility
        _selected = State(initialValue: selection)
    }

    private var directory: URL { state.browserDirectory ?? URL(fileURLWithPath: state.scope) }
    private var entries: [HomeEntry] {
        model.listing.entries.filter { !$0.name.hasPrefix(".") && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }
    private var current: HomeEntry? { entries.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Menu {
                    Button("Home") { navigate(FileManager.default.homeDirectoryForCurrentUser) }
                    ForEach(["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music"], id: \.self) { name in
                        Button(name) { navigate(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)) }
                    }
                    Button("iCloud Drive") { navigate(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")) }
                } label: { Label("Locations", systemImage: "sidebar.left") }
                Spacer(minLength: 0)
            }.padding(MonitorStyle.spacing)
            if let error = model.listing.error {
                ContentUnavailableView("Folder unavailable", systemImage: "folder.badge.questionmark", description: Text(error))
            } else {
                ViewThatFits(in: .horizontal) {
                    HSplitView {
                        fileList.frame(minWidth: 230, idealWidth: 280, maxWidth: 320)
                        preview.frame(minWidth: 310, maxWidth: .infinity)
                    }.frame(minWidth: 570)
                    VSplitView {
                        fileList.frame(minHeight: 180)
                        preview.frame(minHeight: 240)
                    }
                }
            }
        }
        .background(MonitorStyle.page)
        .task(id: "\(directory.path):\(revision):\(visibility.visible)") {
            guard visibility.visible, !Capabilities.isSandboxed else { return }
            selected = nil
            previewing = nil
            await model.load(directory)
        }
        .task(id: "\(selected ?? ""):\(visibility.visible):\(revision)") {
            guard visibility.visible, !Capabilities.isSandboxed else { return }
            guard let current else { inspector.clearPreview(); return }
            await inspector.inspect(current.url)
        }
        .onChange(of: selected) { _, selection in
            if previewing?.path != selection { previewing = nil }
        }
        .onChange(of: query) { _, _ in if current == nil { selected = nil; previewing = nil } }
        .onChange(of: visibility.visible) { _, visible in
            if !visible { previewing = nil; inspector.clearPreview() }
        }
        .alert("Could not open file", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button("OK") { openError = nil }
        } message: { Text(openError ?? "") }
    }

    private var fileList: some View {
        FolderBrowserView(directory: directory, listing: model.listing, loading: model.loading,
            selected: $selected, query: $query, canGoUp: directory.path != "/",
            goUp: { navigate(directory.deletingLastPathComponent()) },
            openFolder: { navigate($0.url) }, openFile: primary,
            previewFile: { previewing = previewing == $0.url ? nil : $0.url },
            showDetails: { store.route = .document($0.url.path) }, showsHiddenFiles: false)
    }

    private var preview: some View {
        FileInspectionView(item: current, preview: inspector.preview, inspecting: inspector.inspecting,
            quickLookURL: visibility.visible ? previewing : nil) {
            if let current {
                DocumentFileActions(url: current.url,
                    preview: current.isDirectory ? nil : { previewing = previewing == current.url ? nil : current.url },
                    contents: inspector.preview?.text)
                if previewing != nil {
                    Button("Close Preview", systemImage: "xmark") { previewing = nil }.buttonStyle(.bordered)
                }
                Button("Document Details", systemImage: "info.circle") { store.route = .document(current.url.path) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func primary(_ entry: HomeEntry) {
        if entry.isDirectory { navigate(entry.url) }
        else if !NSWorkspace.shared.open(entry.url) { openError = "macOS could not open this file. It may have moved or be unavailable." }
    }

    private func navigate(_ url: URL) {
        selected = nil
        query = ""
        previewing = nil
        state.browserDirectory = url
    }
}
