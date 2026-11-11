import Foundation
import Testing
@testable import Smack

@Test func summaryLayoutKeepsSavedOrderAndAppendsNewVisibleTiles() {
    let visible: [SummaryTileID] = [.memory, .cpu, .gpu, .network]
    let order = SummaryLayoutSettings.resolve(order: ["gpu", "cpu", "missing"], visible: visible)
    #expect(order == [.gpu, .cpu, .memory, .network])
}

@Test func summaryLayoutUsesFactoryOrderWhenNothingIsSaved() {
    let visible: [SummaryTileID] = [.disk, .cpu, .memory]
    #expect(SummaryLayoutSettings.resolve(order: [], visible: visible) == [.cpu, .memory, .disk])
}

@Test func summaryLayoutSpanFallsBackToDefaultUntilTheUserSetsOne() {
    var layout = SummaryLayoutSettings()
    #expect(layout.span(for: .cpu, default: 2) == 2)
    layout.setSpan(1, for: .cpu)
    #expect(layout.span(for: .cpu, default: 2) == 1)
    layout.setSpan(99, for: .cpu)
    #expect(layout.span(for: .cpu, default: 2) == 4)
}

@Test func summaryLayoutMoveReordersAndPersistsVisibleIds() {
    var layout = SummaryLayoutSettings()
    let visible: [SummaryTileID] = [.cpu, .memory, .gpu]
    layout.move(.gpu, before: .cpu, visible: visible)
    #expect(SummaryLayoutSettings.resolve(order: layout.order, visible: visible) == [.gpu, .cpu, .memory])
    layout.move(.cpu, before: nil, visible: visible)
    #expect(SummaryLayoutSettings.resolve(order: layout.order, visible: visible) == [.gpu, .memory, .cpu])
}

@Test func summaryLayoutResetClearsOrderAndSpans() {
    var layout = SummaryLayoutSettings(order: ["gpu"], spans: ["cpu": 1])
    layout.reset()
    #expect(layout.order.isEmpty && layout.spans.isEmpty)
}

@Test func summaryLayoutSettingsRoundTripAndDropUnknownTiles() throws {
    var settings = CollectionSettings()
    settings.panel.summaryLayout = SummaryLayoutSettings(order: ["cpu", "not-a-tile"], spans: ["memory": 2, "ghost": 3])
    settings.validate()
    #expect(settings.panel.summaryLayout.order == ["cpu"])
    #expect(settings.panel.summaryLayout.spans == ["memory": 2])
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.panel.summaryLayout == settings.panel.summaryLayout)
}

@Test func summaryLayoutDefaultsEmptyInLegacySettings() throws {
    let legacy = try JSONDecoder().decode(CollectionSettings.self, from: Data(#"{"panel":{"trigger":"Click"}}"#.utf8))
    #expect(legacy.panel.summaryLayout == SummaryLayoutSettings())
}

@Test func savedWindowFrameClampsOntoAVisibleScreen() {
    let screens = [CGRect(x: 0, y: 0, width: 1_440, height: 900)]
    let saved = SavedWindowFrame(CGRect(x: 8_000, y: 8_000, width: 900, height: 500))
    let frame = saved.clamped(to: screens, minimumSize: CGSize(width: 720, height: 340),
                              fallback: CGRect(x: 0, y: 0, width: 1_200, height: 430))
    #expect(frame.width == 900 && frame.height == 500)
    #expect(screens[0].contains(CGPoint(x: frame.midX, y: frame.midY))
        || screens[0].intersects(frame))
    #expect(frame.minX >= screens[0].minX && frame.maxX <= screens[0].maxX + 0.5)
}

@Test func savedWindowFramePersistsWithPanelSettings() throws {
    var settings = CollectionSettings()
    settings.panel.savedWindowFrame = SavedWindowFrame(CGRect(x: 10, y: 20, width: 800, height: 400))
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.panel.savedWindowFrame == settings.panel.savedWindowFrame)
    let legacy = try JSONDecoder().decode(CollectionSettings.self, from: Data("{}".utf8))
    #expect(legacy.panel.savedWindowFrame == nil)
}


@Test func summaryTileSizesMigrateLegacySpansAndRoundTrip() throws {
    var layout = SummaryLayoutSettings(spans: ["cpu": 8, "memory": 0, "gpu": 3])
    layout.validate()
    #expect(layout.size(for: .cpu, default: 1) == .large)
    #expect(layout.size(for: .memory, default: 2) == .square)
    #expect(layout.size(for: .gpu, default: 1) == .wide)
    layout.setSpan(SummaryTileSize.large.rawValue, for: .documents)
    let decoded = try JSONDecoder().decode(SummaryLayoutSettings.self, from: JSONEncoder().encode(layout))
    #expect(decoded.size(for: .documents, default: 1) == .large)
}

@Test func summaryDragReordersLiveAndKeepsTheTileUnderThePointer() {
    let ids: [SummaryTileID] = [.cpu, .memory, .gpu]
    let frames: [SummaryTileID: CGRect] = [.cpu: CGRect(x: 0, y: 0, width: 210, height: 210),
        .memory: CGRect(x: 222, y: 0, width: 210, height: 210),
        .gpu: CGRect(x: 444, y: 0, width: 210, height: 210)]
    var drag = SummaryTileDrag(id: .cpu, order: ids, origin: frames[.cpu]!, start: CGPoint(x: 40, y: 40))
    drag.update(location: CGPoint(x: 280, y: 40), frames: frames)
    #expect(drag.order == [.memory, .cpu, .gpu])
    let reordered: [SummaryTileID: CGRect] = [.memory: frames[.cpu]!, .cpu: frames[.memory]!, .gpu: frames[.gpu]!]
    #expect(drag.offset(in: reordered) == CGSize(width: 18, height: 0))
    // Reflow under a stationary pointer must not oscillate.
    drag.update(location: CGPoint(x: 280, y: 40), frames: reordered)
    #expect(drag.order == [.memory, .cpu, .gpu])
    drag.update(location: CGPoint(x: 500, y: 40), frames: reordered)
    #expect(drag.order == [.memory, .gpu, .cpu])
    drag.update(location: CGPoint(x: -100, y: -100), frames: reordered)
    #expect(drag.order == [.memory, .gpu, .cpu])
}

@Test func summaryLargeTilesShowLongerLists() {
    #expect(SummaryTileSize.large.rowLimit >= 12)
    #expect(SummaryTileSize.large.rowLimit > SummaryTileSize.wide.rowLimit)
}

@Test func summaryArrangementPreservesHiddenTilePositions() {
    var layout = SummaryLayoutSettings(order: ["cpu", "memory", "gpu"], spans: [:])
    layout.reorderVisible([.gpu, .cpu], visible: [.cpu, .gpu])
    #expect(layout.order == ["gpu", "memory", "cpu"])
}

@Test func savedWindowFrameFitsTheScreenItOccupies() {
    let small = CGRect(x: 0, y: 0, width: 1024, height: 768)
    let large = CGRect(x: 1024, y: 0, width: 2560, height: 1440)
    let saved = SavedWindowFrame(CGRect(x: 0, y: 0, width: 1600, height: 900))
    let frame = saved.clamped(to: [small, large], minimumSize: CGSize(width: 720, height: 340), fallback: small)
    #expect(small.contains(frame))
}
