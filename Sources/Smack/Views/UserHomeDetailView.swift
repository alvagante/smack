import SwiftUI
import AppKit

struct UserHomeSummaryTile: View {
    var open: () -> Void

    var body: some View {
        if !Capabilities.isSandboxed {
            SummaryTile(route: .userHome, headline: "Browse", caption: "Settings, dotfiles and configurations", open: open)
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

    private var directory: URL { folders.last ?? rootDirectory ?? model.directory(for: category) }
    private var entries: [HomeEntry] {
        model.listing.entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var current: HomeEntry? { entries.first { $0.id == selected } }

    private var overview: some View {
        ResourceStatsRow(headline: model.loading ? "…" : model.listing.error != nil ? "–" : String(model.listing.entries.count), unit: "entries", stats: [
            ResourceStat(title: "Folders", systemImage: "folder", value: model.loading ? "Loading…" : model.listing.error != nil ? "Unavailable" : String(model.listing.entries.filter(\.isDirectory).count)),
            ResourceStat(title: "Symbolic links", systemImage: "link", value: model.loading ? "Loading…" : model.listing.error != nil ? "Unavailable" : String(model.listing.entries.filter(\.isSymbolicLink).count))
        ], headlineWidth: 120)
    }

    var body: some View {
        VStack(spacing: 0) {
            if rootDirectory == nil {
                DetailPageHeader {
                    ResourceTitle(title: rootDirectory?.lastPathComponent ?? "User home", systemImage: rootDirectory == nil ? "house" : "folder", color: AppRoute.userHome.tint,
                                  subtitle: (rootDirectory ?? model.collector.home).path)
                } actions: {
                    if model.loading { ProgressView().controlSize(.small) }
                    RefreshButton { selected = nil; refreshID += 1 }
                } overview: {
                    overview
                }
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rootDirectory?.lastPathComponent ?? "Folder").font(.headline)
                        Text(model.loading ? "Reading folder…" : model.listing.error != nil ? "Folder unavailable" :
                            "\(model.listing.entries.count) entries · \(model.listing.entries.filter(\.isDirectory).count) folders · \(model.listing.entries.filter(\.isSymbolicLink).count) symbolic links")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    RefreshButton { selected = nil; refreshID += 1 }
                }.padding(MonitorStyle.spacing)
            }
            Divider()
            HStack(spacing: 0) {
                if rootDirectory == nil {
                    ScrollView {
                        VStack(alignment: .leading, spacing: SidebarStyle.rowSpacing) {
                            ForEach(HomeCategory.allCases) { item in
                                Button {
                                    selected = nil
                                    folders = []
                                    query = ""
                                    category = item
                                } label: {
                                    Text(item.rawValue)
                                }.buttonStyle(DetailNavigationStyle(selected: category == item))
                            }
                        }.padding(SidebarStyle.padding)
                    }.frame(width: 184, alignment: .top)
                    Divider()
                }
                FolderBrowserView(directory: directory, listing: model.listing, loading: model.loading,
                    selected: $selected, query: $query, canGoUp: !folders.isEmpty,
                    goUp: { selected = nil; query = ""; folders.removeLast() }, openFolder: openFolder)
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 320, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                FileInspectionView(item: current, preview: model.preview, inspecting: model.inspecting) {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.preview?.text ?? "", forType: .string)
                    }
                    .disabled(model.preview?.text.isEmpty ?? true)
                    .help(current?.isDirectory == true ? "Copy the folder listing" : "Copy the file contents")
                }.frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            }
        }
        .background(MonitorStyle.page)
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
}

/// `stat(1)` fields laid out as a two-pair label grid.
struct HomeFileInfoView: View {
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
            ("Accessed", Formatting.dated(info.accessed.formatted(date: .abbreviated, time: .standard), info.accessed)),
            ("Modified", Formatting.dated(info.modified.formatted(date: .abbreviated, time: .standard), info.modified)),
            ("Changed", Formatting.dated(info.changed.formatted(date: .abbreviated, time: .standard), info.changed)),
            ("Birth", Formatting.dated(info.created.formatted(date: .abbreviated, time: .standard), info.created))
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
