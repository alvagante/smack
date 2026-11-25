import Foundation
import Testing
@testable import Smack

@Test func timelineFileBookmarksRoundTripAndIgnoreMalformedStorage() {
    #expect(TimelineFileBookmarks(stored: "").data.isEmpty)
    #expect(TimelineFileBookmarks(stored: "not json").data.isEmpty)
    var bookmarks = TimelineFileBookmarks(stored: "")
    _ = bookmarks.add([URL(fileURLWithPath: "/logs/a.log")]) { _ in Data([1, 2]) }
    let restored = TimelineFileBookmarks(stored: bookmarks.stored)
    #expect(restored == bookmarks)
    #expect(restored.data == [Data([1, 2])])
}

@Test func timelineFileBookmarksAddDeduplicatesAndReportsFailures() {
    var bookmarks = TimelineFileBookmarks(stored: "")
    let urls = ["/logs/a.log", "/logs/b.log", "/logs/c.log"].map { URL(fileURLWithPath: $0) }
    let result = bookmarks.add(urls) { url in
        url.lastPathComponent == "b.log" ? nil : Data(url.lastPathComponent == "c.log" ? "a.log".utf8 : url.lastPathComponent.utf8)
    }
    // c.log resolves to the same bookmark as a.log: stored once, but both paths are retained for checking.
    #expect(bookmarks.data.count == 1)
    #expect(result.added == ["/logs/a.log", "/logs/c.log"])
    #expect(result.error == "Could not retain access to one or more selected files.")
}

@Test func timelineFileBookmarksStopAtTheFileLimit() {
    var bookmarks = TimelineFileBookmarks(stored: "")
    let urls = (0..<(TimelineFileSources.fileLimit + 5)).map { URL(fileURLWithPath: "/logs/\($0).log") }
    let result = bookmarks.add(urls) { Data($0.path.utf8) }
    #expect(bookmarks.data.count == TimelineFileSources.fileLimit)
    #expect(result.added.count == TimelineFileSources.fileLimit)
    #expect(result.error == "The 200-file limit has been reached.")
}
