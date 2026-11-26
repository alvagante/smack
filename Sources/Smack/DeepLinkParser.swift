import Foundation

struct ViewFilters: Equatable {
    var search = ""
    var port: UInt16?
    var timelineInterval: TimeInterval?
    var timelineKinds: Set<ActivityEventKind> = []
    var settingsPane: SettingsPane?
    var banner: String?
}

struct DeepLink: Equatable {
    var route: AppRoute = .summary
    var filters = ViewFilters()
}

enum DeepLinkParser {
    // This is the entire external input surface. No action or command field is accepted.
    static let queryKeys: Set<String> = ["since", "kind", "q"]

    static func parse(_ url: URL, resolveProcess: (Int32) -> String? = { _ in nil },
                      resolveApplication: (String) -> String? = { _ in nil },
                      flavor: DistributionFlavor = Capabilities.flavor) -> DeepLink {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "smack", c.user == nil, c.password == nil,
              c.port == nil, c.fragment == nil else { return DeepLink() }
        let host = c.host ?? ""
        let path = c.path
        let items = c.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ queryKeys.contains($0.name) && $0.value != nil }),
              host == "timeline" || items.isEmpty else { return DeepLink() }
        var link = DeepLink()
        let resources: [String: ResourceKind] = ["cpu": .cpu, "memory": .memory, "network": .network,
            "disk": .disk, "storage": .storage, "battery": .battery, "thermal": .thermal]
        let pages: [String: AppRoute] = ["": .summary, "summary": .summary, "apps": .applications,
            "devservers": .devServers, "ports": .networkPorts, "docker": .docker, "homebrew": .homebrew, "dev": .devEnvironments,
            "projects": .projects,
            "home": .userHome, "agents": .agents, "installed": .installedApps, "startup": .startupItems,
            "baseline": .baseline, "security": .security, "timeline": .timeline, "history": .history, "insights": .insights, "settings": .settings, "system": .systemDetails]
        if let resource = resources[host], path.isEmpty {
            link.route = .resource(resource)
        } else if host == "settings", path == "/alerts" {
            link.route = .settings
            link.filters.settingsPane = .alerts
        } else if ["app", "process", "port"].contains(host) {
            guard path.hasPrefix("/"), path.count > 1 else { return DeepLink() }
            let argument = String(path.dropFirst())
            guard !argument.contains("/"), !argument.contains("\0") else { return DeepLink() }
            switch host {
            case "app":
                link.route = resolveApplication(argument).map(AppRoute.application) ?? .applications
                if link.route == .applications { link.filters.search = argument }
            case "process":
                guard argument.allSatisfy(\.isASCII), argument.allSatisfy(\.isNumber),
                      let pid = Int32(argument), pid > 0 else { return DeepLink() }
                link.route = resolveProcess(pid).map(AppRoute.process) ?? .applications
                if link.route == .applications { link.filters.banner = "Process \(pid) is not running" }
            default:
                guard argument.allSatisfy(\.isASCII), argument.allSatisfy(\.isNumber),
                      let port = UInt16(argument), port > 0 else { return DeepLink() }
                link.route = .networkPorts
                link.filters.port = port
            }
        } else if let page = pages[host], path.isEmpty {
            link.route = page
        } else { return DeepLink() }
        if host == "timeline" {
            for item in items {
                let value = item.value!
                switch item.name {
                case "q": link.filters.search = value
                case "since":
                    guard let suffix = value.last, let multiplier = ["s": 1.0, "m": 60, "h": 3600, "d": 86400][String(suffix)],
                          let amount = Double(value.dropLast()), amount > 0,
                          (amount * multiplier).isFinite, amount * multiplier <= 604800 else { return DeepLink() }
                    link.filters.timelineInterval = amount * multiplier
                case "kind":
                    let names = value.split(separator: ",", omittingEmptySubsequences: false)
                    let kinds = names.compactMap { ActivityEventKind(rawValue: String($0)) }
                    guard kinds.count == names.count, !kinds.isEmpty else { return DeepLink() }
                    link.filters.timelineKinds = Set(kinds)
                default: return DeepLink()
                }
            }
        }
        let directOnly: Set<String> = ["devservers", "ports", "port", "docker", "homebrew", "dev", "home", "agents", "installed", "startup", "security"]
        if flavor == .appStore, directOnly.contains(host) {
            return DeepLink(route: .unavailable("Not available in this edition"))
        }
        return link
    }
}
