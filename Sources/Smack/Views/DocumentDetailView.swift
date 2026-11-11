import AppKit
import QuickLookUI
import SwiftUI

struct DocumentQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

struct DocumentFileActions: View {
    let url: URL
    var preview: (() -> Void)?
    var contents: String? = nil
    @State private var error: String?
    @State private var applications: [URL] = []
    @State private var choosingApplication = false

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            Button("Open", systemImage: "arrow.up.forward.app") {
                if !NSWorkspace.shared.open(url) { error = "macOS could not open this file. It may have moved or be unavailable." }
            }.buttonStyle(.borderedProminent)
            if let preview {
                Button("Preview", systemImage: "eye", action: preview).buttonStyle(.bordered)
            }
            Button("Open With", systemImage: "app") {
                applications = Array(NSWorkspace.shared.urlsForApplications(toOpen: url).prefix(32))
                choosingApplication = true
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $choosingApplication) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Open With").font(.headline)
                    if applications.isEmpty { Text("No applications available").foregroundStyle(.secondary) }
                    ForEach(applications, id: \.self) { app in
                        Button(app.deletingPathExtension().lastPathComponent) {
                            choosingApplication = false
                            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { _, failure in
                                if let failure { Task { @MainActor in error = failure.localizedDescription } }
                            }
                        }.buttonStyle(.plain)
                    }
                }.padding(16)
            }
            Button("Reveal in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.bordered)
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
            Menu {
                if let contents, !contents.isEmpty { Button("Copy Contents") { copy(contents) } }
                Button("Copy Path") { copy(url.path) }
                Button("Copy File URL") { copy(url.absoluteString) }
            } label: { Label("Copy", systemImage: "doc.on.doc") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .controlSize(.small)
        .alert("Could not open document", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct DocumentDetailView: View {
    @ObservedObject var store: MonitorStore
    let path: String
    @StateObject private var model: DocumentDetailModel
    @ObservedObject private var visibility: PanelVisibility
    @State private var previewing = false
    @State private var revision = 0

    init(store: MonitorStore, path: String, model: DocumentDetailModel = DocumentDetailModel()) {
        self.store = store
        self.path = path
        _model = StateObject(wrappedValue: model)
        visibility = store.panelVisibility
    }

    private var url: URL { URL(fileURLWithPath: path) }
    private var record: DocumentRecord {
        model.inspection?.record ?? store.documentsModel.listing.entries.first { $0.path == path }
            ?? DocumentRecord(path: path, kind: "File")
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailPageHeader {
                ResourceTitle(title: "Document details", systemImage: DocumentFileType.systemImage(path: path, contentType: record.contentType),
                              color: AppRoute.documents.tint, subtitle: record.location)
            } actions: {
                if model.loading { ProgressView().controlSize(.small) }
                RefreshButton { revision += 1 }.disabled(model.loading)
            } overview: {}
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    identity
                    DocumentFileActions(url: url, preview: { previewing.toggle() })
                    if previewing && visibility.visible {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Quick Look").font(.headline)
                                Spacer()
                                Button("Close Preview", systemImage: "xmark") { previewing = false }
                            }
                            DocumentQuickLookView(url: url).frame(height: 400)
                        }
                    }
                    if let error = model.inspection?.error {
                        Label("File details unavailable: " + error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    chronology
                    contentDetails
                    if let info = model.inspection?.info { fileDetails(info) }
                    if let attributes = model.inspection?.attributes, !attributes.isEmpty {
                        section("More from Spotlight", fields: attributes.map { ($0.title, $0.value) })
                    }
                    if let project = store.projectsModel.snapshot?.projects
                        .filter({ path.hasPrefix($0.root + "/") }).max(by: { $0.root.count < $1.root.count }) {
                        GroupBox {
                            HStack {
                                Label("Part of " + project.name, systemImage: "arrow.triangle.branch").font(.headline)
                                Spacer()
                                Button("Open Project") { store.route = .project(project.root) }.buttonStyle(.bordered)
                            }.padding(4)
                        }
                    }
                    Text("Indexed metadata can lag behind the file on disk. Preview and Open may download cloud files through their provider.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(MonitorStyle.inset)
            }
        }
        .background(MonitorStyle.page)
        .task(id: "\(path):\(visibility.visible):\(revision)") {
            guard visibility.visible, !Capabilities.isSandboxed else { return }
            await model.load(path)
        }
        .onChange(of: path) { _, _ in previewing = false }
        .onChange(of: visibility.visible) { _, visible in if !visible { previewing = false } }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                ResourceIcon(systemImage: DocumentFileType.systemImage(path: path, contentType: record.contentType),
                             color: AppRoute.documents.tint, size: 52)
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.name).font(.title2.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(record.kind).font(.callout).foregroundStyle(.secondary)
                    Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                if let info = model.inspection?.info {
                    DetailBadge(text: info.type, systemImage: info.linkTarget == nil ? "checkmark.circle" : "link", color: .secondary)
                }
                DetailBadge(text: record.bytes.map { Formatting.bytes(UInt64(max(0, $0))) } ?? "Size unavailable", color: .secondary)
                if let pages = record.pages { DetailBadge(text: "\(pages) pages", color: .secondary) }
                if let modified = record.modified {
                    DetailBadge(text: "Modified " + Formatting.relative(modified), systemImage: "pencil", color: .secondary)
                }
                ForEach(record.tags, id: \.self) { DetailBadge(text: $0, systemImage: "tag", color: .secondary) }
            }
        }
    }

    private var chronology: some View {
        DetailFactGrid(facts: [
            DetailFact(title: "Created", value: record.created.map { Formatting.relative($0) } ?? "Unavailable",
                       systemImage: "calendar", help: date(record.created)),
            DetailFact(title: "Modified", value: record.modified.map { Formatting.relative($0) } ?? "Unavailable",
                       systemImage: "pencil", help: date(record.modified)),
            DetailFact(title: "Last opened", value: record.lastUsed.map { Formatting.relative($0) } ?? "Unavailable",
                       systemImage: "clock", help: date(record.lastUsed))
        ], minimumWidth: 160)
    }

    private var contentDetails: some View {
        section("Document", fields: [
            ("Title", record.title ?? "Unavailable"),
            ("Authors", record.authors.isEmpty ? "Unavailable" : record.authors.joined(separator: ", ")),
            ("Content type", record.contentType ?? "Unavailable"),
            ("Location", record.location.isEmpty ? "Unavailable" : record.location),
            ("Created", date(record.created)),
            ("Modified (indexed)", date(record.modified)),
            ("Last opened", date(record.lastUsed))
        ])
    }

    private func fileDetails(_ info: HomeFileInfo) -> some View {
        section("File on disk", fields: [
            ("Type", info.type), ("Size", Formatting.bytes(UInt64(max(0, info.bytes)))),
            ("Allocated", Formatting.bytes(UInt64(max(0, info.blocks)) * 512)),
            ("Owner", info.owner), ("Group", info.group),
            ("Permissions", info.mode + " (" + info.octal + ")"),
            ("Created", date(info.created)), ("Modified", date(info.modified)),
            ("Metadata changed", date(info.changed)), ("Accessed", date(info.accessed)),
            ("Links", String(info.links)), ("Inode", String(info.inode)),
            ("Device", info.device), ("Flags", info.flags)
        ] + (info.linkTarget.map { [("Link target", $0)] } ?? []))
    }

    private func section(_ title: String, fields: [(String, String)]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 9) {
                    ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                        GridRow(alignment: .top) {
                            Text(field.0).font(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                            Text(field.1).font(.callout).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func date(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .standard) ?? "Unavailable" }
}
