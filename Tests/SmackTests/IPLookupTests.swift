import Foundation
import Darwin
import Testing
@testable import Smack

@Test func ipLookupOffersOnlyGloballyRoutableAddresses() {
    #expect(IPLookup.publicAddress("8.8.8.8") == "8.8.8.8")
    #expect(IPLookup.publicAddress("[2606:4700:4700::1111]") == "2606:4700:4700::1111")
    #expect(IPLookup.publicAddress("::ffff:1.1.1.1") == "1.1.1.1")
    for host in ["127.0.0.1", "10.1.2.3", "172.20.0.1", "192.168.1.10", "100.64.0.1", "169.254.1.1",
                 "203.0.113.8", "224.0.0.251", "::1", "fe80::1%en0", "fd7a:115c:a1e0::1", "2001:db8::1", "::ffff:127.0.0.1", "*", "localhost"] {
        #expect(IPLookup.publicAddress(host) == nil, "\(host)")
    }
}

@Test func ipLookupBuildsServiceURLsAndSkipsIPv4OnlyServicesForIPv6() {
    let ipinfo = IPLookup.services.first { $0.id == "IPinfo" }
    #expect(ipinfo?.url(for: "8.8.8.8")?.absoluteString == "https://ipinfo.io/8.8.8.8")
    #expect(IPLookup.services(for: "8.8.8.8").count == IPLookup.services.count)
    #expect(!IPLookup.services(for: "2606:4700:4700::1111").contains { $0.id == "GreyNoise" })
}

@Test func fileLookupHashesFilesAndSkipsMissingOnes() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("smack-lookup-\(UUID().uuidString)")
    try Data("abc".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(FileLookup.sha256(ofFileAt: url.path) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(FileLookup.isRegularFile(url.path))
    #expect(!FileLookup.isRegularFile("/usr/lib/libSystem.B.dylib"))
    #expect(!FileLookup.isRegularFile(FileManager.default.temporaryDirectory.path))
    #expect(!FileLookup.isRegularFile("/dev/random"))
    #expect(FileLookup.sha256(ofFileAt: "/dev/random") == nil)
    #expect(FileLookup.virusTotalURL(sha256: "ab")?.absoluteString == "https://www.virustotal.com/gui/file/ab")
}

@Test func fileLookupSearchesTheInnermostBundleOrTheFileName() {
    #expect(FileLookup.searchTerm(for: "/Applications/Foo.app/Contents/Frameworks/Bar.framework/Versions/A/Bar") == "Bar.framework")
    #expect(FileLookup.searchTerm(for: "/Applications/Foo.app/Contents/MacOS/Foo") == "Foo.app")
    #expect(FileLookup.searchTerm(for: "/usr/lib/swift/libswiftCore.dylib") == "libswiftCore.dylib")
    #expect(FileLookup.searchTerm(for: "/Users/someone/Secret Project/notes.txt") == "notes.txt")
    #expect(FileLookup.googleURL(for: "/usr/lib/libz.1.dylib")?.absoluteString == "https://www.google.com/search?q=%22libz.1.dylib%22%20macOS")
}


@Test func hashingRejectsFIFOsAndDirectoriesWithoutBlocking() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fifo = directory.appendingPathComponent("fifo")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(FileLookup.sha256(ofFileAt: fifo.path) == nil)
    #expect(FileLookup.sha256(ofFileAt: directory.path) == nil)
    let file = directory.appendingPathComponent("empty")
    try Data().write(to: file)
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(FileLookup.sha256(ofFileAt: link.path) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}
