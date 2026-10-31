import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Smack

struct DevEnvironmentMonitorTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("smack-dev-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func executable(_ root: URL, _ path: String) throws -> String {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func detectsManagersAndKeepsVirtualenvsWithTheSameInterpreterSeparate() throws {
        let root = try fixture()
        let python = try executable(root, ".pyenv/versions/3.13/bin/python3")
        try FileManager.default.createSymbolicLink(atPath: root.path + "/.pyenv/versions/3.13/bin/python3.13", withDestinationPath: python)
        for name in ["first", "second"] {
            let directory = root.appendingPathComponent(".virtualenvs/" + name)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try Data("home = /python\n".utf8).write(to: directory.appendingPathComponent("pyvenv.cfg"))
            try FileManager.default.createSymbolicLink(atPath: directory.path + "/bin/python3", withDestinationPath: python)
        }
        let ruby = try executable(root, ".rbenv/versions/3.4/bin/ruby")
        let elixir = try executable(root, ".asdf/installs/elixir/1.18/bin/elixir")
        let rust = try executable(root, ".rustup/toolchains/stable/bin/rustc")
        let snapshot = DevEnvironmentCollector.discover(home: root.path, environment: ["PATH": root.path + "/.pyenv/versions/3.13/bin"], includeSystem: false)
        #expect(snapshot.environments.filter { $0.language == .python }.count == 3)
        #expect(snapshot.environments.contains { $0.executable == ruby && $0.source == "rbenv" })
        #expect(snapshot.environments.contains { $0.executable == elixir && $0.source == "asdf" })
        #expect(snapshot.environments.contains { $0.executable == rust && $0.source == "rustup" })
        #expect(snapshot.environments.filter(\.onPath).count == 1)
        #expect(Set(snapshot.environments.map(\.id)).count == snapshot.environments.count)
    }

    @Test func customProjectScanSkipsShimsDependenciesAndDeepTrees() throws {
        let root = try fixture()
        let found = try executable(root, "project/.venv/bin/python3")
        _ = try executable(root, "project/node_modules/package/bin/node")
        _ = try executable(root, "project/a/b/c/d/e/bin/ruby")
        _ = try executable(root, ".asdf/shims/elixir")
        let snapshot = DevEnvironmentCollector.discover(home: root.path, environment: ["PATH": root.path + "/.asdf/shims"],
                                                        folders: [root.path + "/project"], includeSystem: false)
        #expect(snapshot.environments.map(\.executable) == [found])
    }

    @Test func selectedRuntimeIsUsedForPythonAndNodePackages() async {
        for language in [DevLanguage.python, .node] {
            let item = DevEnvironment(language: language, executable: "/custom/bin/" + language.executables[0],
                                      resolvedPath: "/custom/runtime", source: "Test", onPath: false)
            let collector = DevEnvironmentCollector(run: { executable, arguments in
                #expect(executable == "/usr/bin/env")
                #expect(arguments.contains("PATH=/custom/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"))
                #expect(arguments.contains(item.executable))
                #expect(!arguments.contains("sh"))
                if arguments.contains("-c") {
                    #expect(arguments.contains("-I"))
                    #expect(arguments.last?.contains("metadata.distributions()") == true)
                    return .init(status: 0, output: "example==1.2 /custom/site-packages", error: "")
                }
                if arguments.contains("/custom/bin/npm") {
                    #expect(arguments.contains("--global"))
                    return .init(status: 0, output: "{\"dependencies\":{}}", error: "")
                }
                return .init(status: 0, output: "Runtime 1.2", error: "")
            })
            let inspection = await collector.inspect(item)
            #expect(inspection.version == "Runtime 1.2")
            #expect(inspection.reports.allSatisfy { !$0.failed })
            #expect(inspection.reports.count >= 2)
        }
    }

    @Test func timeoutTruncationAndMissingCompanionAreVisible() async {
        let item = DevEnvironment(language: .rust, executable: "/toolchain/bin/rustc", resolvedPath: "/toolchain/bin/rustc",
                                  source: "rustup", onPath: false)
        let collector = DevEnvironmentCollector(run: { _, arguments in
            if arguments.contains("/toolchain/bin/cargo") { return .unavailable("cargo missing") }
            return .init(status: 0, output: "partial", error: "", timedOut: true, truncated: true)
        })
        let inspection = await collector.inspect(item)
        #expect(inspection.version == "Unavailable")
        #expect(inspection.reports.allSatisfy { $0.failed })
        #expect(inspection.reports.first?.output.contains("Timed out") == true)
        #expect(inspection.reports.first?.output.contains("1 MB") == true)
        #expect(inspection.reports.last?.output.contains("cargo missing") == true)
    }

    @Test @MainActor func refreshInvalidatesDetailsAndFolderIsNotAddedTwice() async {
        let item = DevEnvironment(language: .ruby, executable: "/ruby", resolvedPath: "/ruby", source: "Test", onPath: false)
        let model = DevEnvironmentMonitor(collector: .init(run: { _, _ in .init(status: 0, output: "3.4", error: "") }),
                                          discover: { folders in DevDiscovery(environments: [item], roots: folders) })
        await model.refresh()
        await model.inspect(item)
        #expect(model.inspections[item.id] != nil)
        await model.addFolder("/project")
        await model.addFolder("/project")
        #expect(model.folders == ["/project"])
        #expect(model.inspections.isEmpty)
        #expect(model.snapshot?.roots == ["/project"])
        #expect(!model.loading)
    }

    @Test func systemPythonAndRubyProbesReturnRealPackageAndPathData() async throws {
        for (language, executable, marker) in [(DevLanguage.python, "/usr/bin/python3", "Base prefix:"),
                                                (.ruby, "/usr/bin/ruby", "Gem paths:")] {
            guard FileManager.default.isExecutableFile(atPath: executable) else { continue }
            let item = DevEnvironment(language: language, executable: executable, resolvedPath: executable,
                                      source: "System", onPath: true)
            let inspection = await DevEnvironmentCollector().inspect(item)
            #expect(inspection.version != "Unavailable")
            #expect(inspection.reports.last?.failed == false)
            #expect(inspection.reports.last?.output.contains(marker) == true)
        }
    }

    @Test func installedCommonLanguageProbesReturnUsableDetails() async {
        let snapshot = await Task.detached { DevEnvironmentCollector.discover() }.value
        for language in [DevLanguage.erlang, .elixir, .go, .node, .c] {
            guard let item = snapshot.environments.first(where: { $0.language == language }) else { continue }
            let inspection = await DevEnvironmentCollector().inspect(item)
            #expect(inspection.version != "Unavailable", "\(language.rawValue) version")
            #expect(inspection.reports.allSatisfy { !$0.failed }, "\(language.rawValue) details: \(inspection.reports.filter { $0.failed }.map(\.output))")
        }
    }

    @Test @MainActor func pageRendersAndLiveDiscoveryFindsSystemRuntimes() async throws {
        let snapshot = await Task.detached { DevEnvironmentCollector.discover() }.value
        #expect(!snapshot.environments.isEmpty)
        let model = DevEnvironmentMonitor(collector: .init(run: { _, _ in .init(status: 0, output: "Test runtime\npackage==1.0 /test/lib", error: "") }),
                                          discover: { _ in snapshot })
        await model.refresh()
        if let item = snapshot.environments.first { await model.inspect(item) }
        let host = NSHostingView(rootView: DevEnvironmentDetailView(model: model)
            .environment(\.colorScheme, .light).background(Color.white))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/smack-dev-environments.png"))
    }
}
