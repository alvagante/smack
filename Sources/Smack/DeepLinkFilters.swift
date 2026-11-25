import Foundation

/// A Page's view model that takes the filters of a deep link and says whether it currently shows them.
/// MonitorStore only picks the model for the route; each model owns what its filters mean.
@MainActor
protocol DeepLinkFilterable: AnyObject {
    func apply(_ filters: ViewFilters, now: Date)
    func shows(_ filters: ViewFilters) -> Bool
}

extension NetworkPortsViewModel: DeepLinkFilterable {
    func apply(_ filters: ViewFilters, now: Date) {
        query = ""
        port = filters.port
        mode = .listening
    }

    func shows(_ filters: ViewFilters) -> Bool { filters.port == port && query.isEmpty }
}

extension ApplicationListViewModel: DeepLinkFilterable {
    func apply(_ filters: ViewFilters, now: Date) { query = filters.search }
    func shows(_ filters: ViewFilters) -> Bool { filters.search == query }
}

extension TimelineViewModel: DeepLinkFilterable {
    func apply(_ filters: ViewFilters, now: Date) {
        select(range: .hour1)
        if let interval = filters.timelineInterval {
            open(window: DateInterval(start: now.addingTimeInterval(-interval), end: now))
        }
        query = filters.search
        selectedKinds = filters.timelineKinds
    }

    func shows(_ filters: ViewFilters) -> Bool {
        filters.search == query && filters.timelineKinds == selectedKinds
            && (filters.timelineInterval == nil || filters.timelineInterval == window().duration)
    }
}

extension SettingsViewModel: DeepLinkFilterable {
    func apply(_ filters: ViewFilters, now: Date) {
        if let pane = filters.settingsPane { self.pane = pane }
    }

    func shows(_ filters: ViewFilters) -> Bool { filters.settingsPane == nil || filters.settingsPane == pane }
}
