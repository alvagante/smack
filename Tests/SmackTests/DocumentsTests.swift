import AppKit
import QuickLookUI
import SwiftUI
import Foundation
import Testing
@testable import Smack

struct DocumentsTests {
    @Test func sortsUnknownMetadataLastInBothDirections() {
        let a = DocumentRecord(path: "/docs/a.pdf", kind: "PDF", modified: Date(timeIntervalSince1970: 10), bytes: 100, created: Date(timeIntervalSince1970: 10), lastUsed: Date(timeIntervalSince1970: 10))
        let b = DocumentRecord(path: "/docs/b.pdf", kind: "PDF", modified: Date(timeIntervalSince1970: 20), bytes: 200, created: Date(timeIntervalSince1970: 20), lastUsed: Date(timeIntervalSince1970: 20))
        let missing = DocumentRecord(path: "/docs/c.pdf", kind: "PDF")
        for sort in [DocumentSort.modified, .size, .lastUsed, .created] {
            for ascending in [true, false] {
                let sorted = DocumentOrder.sorted([missing, b, a], by: sort, ascending: ascending)
                #expect(sorted.last?.path == missing.path)
            }
        }
        #expect(DocumentOrder.sorted([a, b], by: .modified, ascending: false).first?.path == b.path)
    }

    @Test func searchMatchesTagsAuthorsAndPaths() {
        let file = DocumentRecord(path: "/docs/report.pdf", kind: "PDF", authors: ["Alice"], tags: ["Review"])
        #expect(file.matches("alice"))
        #expect(file.matches("REVIEW"))
        #expect(file.matches("/docs"))
        #expect(!file.matches("Bob"))
    }

    @Test func locationsDistinguishCloudProvidersAndRespectPathBoundaries() {
        #expect(DocumentRecord.location("/Users/test/Library/Mobile Documents/com~apple~CloudDocs/a.pdf", home: "/Users/test") == "iCloud Drive")
        #expect(DocumentRecord.location("/Users/test/Library/CloudStorage/OneDrive-Work/a.pdf", home: "/Users/test") == "OneDrive-Work")
        #expect(DocumentRecord.location("/Volumes/Drive/a.pdf", home: "/Users/test") == "Drive")
        #expect(DocumentRecord.location("/Users/test/Documents2/a.pdf", home: "/Users/test") == "Home")
    }

    @Test func collectorRejectsPartialPathsDeduplicatesAndSortsBeforeCapping() async {
        let collector = DocumentsCollector(run: { _, _, _, _ in
            .init(status: 0, output: "/docs/old.pdf\0/docs/new.pdf\0/docs/new.pdf\0/docs/partial", error: "", truncated: true)
        }, metadata: { path in
            DocumentRecord(path: path, kind: "PDF", modified: Date(timeIntervalSince1970: path.contains("new") ? 20 : 10))
        })
        let result = await collector.collect(scope: "/docs", days: 30)
        #expect(result.entries.map(\.path) == ["/docs/new.pdf", "/docs/old.pdf"])
        #expect(result.warning != nil)
    }

    @Test func collectorFailureIsUnavailableRatherThanAnEmptySuccess() async {
        let collector = DocumentsCollector(run: { _, _, _, _ in .unavailable("denied") }, metadata: { _ in nil })
        let result = await collector.collect(scope: "/docs", days: 30)
        #expect(result.error != nil)
    }

    @Test @MainActor func documentsBelongsToWorkAndIsHiddenInSandbox() {
        let routes = MonitorNavigation.sections(settings: CollectionSettings(), hasBattery: true).flatMap(\.routes)
        #expect(routes.contains(.documents) == !Capabilities.isSandboxed)
        #expect(AppRoute.documents.category == .work)
    }
}

extension DocumentsTests {
    @Test @MainActor func rendersBothViewsAndDocumentDetailAtPanelWidths() async throws {
        let directory = try obsTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "DocumentsRender-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
        let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let scheduler = CollectionScheduler(systemCollector: SystemCollector(), processCollector: ProcessCollector(),
            inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(), history: history,
            settings: settings.settings, onSystem: { _ in }, onProcesses: { _ in })
        let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)
        let path = "/Users/example/Documents/Quarterly planning and infrastructure costs.pdf"
        let model = DocumentsModel(collector: DocumentsCollector(run: { _, _, _, _ in
            .init(status: 0, output: path + "\0/Users/example/Downloads/notes.md\0", error: "")
        }, metadata: { path in
            DocumentRecord(path: path, kind: "PDF document", modified: Date(timeIntervalSince1970: 1_794_000_000),
                bytes: 123_456, authors: ["Example author"], tags: ["Planning", "Review"],
                title: "Infrastructure planning", pages: 42, contentType: "com.adobe.pdf", location: "Documents")
        }))
        await model.refresh(scope: "/Users/example", days: 30)
        let detail = DocumentDetailModel(read: { _ in
            DocumentInspection(record: DocumentRecord(path: path, kind: "PDF document",
                modified: Date(timeIntervalSince1970: 1_794_000_000), bytes: 123_456,
                created: Date(timeIntervalSince1970: 1_793_000_000), lastUsed: Date(timeIntervalSince1970: 1_794_100_000),
                authors: ["Example author"], tags: ["Planning", "Review"], title: "Infrastructure planning",
                pages: 42, contentType: "com.adobe.pdf", location: "Documents"),
                info: HomeFileInfo(path: path, type: "Regular file", mode: "-rw-r--r--", octal: "0644",
                    owner: "example (501)", group: "staff (20)", links: 1, bytes: 123_456, blocks: 248,
                    blockSize: 4096, inode: 42, device: "1,1", flags: "-", accessed: .distantPast,
                    modified: Date(timeIntervalSince1970: 1_794_000_000), changed: .distantPast,
                    created: Date(timeIntervalSince1970: 1_793_000_000), linkTarget: nil),
                attributes: [DocumentAttribute(title: "Created with", value: "Pages", systemImage: "app")])
        })
        await detail.load(path)
        let selectedFile = directory.appendingPathComponent("notes.md")
        try Data("# Infrastructure planning\n\nSelected file contents appear below filesystem details.\n".utf8).write(to: selectedFile)
        let inspector = UserHomeMonitor()
        await inspector.inspect(selectedFile)
        #expect(inspector.preview?.text.contains("Infrastructure planning") == true)
        #expect(inspector.preview?.info?.type == "Regular file")
        let browser = DocumentBrowserModel(read: { root in
            HomeListing(entries: [
                HomeEntry(url: root.appendingPathComponent("Planning"), isDirectory: true, isSymbolicLink: false, bytes: nil, modified: nil),
                HomeEntry(url: selectedFile, isDirectory: false, isSymbolicLink: false, bytes: 88, modified: nil),
                HomeEntry(url: root.appendingPathComponent("photo.png"), isDirectory: false, isSymbolicLink: false, bytes: 90_000, modified: nil)
            ])
        })
        await browser.load(URL(fileURLWithPath: "/docs"))
        let presentation = DocumentsPresentation()
        presentation.browserDirectory = URL(fileURLWithPath: "/docs")
        for dark in [false, true] {
            for width in [480.0, 620.0, 1100.0] {
                let views: [(String, AnyView)] = [
                    ("recent", AnyView(DocumentsView(store: store, model: model))),
                    ("detail", AnyView(DocumentDetailView(store: store, path: path, model: detail))),
                    ("browse", AnyView(DocumentBrowserView(store: store, state: presentation, model: browser, selection: selectedFile.path, inspector: inspector)))
                ]
                for (name, page) in views {
                    let view = page.frame(width: width, height: 900).environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    #expect(host.fittingSize.width <= width + 1)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: "/tmp/smack-documents-\(name)-\(dark ? "dark" : "light")-\(Int(width)).png"))
                    window.close()
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SMACK_DOCUMENT_BENCHMARK"] == "1"))
    func liveSpotlightDiscoveryBenchmark() async {
        let start = ContinuousClock.now
        let listing = await DocumentsCollector().collect(scope: FileManager.default.homeDirectoryForCurrentUser.path, days: 30)
        print("Documents discovery: \(start.duration(to: .now)); \(listing.entries.count) files; limited=\(listing.warning != nil); error=\(listing.error ?? "none")")
        #expect(listing.error == nil)
        #expect(listing.entries.count <= DocumentsCollector.entryLimit)
    }
}

extension DocumentsTests {
    @Test @MainActor func cancelledPageDoesNotStartDiscovery() async {
        let model = DocumentsModel(collector: DocumentsCollector(run: { _, _, _, _ in
            Issue.record("Cancelled work must not launch Spotlight")
            return .init(status: 0, output: "", error: "")
        }, metadata: { _ in nil }))
        let task = Task { await model.refresh(scope: "/docs", days: 30) }
        task.cancel()
        await task.value
        #expect(model.checkedAt == nil)
        #expect(!model.loading)
    }
}

extension DocumentsTests {
    @Test func documentIconsUseContentTypesAndExtensions() {
        #expect(DocumentFileType.systemImage(path: "/d/a.pdf") == "doc.richtext")
        #expect(DocumentFileType.systemImage(path: "/d/a.xlsx") == "tablecells")
        #expect(DocumentFileType.systemImage(path: "/d/a.key") == "rectangle.on.rectangle")
        #expect(DocumentFileType.systemImage(path: "/d/a.png") == "photo")
        #expect(DocumentFileType.systemImage(path: "/d/a.swift") == "curlybraces")
        #expect(DocumentFileType.systemImage(path: "/d/a.mp3") == "music.note")
        #expect(DocumentFileType.systemImage(path: "/d/no-extension", contentType: "public.jpeg") == "photo")
        #expect(DocumentFileType.systemImage(path: "/d/a", isDirectory: true) == "folder")
    }

    @Test @MainActor func documentDetailsRetainDocumentsNavigation() {
        #expect(AppRoute.document("/docs/report.pdf").sidebarRoute == .documents)
        #expect(AppRoute.document("/docs/report.pdf").category == .work)
        #expect(AppRoute.document("/docs/report.pdf").title == "Document details")
    }

    @Test @MainActor func browserAndInspectionUseInjectedReadersOnlyOnRequest() async {
        let browser = DocumentBrowserModel(read: { url in
            #expect(url.path == "/docs")
            return HomeListing(entries: [HomeEntry(url: url.appendingPathComponent("report.pdf"),
                isDirectory: false, isSymbolicLink: false, bytes: 42, modified: nil)])
        })
        #expect(browser.listing.entries.isEmpty)
        await browser.load(URL(fileURLWithPath: "/docs"))
        #expect(browser.listing.entries.first?.name == "report.pdf")
        let inspection = DocumentDetailModel(read: { path in
            #expect(path == "/docs/report.pdf")
            return DocumentInspection(record: DocumentRecord(path: path, kind: "PDF"), attributes: [
                DocumentAttribute(title: "Dimensions", value: "1200 × 800", systemImage: "aspectratio")
            ])
        })
        #expect(inspection.inspection == nil)
        await inspection.load("/docs/report.pdf")
        #expect(inspection.inspection?.attributes.first?.value == "1200 × 800")
    }
}

extension DocumentsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SMACK_DOCUMENT_PREVIEW"] == "1"))
    @MainActor func nativeQuickLookUsesSelectedFileWithoutAutoplay() async throws {
        let directory = try obsTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preview.rtf")
        let text = NSAttributedString(string: "Smack document preview fixture")
        let data = try #require(text.rtf(from: NSRange(location: 0, length: text.length)))
        try data.write(to: url)
        let host = NSHostingView(rootView: DocumentQuickLookView(url: url).frame(width: 480, height: 400))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> QLPreviewView? {
            if let preview = view as? QLPreviewView { return preview }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let preview = try #require(find(host))
        #expect(preview.previewItem?.previewItemURL == url)
        #expect(!preview.autostarts)
        #expect(!preview.shouldCloseWithWindow)
        window.contentView = nil
        window.close()
    }
}

extension DocumentsTests {
    @Test func documentsSummaryParticipatesInSavedLayout() {
        #expect(SummaryTileID.factorySpans[.documents] == 2)
        #expect(SummaryTileID.factoryOrder.filter { $0 == .documents }.count == 1)
        #expect(SummaryLayoutSettings.resolve(order: ["projects"], visible: [.documents, .projects]) == [.projects, .documents])
        var layout = SummaryLayoutSettings()
        layout.setSpan(1, for: .documents)
        layout.move(.documents, before: .projects, visible: [.projects, .documents])
        #expect(layout.order == ["documents", "projects"])
        #expect(layout.span(for: .documents, default: 2) == 1)
    }

    @Test @MainActor func documentSummaryRendersWithoutStartingDiscovery() async throws {
        let model = DocumentsModel(collector: DocumentsCollector(run: { _, _, _, _ in
            Issue.record("Summary must reuse the document inventory")
            return .unavailable("Unexpected collection")
        }, metadata: { _ in nil }))
        for width in [300.0, 620.0] {
            let host = NSHostingView(rootView:
                DocumentsSummaryTile(model: model, open: {}, openDocument: { _ in })
                    .frame(width: width).padding().background(MonitorStyle.page))
            host.frame = CGRect(x: 0, y: 0, width: width + 32, height: 240)
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            #expect(model.checkedAt == nil)
            #expect(!model.loading)
            #expect(host.fittingSize.width <= width + 32)
        }
    }
}

extension DocumentsTests {
    @Test @MainActor func documentSummaryRendersLoadedFilesAtBothSpans() async throws {
        let model = DocumentsModel(collector: DocumentsCollector(run: { _, _, _, _ in
            .init(status: 0, output: (1...7).map { "/docs/Report \($0).pdf\0" }.joined(), error: "")
        }, metadata: {
            DocumentRecord(path: $0, kind: "PDF", modified: Date(timeIntervalSince1970: 1_794_000_000),
                           bytes: 123_456, contentType: "com.adobe.pdf", location: "Documents")
        }))
        await model.refresh(scope: "/docs", days: 30)
        for dark in [false, true] {
            for width in [300.0, 620.0] {
                let host = NSHostingView(rootView:
                    DocumentsSummaryTile(model: model, open: {}, openDocument: { _ in })
                        .padding().background(MonitorStyle.page).environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 330),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                #expect(host.fittingSize.width <= width + 1)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: "/tmp/smack-documents-summary-\(dark ? "dark" : "light")-\(Int(width)).png"))
                window.close()
            }
        }
    }
}

extension DocumentsTests {
    @Test @MainActor func sharedFolderBrowserFitsNarrowAndWideColumns() throws {
        let listing = HomeListing(entries: [
            HomeEntry(url: URL(fileURLWithPath: "/docs/Planning"), isDirectory: true,
                      isSymbolicLink: false, bytes: nil, modified: nil),
            HomeEntry(url: URL(fileURLWithPath: "/docs/report.pdf"), isDirectory: false,
                      isSymbolicLink: true, bytes: 42, modified: nil)
        ], warning: "Showing a bounded sample")
        for width in [230.0, 320.0, 480.0] {
            let host = NSHostingView(rootView: FolderBrowserView(
                directory: URL(fileURLWithPath: "/docs"), listing: listing, loading: false,
                selected: .constant("/docs/report.pdf"), query: .constant(""), canGoUp: true,
                goUp: {}, openFolder: { _ in }).frame(width: width, height: 600))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width <= width + 1)
        }
    }
}


extension DocumentsTests {
    @Test @MainActor func sharedFileInspectionShowsContentsAtPanelWidths() throws {
        let file = HomeEntry(url: URL(fileURLWithPath: "/docs/notes.md"), isDirectory: false,
                             isSymbolicLink: false, bytes: 42, modified: nil)
        for width in [280.0, 480.0, 780.0] {
            let host = NSHostingView(rootView: FileInspectionView(item: file,
                preview: HomePreview(text: "# Infrastructure notes\nSelected file contents"), inspecting: false) {
                    Button("Document Details", systemImage: "info.circle") {}
                }.frame(width: width, height: 600))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width <= width + 1)
        }
    }
}


extension DocumentsTests {
    @Test @MainActor func cancelledBrowserInspectionDoesNotReadFile() async {
        let inspector = UserHomeMonitor()
        let task = Task { await inspector.inspect(URL(fileURLWithPath: "/not-read/notes.md")) }
        task.cancel()
        await task.value
        #expect(inspector.preview == nil)
        #expect(!inspector.inspecting)
    }
}
