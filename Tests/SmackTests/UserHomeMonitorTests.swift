import Foundation
import Darwin
import AppKit
import SwiftUI
import Testing
@testable import Smack

struct UserHomeMonitorTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("smack-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func listsHiddenEntriesAndHomeFilesWithoutRecursing() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(".config/tool"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try Data("export EDITOR=vim".utf8).write(to: root.appendingPathComponent(".zshrc"))
        try Data("settings".utf8).write(to: root.appendingPathComponent(".config/tool/settings.toml"))
        try Data("brew".utf8).write(to: root.appendingPathComponent("Brewfile"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent(".linked").path,
                                  withDestinationPath: root.appendingPathComponent(".config").path)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent(".broken").path,
                                  withDestinationPath: root.appendingPathComponent("missing").path)
        let collector = UserHomeCollector(home: root, environment: [:])
        let listing = collector.list(category: .dotfiles, directory: root)
        #expect(listing.error == nil)
        #expect(Set(listing.entries.map(\.name)) == [".config", ".linked", ".broken", ".zshrc", "Brewfile"])
        #expect(listing.entries.first?.isDirectory == true)
        #expect(listing.entries.first { $0.name == ".linked" }?.isDirectory == true)
        let nested = collector.list(category: .config, directory: root.appendingPathComponent(".config/tool"))
        #expect(nested.entries.map(\.name) == ["settings.toml"])
        #expect(collector.preview(root.appendingPathComponent(".zshrc")).text == "export EDITOR=vim")
        #expect(collector.list(category: .preferences, directory: root.appendingPathComponent("missing")).error != nil)
    }

    @Test func resolvesCategoriesAndAbsoluteXDGOverride() {
        let home = URL(fileURLWithPath: "/fixture")
        #expect(HomeCategory.config.directory(home: home, environment: [:]).path == "/fixture/.config")
        #expect(HomeCategory.config.directory(home: home, environment: ["XDG_CONFIG_HOME": "/custom"]).path == "/custom")
        #expect(HomeCategory.config.directory(home: home, environment: ["XDG_CONFIG_HOME": "relative"]).path == "/fixture/.config")
        #expect(HomeCategory.preferences.directory(home: home, environment: [:]).path == "/fixture/Library/Preferences")
        #expect(HomeCategory.applicationSupport.directory(home: home, environment: [:]).path == "/fixture/Library/Application Support")
        #expect(HomeCategory.launchAgents.directory(home: home, environment: [:]).path == "/fixture/Library/LaunchAgents")
    }

    @Test func previewsPlistsUnicodeLinksAndRejectsUnsafeOrOversizedFiles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = UserHomeCollector(home: root, environment: [:])
        let plist = root.appendingPathComponent("test.plist")
        try PropertyListSerialization.data(fromPropertyList: ["enabled": true], format: .binary, options: 0).write(to: plist)
        #expect(collector.preview(plist).text.contains("<key>enabled</key>"))
        try Data("<broken plist".utf8).write(to: plist)
        #expect(collector.preview(plist).text == "<broken plist")
        try PropertyListSerialization.data(fromPropertyList: ["enabled": true], format: .binary, options: 0).write(to: plist)
        let utf16 = root.appendingPathComponent("unicode")
        try #require("caffè".data(using: .utf16)).write(to: utf16)
        #expect(collector.preview(utf16).text == "caffè")
        let link = root.appendingPathComponent("linked.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: plist)
        #expect(collector.preview(link).text.contains("<true/>"))
        let large = root.appendingPathComponent("large")
        try Data(repeating: 65, count: UserHomeCollector.previewLimit + 1).write(to: large)
        #expect(collector.preview(large).message?.contains("1 MiB") == true)
        let binary = root.appendingPathComponent("binary")
        try Data([0, 1, 2, 255]).write(to: binary)
        #expect(collector.preview(binary).text.isEmpty)
        #expect(collector.preview(binary).message?.contains("Binary") == true)
        let fifo = root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(collector.preview(fifo).message == "Only regular files can be previewed.")
        #expect(collector.preview(root).message == "Only regular files can be previewed.")
        #expect(collector.preview(root.appendingPathComponent("missing")).message != nil)
    }

    @Test func detailsCombineStatWithContentsOrLongListing() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "notes.txt")
        let collector = UserHomeCollector(home: root, environment: [:])

        let details = collector.details(file)
        #expect(details.text == "hello")
        let info = try #require(details.info)
        #expect(info.path == file.path)
        #expect(info.type == "Regular file")
        #expect(info.mode == "-rw-r-----")
        #expect(info.octal == "0640")
        #expect(info.bytes == 5)
        #expect(info.links == 1)

        let link = try HomeStat.info(root.appendingPathComponent("link"))
        #expect(link.type == "Symbolic link")
        #expect(link.linkTarget == "notes.txt")

        let listing = collector.details(root)
        #expect(listing.info?.type == "Directory")
        let lines = listing.text.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("total ") == true)
        #expect(lines.count == 5)
        #expect(lines[1].hasPrefix("d") && lines[1].hasSuffix(" ."))
        #expect(lines[2].hasSuffix(" .."))
        #expect(lines.contains { $0.hasPrefix("l") && $0.hasSuffix(" link -> notes.txt") })
        #expect(lines.contains { $0.hasPrefix("-rw-r-----") && $0.hasSuffix(" notes.txt") })
        #expect(HomeStat.longListing(root, limit: 2).message == "Showing the first 2 of 4 entries.")
        #expect(HomeStat.modeString(S_IFDIR | 0o1777) == "drwxrwxrwt")
        #expect(HomeStat.modeString(S_IFREG | 0o4754) == "-rwsr-xr--")
        #expect(HomeStat.modeString(S_IFREG | 0o2640) == "-rw-r-S---")
    }

    @Test @MainActor func modelAndPageRenderWithFixtureData() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".gitconfig")
        try Data("[user]\nname = Fixture".utf8).write(to: file)
        let model = UserHomeMonitor(collector: UserHomeCollector(home: root, environment: [:]))
        await model.load(category: .dotfiles, directory: root)
        #expect(model.listing.entries.count == 1)
        #expect(!model.loading)
        await model.inspect(file)
        #expect(model.preview?.text.contains("Fixture") == true)
        #expect(!model.inspecting)
        for width in [900.0, 1400.0] {
            let host = NSHostingView(rootView: UserHomeDetailView(model: model)
                .environment(\.colorScheme, .light).background(Color.white))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 650)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            #expect(model.listing.entries.count == 1)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= Int(width))
            window.contentView = nil
            if width == 1400, let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "/tmp/smack-user-home-page.png"))
            }
        }
        await model.load(category: .config, directory: root.appendingPathComponent("missing"))
        #expect(model.preview == nil)
        #expect(model.listing.error != nil)
    }
}
