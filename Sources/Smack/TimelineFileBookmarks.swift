import Foundation

/// Read-only security-scoped bookmarks for log files the user added to the Timeline, stored as a JSON array
/// of base64 strings. Malformed storage reads as empty.
struct TimelineFileBookmarks: Equatable {
    private var encoded: [String]

    init(stored text: String) {
        encoded = (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
    }

    var stored: String {
        guard let data = try? JSONEncoder().encode(encoded) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    var data: [Data] { encoded.compactMap { Data(base64Encoded: $0) } }

    /// Adds a bookmark for each URL until `TimelineFileSources.fileLimit`. `added` lists the paths now retained;
    /// `error` is the message for the user, if any.
    mutating func add(_ urls: [URL], makeBookmark: (URL) -> Data? = Self.securityScopedBookmark) -> (added: [String], error: String?) {
        var added: [String] = []
        var error: String?
        for url in urls where encoded.count < TimelineFileSources.fileLimit {
            guard let bookmark = makeBookmark(url) else {
                error = "Could not retain access to one or more selected files."
                continue
            }
            let value = bookmark.base64EncodedString()
            if !encoded.contains(value) { encoded.append(value) }
            added.append(url.path)
        }
        if encoded.count >= TimelineFileSources.fileLimit { error = "The \(TimelineFileSources.fileLimit)-file limit has been reached." }
        return (added, error)
    }

    static func securityScopedBookmark(_ url: URL) -> Data? {
        let active = url.startAccessingSecurityScopedResource()
        defer { if active { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                     includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
