import CoreServices
import Foundation
import UniformTypeIdentifiers

enum DocumentFileType {
    static func systemImage(path: String, contentType: String? = nil, isDirectory: Bool = false) -> String {
        if isDirectory { return "folder" }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ["doc", "docx", "pages", "odt", "rtf"].contains(ext) { return "doc.richtext" }
        if ["xls", "xlsx", "numbers", "ods", "csv", "tsv"].contains(ext) { return "tablecells" }
        if ["ppt", "pptx", "key", "odp"].contains(ext) { return "rectangle.on.rectangle" }
        let type = contentType.flatMap(UTType.init) ?? UTType(filenameExtension: ext)
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .movie) == true { return "play.rectangle" }
        if type?.conforms(to: .audio) == true { return "music.note" }
        if type?.conforms(to: .sourceCode) == true { return "curlybraces" }
        if type?.conforms(to: .archive) == true { return "archivebox" }
        if type?.conforms(to: .presentation) == true { return "rectangle.on.rectangle" }
        if type?.conforms(to: .spreadsheet) == true { return "tablecells" }
        return "doc.text"
    }
}

enum DocumentsMode: String, CaseIterable, Identifiable {
    case recent = "Recent", browse = "Browse"
    var id: String { rawValue }
}

@MainActor final class DocumentsPresentation: ObservableObject {
    @Published var mode: DocumentsMode = .recent
    @Published var query = ""
    @Published var kind = ""
    @Published var location = ""
    @Published var days = 30
    @Published var scope = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var sort: DocumentSort = .modified
    @Published var ascending = false
    @Published var browserDirectory: URL?
}

struct DocumentAttribute: Identifiable, Sendable {
    var id: String { title }
    let title: String
    let value: String
    let systemImage: String
}

struct DocumentInspection: Sendable {
    var record: DocumentRecord
    var info: HomeFileInfo?
    var attributes: [DocumentAttribute] = []
    var error: String?
}

struct DocumentInspector: Sendable {
    func read(_ path: String) -> DocumentInspection {
        var result = DocumentInspection(record: DocumentsCollector.metadata(path)
            ?? DocumentRecord(path: path, kind: "File"))
        do { result.info = try HomeStat.info(URL(fileURLWithPath: path)) }
        catch { result.error = error.localizedDescription }
        guard !Task.isCancelled else { return result }
        if let item = MDItemCreate(kCFAllocatorDefault, path as CFString) {
            let fields: [(String, String, String)] = [
                ("kMDItemDescription", "Description", "text.alignleft"),
                ("kMDItemComment", "Comment", "text.bubble"),
                ("kMDItemSubject", "Subject", "doc.text"),
                ("kMDItemKeywords", "Keywords", "tag"),
                ("kMDItemLanguages", "Languages", "globe"),
                ("kMDItemOrganizations", "Organizations", "building.2"),
                ("kMDItemCreator", "Created with", "app"),
                ("kMDItemVersion", "Version", "number"),
                ("kMDItemPixelWidth", "Pixel width", "arrow.left.and.right"),
                ("kMDItemPixelHeight", "Pixel height", "arrow.up.and.down"),
                ("kMDItemDurationSeconds", "Duration (seconds)", "play"),
                ("kMDItemCodecs", "Codecs", "film"),
                ("kMDItemAudioBitRate", "Audio bit rate", "waveform"),
                ("kMDItemWhereFroms", "Downloaded from", "arrow.down.circle")
            ]
            result.attributes = fields.compactMap { key, title, icon in
                guard let value = MDItemCopyAttribute(item, key as CFString) else { return nil }
                let text: String
                if let strings = value as? [String] { text = strings.prefix(16).joined(separator: ", ") }
                else if let string = value as? String { text = string }
                else if let number = value as? NSNumber { text = number.stringValue }
                else { return nil }
                guard !text.isEmpty else { return nil }
                return DocumentAttribute(title: title, value: String(text.prefix(2_048)), systemImage: icon)
            }
        }
        return result
    }
}

@MainActor final class DocumentDetailModel: ObservableObject {
    @Published private(set) var inspection: DocumentInspection?
    @Published private(set) var loading = false
    let read: @Sendable (String) -> DocumentInspection
    private var generation = 0

    init(read: @escaping @Sendable (String) -> DocumentInspection = { DocumentInspector().read($0) }) { self.read = read }

    func load(_ path: String) async {
        guard !Task.isCancelled else { return }
        generation += 1
        let current = generation
        loading = true
        inspection = nil
        let read = read
        let task = Task.detached(priority: .utility) { read(path) }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard generation == current else { return }
        loading = false
        guard !Task.isCancelled else { return }
        inspection = result
    }
}

@MainActor final class DocumentBrowserModel: ObservableObject {
    @Published private(set) var listing = HomeListing()
    @Published private(set) var loading = false
    let read: @Sendable (URL) -> HomeListing
    private var generation = 0

    init(read: @escaping @Sendable (URL) -> HomeListing = { UserHomeCollector().list(category: .library, directory: $0) }) {
        self.read = read
    }

    func load(_ directory: URL) async {
        guard !Task.isCancelled else { return }
        generation += 1
        let current = generation
        loading = true
        listing = HomeListing()
        let read = read
        let task = Task.detached(priority: .utility) { read(directory) }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard generation == current else { return }
        loading = false
        guard !Task.isCancelled else { return }
        listing = result
    }
}
