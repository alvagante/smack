import Foundation
import Testing
@testable import Smack

@MainActor @Test func networkPortsViewModelAppliesAndMatchesPortFilters() {
    let model = NetworkPortsViewModel()
    model.query = "stale"
    model.apply(ViewFilters(port: 443), now: Date())
    #expect(model.query.isEmpty)
    #expect(model.port == 443)
    #expect(model.mode == .listening)
    #expect(model.shows(ViewFilters(port: 443)))
    #expect(!model.shows(ViewFilters(port: 80)))
    model.query = "nginx"
    #expect(!model.shows(ViewFilters(port: 443)))
}

@MainActor @Test func applicationListViewModelAppliesAndMatchesSearch() {
    let model = ApplicationListViewModel()
    model.apply(ViewFilters(search: "Safari"), now: Date())
    #expect(model.query == "Safari")
    #expect(model.shows(ViewFilters(search: "Safari")))
    #expect(!model.shows(ViewFilters(search: "Mail")))
}

@MainActor @Test func timelineViewModelAppliesAndMatchesWindowKindsAndSearch() {
    let model = TimelineViewModel()
    let now = Date(timeIntervalSince1970: 10_000)
    let filters = ViewFilters(search: "nginx", timelineInterval: 600, timelineKinds: [.listenerOpened])
    model.apply(filters, now: now)
    #expect(model.window(now: now) == DateInterval(start: now.addingTimeInterval(-600), end: now))
    #expect(model.query == "nginx")
    #expect(model.selectedKinds == [.listenerOpened])
    #expect(model.shows(filters))
    #expect(model.shows(ViewFilters(search: "nginx", timelineKinds: [.listenerOpened])))
    #expect(!model.shows(ViewFilters(search: "nginx", timelineInterval: 3_600, timelineKinds: [.listenerOpened])))
    #expect(!model.shows(ViewFilters(search: "other", timelineKinds: [.listenerOpened])))

    model.apply(ViewFilters(), now: now)
    #expect(model.customWindow == nil)
    #expect(model.range == .hour1)
    #expect(model.query.isEmpty)
}

@MainActor @Test func settingsViewModelAppliesAndMatchesPane() {
    let model = SettingsViewModel()
    model.apply(ViewFilters(settingsPane: .alerts), now: Date())
    #expect(model.pane == .alerts)
    #expect(model.shows(ViewFilters(settingsPane: .alerts)))
    #expect(model.shows(ViewFilters()))
    #expect(!model.shows(ViewFilters(settingsPane: .general)))
    model.apply(ViewFilters(), now: Date())
    #expect(model.pane == .alerts)
}
