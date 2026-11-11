import CoreServices
import Foundation

struct DocumentRecord: Identifiable, Sendable {
    let path: String
    var kind: String
    var modified: Date?
    var bytes: Int64?
    var created: Date?
    var lastUsed: Date?
    var authors: [String] = []
    var tags: [String] = []
    var title: String?
    var pages: Int?
    var contentType: String?
    var location = ""
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    func matches(_ query: String) -> Bool {
        query.isEmpty || ([path, kind, title ?? "", location] + authors + tags)
            .joined(separator: " ").localizedCaseInsensitiveContains(query)
    }

    static func location(_ path: String, home: String) -> String {
        if path.hasPrefix(home + "/Library/Mobile Documents/") { return "iCloud Drive" }
        let cloud = home + "/Library/CloudStorage/"
        if path.hasPrefix(cloud) { return String(path.dropFirst(cloud.count).split(separator: "/").first ?? "Cloud storage") }
        if path.hasPrefix("/Volumes/") { return String(path.dropFirst(9).split(separator: "/").first ?? "External volume") }
        for name in ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music"] {
            if path.hasPrefix(home + "/" + name + "/") { return name }
        }
        return path.hasPrefix(home + "/") ? "Home" : "Other locations"
    }
}

enum DocumentSort: String, CaseIterable, Identifiable {
    case modified = "Modified", created = "Created", lastUsed = "Last opened"
    case name = "Name", kind = "Kind", location = "Location", size = "Size"
    var id: String { rawValue }
    var startsAscending: Bool { self == .name || self == .kind || self == .location }
}

enum DocumentOrder {
    static func sorted(_ entries: [DocumentRecord], by sort: DocumentSort, ascending: Bool) -> [DocumentRecord] {
        entries.sorted { a, b in
            func optional<T: Comparable>(_ x: T?, _ y: T?) -> Bool {
                if x == y { return a.path < b.path }
                guard let x else { return false }
                guard let y else { return true }
                return ascending ? x < y : x > y
            }
            switch sort {
            case .modified: return optional(a.modified, b.modified)
            case .created: return optional(a.created, b.created)
            case .lastUsed: return optional(a.lastUsed, b.lastUsed)
            case .size: return optional(a.bytes, b.bytes)
            default:
                let x = sort == .name ? a.name : sort == .kind ? a.kind : a.location
                let y = sort == .name ? b.name : sort == .kind ? b.kind : b.location
                let order = x.localizedStandardCompare(y)
                if order == .orderedSame { return a.path < b.path }
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }
    }
}

struct DocumentsListing: Sendable {
    var entries: [DocumentRecord] = []
    var error: String?
    var warning: String?
}

struct DocumentsCollector: Sendable {
    typealias Run = @Sendable (String, [String], TimeInterval, Int) async -> CommandRunner.Result
    var run: Run = { await CommandRunner.run($0, $1, timeout: $2, outputLimit: $3) }
    var metadata: @Sendable (String) -> DocumentRecord? = Self.metadata
    static let candidateLimit = 2_000
    static let entryLimit = 500

    func collect(scope: String, days: Int) async -> DocumentsListing {
        let types = ["public.text", "com.adobe.pdf", "public.image", "public.audio", "public.movie",
                     "public.presentation", "public.spreadsheet", "public.archive", "com.apple.iwork.pages.pages",
                     "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc"]
        let predicate = "(" + types.map { "kMDItemContentTypeTree == '\($0)'" }.joined(separator: " || ")
            + ") && kMDItemFSContentChangeDate >= $time.today(-\(days))"
        let result = await run("/usr/bin/mdfind", ["-0", "-onlyin", scope, predicate], 8, 524_288)
        guard !result.cancelled, !Task.isCancelled else { return DocumentsListing() }
        guard result.status == 0, !result.timedOut else {
            return DocumentsListing(error: result.timedOut ? "Spotlight search timed out. Try a smaller folder."
                : "Spotlight unavailable. " + result.error)
        }
        // Only NUL-terminated paths are complete when the subprocess output was capped.
        let paths = result.output.split(separator: "\0", omittingEmptySubsequences: false).dropLast()
        var seen: Set<String> = []
        var entries: [DocumentRecord] = []
        var inspected = 0
        var limited = result.truncated
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        for raw in paths {
            guard !Task.isCancelled else { return DocumentsListing() }
            guard inspected < Self.candidateLimit, ProcessInfo.processInfo.systemUptime < deadline else { limited = true; break }
            let path = String(raw)
            guard seen.insert(path).inserted else { continue }
            inspected += 1
            if let entry = metadata(path) { entries.append(entry) }
        }
        limited = limited || entries.count > Self.entryLimit
        return DocumentsListing(entries: Array(DocumentOrder.sorted(entries, by: .modified, ascending: false).prefix(Self.entryLimit)),
            warning: limited ? "Discovery limited: showing up to 500 files from a bounded Spotlight sample. Narrow the folder or date range to find more recent files." : nil)
    }

    static func metadata(_ path: String) -> DocumentRecord? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        func value(_ key: CFString) -> Any? { MDItemCopyAttribute(item, key) }
        let tree = value(kMDItemContentTypeTree) as? [String] ?? []
        guard !tree.contains("public.folder"), !tree.contains("com.apple.application-bundle") else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Exclude app internals and build outputs; keep cloud documents inside Library.
        if path.hasPrefix(home + "/Library/"),
           !path.hasPrefix(home + "/Library/Mobile Documents/"),
           !path.hasPrefix(home + "/Library/CloudStorage/") { return nil }
        let components = path.split(separator: "/")
        if components.contains(where: { $0.hasPrefix(".") || ["node_modules", "vendor", "DerivedData"].contains(String($0)) }) { return nil }
        return DocumentRecord(path: path, kind: value(kMDItemKind) as? String ?? "File",
            modified: value(kMDItemFSContentChangeDate) as? Date,
            bytes: (value(kMDItemFSSize) as? NSNumber)?.int64Value,
            created: value(kMDItemFSCreationDate) as? Date, lastUsed: value(kMDItemLastUsedDate) as? Date,
            authors: value(kMDItemAuthors) as? [String] ?? [], tags: value("kMDItemUserTags" as CFString) as? [String] ?? [],
            title: value(kMDItemTitle) as? String, pages: (value(kMDItemNumberOfPages) as? NSNumber)?.intValue,
            contentType: value(kMDItemContentType) as? String, location: locationForPath(path, home: home))
    }

    private static func locationForPath(_ path: String, home: String) -> String {
        DocumentRecord.location(path, home: home)
    }
}

@MainActor
final class DocumentsModel: ObservableObject {
    @Published private(set) var listing = DocumentsListing()
    @Published private(set) var loading = false
    @Published private(set) var checkedAt: Date?
    let presentation = DocumentsPresentation()
    let collector: DocumentsCollector
    private var generation = 0
    private var cachedScope: String?
    private var cachedDays: Int?

    init(collector: DocumentsCollector = DocumentsCollector()) { self.collector = collector }

    func invalidate() { checkedAt = nil }

    func refresh(scope: String, days: Int, cacheInterval: TimeInterval = 0) async {
        guard !Task.isCancelled else { return }
        if cachedScope == scope, cachedDays == days, let checkedAt,
           Date().timeIntervalSince(checkedAt) < cacheInterval { return }
        generation += 1
        let current = generation
        loading = true
        listing = DocumentsListing()
        checkedAt = nil
        let collector = collector
        let worker = Task.detached(priority: .utility) { await collector.collect(scope: scope, days: days) }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard generation == current else { return }
        loading = false
        guard !Task.isCancelled else { return }
        listing = result
        if result.error == nil {
            cachedScope = scope
            cachedDays = days
            checkedAt = Date()
        }
    }
}
