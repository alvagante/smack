import Foundation
import Testing
import SwiftUI
@testable import Smack

@Test func savedSessionsFilterAndSortWithUnavailableTokensLast() {
    let a = PastTranscript(source: .file(path: "/a", format: .claude), directory: "/work/api",
                           title: "Fix login", started: Date(timeIntervalSince1970: 10),
                           updated: Date(timeIntervalSince1970: 30), inputTokens: 100, outputTokens: 20)
    let b = PastTranscript(source: .file(path: "/b", format: .codex), directory: "/work/web",
                           updated: Date(timeIntervalSince1970: 50))
    let c = PastTranscript(source: .file(path: "/c", format: .claude), directory: "/other/api",
                           updated: Date(timeIntervalSince1970: 40), inputTokens: 200, outputTokens: 40)
    #expect(SavedSessionList.items([a, b, c], query: "LOGIN", agents: [], sort: .activity, ascending: false).map(\.id) == [a.id])
    #expect(SavedSessionList.items([a, b, c], query: "api", agents: ["claude"], sort: .input, ascending: false).map(\.id) == [c.id, a.id])
    #expect(SavedSessionList.items([a, b, c], query: "", agents: [], sort: .input, ascending: true).map(\.id) == [a.id, c.id, b.id])
    #expect(a.duration == 20)
    #expect(b.duration == nil)
}

@Test @MainActor func savedSessionTotalsReuseExistingReadsAndInvalidateOnChange() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = home.appendingPathComponent(".claude/projects/test")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let file = folder.appendingPathComponent("session.jsonl")
    try Data().write(to: file)
    let date = Date(timeIntervalSince1970: 100)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    let model = TranscriptHistoryModel(catalog: TranscriptCatalog(home: home, agents: ["claude"]))
    await model.load(maxAge: 0)
    let id = try #require(model.result.items.first?.id)
    model.record(TranscriptIndex(tokens: [TranscriptTokens(date: date, input: 100, output: 25)]), for: id)
    #expect(model.result.items.first?.inputTokens == 100)
    await model.load(maxAge: 0, force: true)
    #expect(model.result.items.first?.outputTokens == 25)
    try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(10)], ofItemAtPath: file.path)
    await model.load(maxAge: 0, force: true)
    #expect(model.result.items.first?.inputTokens == nil)
}

@Test @MainActor func savedSessionNavigationAndSummaryRenderAtPanelWidths() throws {
    for width in [900.0, 1400.0] {
        let view = SessionTimelineView(session: nil, transcripts: false, interval: 5, visibility: PanelVisibility())
        let host = NSHostingView(rootView: view.frame(width: width, height: 650))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 650)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width >= width)
    }
}

@Test func savedSessionsColumnOrderAndAgentChips() {
    let a = PastTranscript(source: .file(path: "/a", format: .claude), directory: "/work/zebra",
                           title: "Zebra", updated: Date(timeIntervalSince1970: 30), inputTokens: 100, outputTokens: 20)
    let b = PastTranscript(source: .file(path: "/b", format: .codex), directory: "/other/apple",
                           title: "Apple", updated: Date(timeIntervalSince1970: 50))
    #expect(SavedSessionList.items([a, b], query: "", agents: ["claude", "codex"], sort: .title, ascending: true).map(\.id) == [b.id, a.id])
    #expect(SavedSessionList.items([a, b], query: "", agents: [], sort: .project, ascending: true).map(\.id) == [b.id, a.id])
    #expect(SavedSessionSort.title.startsAscending)
    #expect(!SavedSessionSort.activity.startsAscending)
    let summary = SavedSessionSummary(items: [a, b])
    #expect(summary.projects == 2)
    #expect(summary.agents == 2)
    #expect(summary.knownTokens == 120)
    #expect(summary.tokenSessions == 1)
    #expect(SavedSessionSummary(items: [b]).knownTokens == nil)
}

@Test @MainActor func savedSessionsPageRendersAtPanelWidths() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = directory.appendingPathComponent(".claude/projects/test")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for i in 0..<8 {
        let line = #"{"type":"user","cwd":"/work/smack","message":{"content":"Improve the Saved Sessions view"},"timestamp":"2026-11-09T10:00:00Z"}"#
        try Data((line + "\n").utf8).write(to: folder.appendingPathComponent("session-\(i).jsonl"))
    }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let suite = "SavedSessionsViewTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    settings.update { $0.devTools.readSessionTranscripts = true }
    let scheduler = CollectionScheduler(systemCollector: SystemCollector(), processCollector: ProcessCollector(),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(), history: repository,
        settings: settings.settings, onSystem: { _ in }, onProcesses: { _ in })
    let store = MonitorStore(settingsStore: settings, history: repository, scheduler: scheduler)
    let model = TranscriptHistoryModel(catalog: TranscriptCatalog(home: directory, agents: ["claude"]))
    await model.load(maxAge: 0)
    #expect(model.result.items.count == 8)
    if let id = model.result.items.first?.id {
        model.record(TranscriptIndex(tokens: [TranscriptTokens(date: .distantPast, input: 12500, output: 3200)]), for: id)
    }
    for width in [900.0, 1400.0] {
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: SavedSessionsView(history: model, store: store, maxAge: 600)
                .frame(width: width, height: 650).environment(\.colorScheme, scheme))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 650)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width <= width + 1)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                let name = scheme == .dark ? "dark" : "light"
                try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("smack-saved-\(name)-\(Int(width)).png"))
            }
        }
    }
}
