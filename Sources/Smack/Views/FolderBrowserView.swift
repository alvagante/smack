import AppKit
import SwiftUI

struct FolderBrowserView: View {
    let directory: URL
    let listing: HomeListing
    let loading: Bool
    @Binding var selected: String?
    @Binding var query: String
    var canGoUp: Bool
    var goUp: () -> Void
    var openFolder: (HomeEntry) -> Void
    var openFile: ((HomeEntry) -> Void)? = nil
    var previewFile: ((HomeEntry) -> Void)? = nil
    var showDetails: ((HomeEntry) -> Void)? = nil
    var showsHiddenFiles = true

    private var entries: [HomeEntry] {
        listing.entries.filter {
            (showsHiddenFiles || !$0.name.hasPrefix(".")) &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }
    private var current: HomeEntry? { entries.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    goUp()
                } label: { Image(systemName: "chevron.up") }
                .disabled(!canGoUp)
                .accessibilityLabel("Parent folder")
                Text(directory.path).font(.caption.monospaced())
                    .lineLimit(2).truncationMode(.head).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            TextField("Filter this folder", text: $query).textFieldStyle(.roundedBorder)
            HStack {
                Text("\(entries.count) entries").font(.caption).foregroundStyle(.secondary)
                Spacer()
                ToolbarIconButton(title: "Reveal in Finder", systemImage: "folder", color: .blue) { NSWorkspace.shared.activateFileViewerSelecting([current?.url ?? directory]) }
                    .controlSize(.small)
                    .help(current == nil ? "Reveal this folder in Finder" : "Reveal the selection in Finder")
            }
            Text("Click to inspect, double-click a folder to open it.")
                .font(.caption).foregroundStyle(.secondary)
            if let warning = listing.warning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            if let error = listing.error {
                ContentUnavailableView("Folder unavailable", systemImage: "folder.badge.questionmark",
                                       description: Text(error))
            } else if entries.isEmpty {
                ContentUnavailableView(loading ? "Reading folder" : "No matching entries",
                                       systemImage: "folder")
            } else {
                List(selection: $selected) {
                    ForEach(entries) { item in
                        HStack {
                            Image(systemName: DocumentFileType.systemImage(path: item.url.path, isDirectory: item.isDirectory))
                                .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                HStack {
                                    if item.isSymbolicLink { Text("Symbolic link") }
                                    if !item.isDirectory, let size = item.bytes {
                                        Text(Formatting.bytes(UInt64(max(0, size))))
                                    }
                                }.font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .tag(item.id)
                        .help(item.url.path)
                        .draggable(item.url)
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let item = entries.first(where: { ids.contains($0.id) }) {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.url.path, forType: .string)
                        }
                        if item.isDirectory { Button("Open folder") { openFolder(item) } }
                        else {
                            if let openFile { Button("Open") { openFile(item) } }
                            if let previewFile { Button("Preview") { selected = item.id; previewFile(item) } }
                            if let showDetails { Button("Document Details") { showDetails(item) } }
                        }
                    }
                } primaryAction: { ids in
                    if let item = entries.first(where: { ids.contains($0.id) }) {
                        if item.isDirectory { openFolder(item) }
                        else { openFile?(item) }
                    }
                }
                .onKeyPress(.space) {
                    guard let current, !current.isDirectory, let previewFile else { return .ignored }
                    previewFile(current)
                    return .handled
                }
            }
        }
        .padding(MonitorStyle.spacing)
    }
}
