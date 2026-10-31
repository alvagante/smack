import SwiftUI
import AppKit

struct UserHomeSummaryTile: View {
    var open: () -> Void

    var body: some View {
        if !Capabilities.isSandboxed {
            Button(action: open) {
                MetricCard(title: "User home", systemImage: "house") {
                    Text("Settings and dotfiles").font(.title3.weight(.semibold))
                    Text("Browse configurations and contents")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct UserHomeDetailView: View {
    @ObservedObject var model: UserHomeMonitor
    var rootDirectory: URL? = nil
    @State private var category: HomeCategory = .dotfiles
    @State private var folders: [URL] = []
    @State private var selected: String?
    @State private var query = ""
    @State private var refreshID = 0
    @AppStorage(FileContentsScrollView<EmptyView>.wrapKey) private var wrap = false

    private var directory: URL { folders.last ?? rootDirectory ?? model.directory(for: category) }
    private var entries: [HomeEntry] {
        model.listing.entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var current: HomeEntry? { entries.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label(rootDirectory?.lastPathComponent ?? "User home", systemImage: rootDirectory == nil ? "house" : "folder").font(.title2.weight(.semibold))
                    Text((rootDirectory ?? model.collector.home).path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button("Refresh") { selected = nil; refreshID += 1 }
            }.padding()
            Divider()
            HStack(spacing: 0) {
                if rootDirectory == nil {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(HomeCategory.allCases) { item in
                                Button {
                                    selected = nil
                                    folders = []
                                    query = ""
                                    category = item
                                } label: {
                                    Text(item.rawValue).font(.callout)
                                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(category == item ? Color.accentColor.opacity(0.15) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(10)
                    }.frame(width: 190, alignment: .top)
                    Divider()
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button {
                            selected = nil
                            query = ""
                            folders.removeLast()
                        } label: { Image(systemName: "chevron.up") }
                        .disabled(folders.isEmpty)
                        .accessibilityLabel("Parent folder")
                        Text(directory.path).font(.caption.monospaced())
                            .lineLimit(2).truncationMode(.head).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    TextField("Filter this folder", text: $query).textFieldStyle(.roundedBorder)
                    HStack {
                        Text("\(entries.count) entries").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([current?.url ?? directory]) }
                            .controlSize(.small)
                            .help(current == nil ? "Reveal this folder in Finder" : "Reveal the selection in Finder")
                    }
                    Text("Click to inspect, double-click a folder to open it.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let warning = model.listing.warning {
                        Text(warning).font(.caption).foregroundStyle(.orange)
                    }
                    if let error = model.listing.error {
                        ContentUnavailableView("Folder unavailable", systemImage: "folder.badge.questionmark",
                                               description: Text(error))
                    } else if entries.isEmpty {
                        ContentUnavailableView(model.loading ? "Reading folder" : "No matching entries",
                                               systemImage: "folder")
                    } else {
                        List(selection: $selected) {
                            ForEach(entries) { item in
                                HStack {
                                    Image(systemName: item.isDirectory ? "folder" : "doc.text")
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
                            }
                        }
                        .listStyle(.inset)
                        .contextMenu(forSelectionType: String.self) { ids in
                            if let item = entries.first(where: { ids.contains($0.id) }) {
                                Button("Reveal in Finder") { reveal(item) }
                                if item.isDirectory { Button("Open folder") { openFolder(item) } }
                            }
                        } primaryAction: { ids in
                            if let item = entries.first(where: { ids.contains($0.id) }), item.isDirectory { openFolder(item) }
                        }
                    }
                }.padding().frame(minWidth: 220, idealWidth: 280, maxWidth: 320, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                FileContentsScrollView(wrap: wrap) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let item = current {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.url.path).font(.headline.monospaced()).textSelection(.enabled)
                                Spacer(minLength: 20)
                                WrapToggle(wrap: $wrap)
                                Button("Copy", systemImage: "doc.on.doc") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(model.preview?.text ?? "", forType: .string)
                                }
                                .disabled(model.preview?.text.isEmpty ?? true)
                                .help(item.isDirectory ? "Copy the folder listing" : "Copy the file contents")
                            }
                            if let info = model.preview?.info { HomeFileInfoView(info: info) }
                            Divider()
                            if model.inspecting {
                                ProgressView(item.isDirectory ? "Listing folder…" : "Reading contents…")
                            } else if let preview = model.preview {
                                if let message = preview.message {
                                    Text(message).font(.callout).foregroundStyle(.secondary)
                                }
                                Text(preview.text).font(.caption.monospaced()).textSelection(.enabled)
                                    .fixedSize(horizontal: !wrap, vertical: false)
                            }
                        } else {
                            Text("Select a file or folder to show its details.").foregroundStyle(.secondary)
                        }
                    }.padding()
                }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .task(id: "\(category.id):\(directory.path):\(refreshID)") {
            guard !Capabilities.isSandboxed else { return }
            selected = nil
            await model.load(category: category, directory: directory)
        }
        .task(id: selected) {
            if let item = current { await model.inspect(item.url) }
            else { model.clearPreview() }
        }
    }

    private func openFolder(_ item: HomeEntry) {
        selected = nil
        query = ""
        folders.append(item.url)
    }

    private func reveal(_ item: HomeEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}

/// `stat(1)` fields laid out as a two-pair label grid.
private struct HomeFileInfoView: View {
    let info: HomeFileInfo

    private var fields: [(String, String)] {
        var rows: [(String, String)] = [
            ("Type", info.type),
            ("Size", "\(info.bytes) bytes (\(Formatting.bytes(UInt64(max(0, info.bytes)))))"),
            ("Mode", "\(info.mode)  \(info.octal)"),
            ("Blocks", "\(info.blocks) (IO block \(info.blockSize))"),
            ("Owner", info.owner),
            ("Group", info.group),
            ("Links", String(info.links)),
            ("Inode", String(info.inode)),
            ("Device", info.device),
            ("Flags", info.flags),
            ("Accessed", info.accessed.formatted(date: .abbreviated, time: .standard)),
            ("Modified", info.modified.formatted(date: .abbreviated, time: .standard)),
            ("Changed", info.changed.formatted(date: .abbreviated, time: .standard)),
            ("Birth", info.created.formatted(date: .abbreviated, time: .standard))
        ]
        if let target = info.linkTarget { rows.insert(("Link target", target), at: 1) }
        return rows
    }

    var body: some View {
        let fields = fields
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(Array(stride(from: 0, to: fields.count, by: 2)), id: \.self) { index in
                GridRow {
                    cell(fields[index])
                    if index + 1 < fields.count { cell(fields[index + 1]) }
                }
            }
        }
        .font(.caption)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func cell(_ field: (String, String)) -> some View {
        Text(field.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
        Text(field.1).font(.caption.monospaced()).textSelection(.enabled).padding(.trailing, 16)
    }
}

/// Scrolls file contents pinned to the top-leading corner; wrapping drops horizontal scrolling.
struct FileContentsScrollView<Content: View>: View {
    static var wrapKey: String { "wrapFileContents" }
    var wrap: Bool
    @ViewBuilder var content: Content

    var body: some View {
        // A scroll view centers content narrower than its viewport, so stretch it to the viewport instead.
        GeometryReader { proxy in
            ScrollView(wrap ? .vertical : [.horizontal, .vertical]) {
                content.frame(minWidth: proxy.size.width, maxWidth: wrap ? proxy.size.width : nil,
                              minHeight: proxy.size.height, alignment: .topLeading)
            }
        }
    }
}

struct WrapToggle: View {
    @Binding var wrap: Bool

    var body: some View {
        Toggle(isOn: $wrap) { Label("Wrap", systemImage: "text.word.spacing") }
            .toggleStyle(.button)
            .help(wrap ? "Show long lines unwrapped with horizontal scrolling" : "Wrap long lines to the column width")
    }
}
