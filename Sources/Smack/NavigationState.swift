enum ResourceKind: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case network = "Network"
    case disk = "Disk Activity"
    case gpu = "GPU"
    case storage = "Storage"
    case battery = "Battery"
    case thermal = "Thermal State"
    var id: String { rawValue }
}

enum AppRoute: Hashable {
    case summary
    case resource(ResourceKind)
    case applications
    case application(String)
    case process(String)
    case networkPorts
    case devServers
    case docker
    case homebrew
    case devEnvironments
    case projects
    case documents
    case document(String)
    case project(String)
    case userHome
    case agents
    case agentSession(String)
    case installedApps
    case startupItems
    case timeline
    case history
    case insights
    case settings
    case systemDetails
    case security
    case baseline
    case unavailable(String)
}

struct NavigationState {
    private(set) var route: AppRoute = .summary
    private(set) var filters = ViewFilters()
    private var routeHistory: [AppRoute] = []
    private var pendingProjectSection: ProjectSection?

    var previousRoute: AppRoute? { routeHistory.last }

    mutating func navigate(to newRoute: AppRoute, filters newFilters: ViewFilters? = nil) {
        if let newFilters { filters = newFilters }
        setRoute(newRoute, recordsHistory: true)
    }

    mutating func goBack() {
        guard let previous = routeHistory.popLast() else { return }
        setRoute(previous, recordsHistory: false)
    }

    mutating func openProject(_ root: String, section: ProjectSection = .overview) {
        pendingProjectSection = section
        navigate(to: .project(root))
    }

    mutating func takeProjectSection() -> ProjectSection? {
        defer { pendingProjectSection = nil }
        return pendingProjectSection
    }

    private mutating func setRoute(_ newRoute: AppRoute, recordsHistory: Bool) {
        guard route != newRoute else { return }
        if newRoute != .applications { filters.banner = nil }
        if newRoute == .summary {
            routeHistory.removeAll()
        } else if recordsHistory {
            routeHistory.append(route)
        }
        route = newRoute
    }
}
