import Foundation
import Testing
@testable import Smack

@Test func applicationLogFilesExcludeEmptyStaleAndNonLogs() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let process = ProcessRef(id: "p1", pid: 1, name: "app")
    let paths = ["/tmp/app.log", "/tmp/empty.log", "/tmp/old.log", "/tmp/data.txt"].map {
        AggregatedPath(id: $0, path: $0, descriptorType: "VNODE", processes: [process])
    }
    let result = ApplicationLogFiles.discover(paths, now: now) { path in
        switch path {
        case "/tmp/empty.log": (0, now)
        case "/tmp/old.log": (10, now.addingTimeInterval(-8 * 86_400))
        default: (10, now)
        }
    }
    #expect(result.map(\.path) == ["/tmp/app.log"])
}

@Test func applicationLogReadReturnsOnlyTheLastBytes() throws {
    let files = MemoryLogFiles()
    let text = String(repeating: "a", count: 10) + String(repeating: "b", count: ApplicationLogFiles.byteLimit)
    files.set("/tmp/app.log", Data(text.utf8))
    files.set("/tmp/empty.log", Data())
    #expect(try ApplicationLogFiles.read("/tmp/app.log", files: files) == String(repeating: "b", count: ApplicationLogFiles.byteLimit))
    #expect(files.reads.map(\.offset) == [10])
    #expect(try ApplicationLogFiles.read("/tmp/empty.log", files: files) == "")
    #expect(throws: (any Error).self) { try ApplicationLogFiles.read("/tmp/missing.log", files: files) }
}
