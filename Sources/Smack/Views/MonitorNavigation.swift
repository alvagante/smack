import SwiftUI

struct MonitorNavigationSection: Identifiable {
    var id: String { title }
    let title: String
    let routes: [AppRoute]
}

/// One navigation catalogue keeps the sidebar, page titles and detail-page selection in agreement.
enum MonitorNavigation {
    static func sections(settings: CollectionSettings, hasBattery: Bool) -> [MonitorNavigationSection] {
        var health: [AppRoute] = [.resource(.storage), .resource(.thermal)]
        if hasBattery { health.append(.resource(.battery)) }
        if Capabilities.supportsPostureChecks { health.append(.security) }
        health.append(.baseline)
        var activity: [AppRoute] = [.applications, .timeline, .history]
        if Capabilities.supportsNetworkPortInspection { activity.append(.networkPorts) }
        if Capabilities.supportsStartupItems { activity.append(.startupItems) }
        let environment: [AppRoute] = Capabilities.isSandboxed ? [] : SummaryPage.allCases.filter(settings.shows).map(\.route)
        return [
            MonitorNavigationSection(title: "", routes: [.summary]),
            MonitorNavigationSection(title: "Performance", routes: [.resource(.cpu), .resource(.gpu), .resource(.memory), .resource(.network), .resource(.disk)]),
            MonitorNavigationSection(title: "Health", routes: health),
            MonitorNavigationSection(title: "Activity", routes: activity),
            MonitorNavigationSection(title: "Environment", routes: environment),
            MonitorNavigationSection(title: "Smack", routes: [.systemDetails, .settings])
        ].filter { !$0.routes.isEmpty }
    }
}

extension SummaryPage {
    var route: AppRoute {
        switch self {
        case .devServers: .devServers
        case .docker: .docker
        case .homebrew: .homebrew
        case .devEnvironments: .devEnvironments
        case .agents: .agents
        case .userHome: .userHome
        case .installedApps: .installedApps
        }
    }
}

extension AppRoute {
    var sidebarRoute: AppRoute? {
        switch self {
        case .application, .process: .applications
        case .unavailable: nil
        default: self
        }
    }

    var title: String {
        switch self {
        case .summary: "Summary"
        case .resource(let resource): resource.rawValue
        case .applications: "Applications"
        case .application: "Application details"
        case .process: "Process details"
        case .networkPorts: "Connections"
        case .devServers: "Dev servers"
        case .docker: "Docker"
        case .homebrew: "Homebrew"
        case .devEnvironments: "Dev environments"
        case .userHome: "User home"
        case .agents: "AI agents"
        case .installedApps: "Installed apps"
        case .startupItems: "Startup items"
        case .timeline: "Timeline"
        case .history: "Historical data"
        case .settings: "Settings"
        case .systemDetails: "System details"
        case .security: "Security"
        case .baseline: "Baselines"
        case .unavailable: "Unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .summary: "square.grid.2x2"
        case .resource(let resource):
            switch resource {
            case .cpu: "cpu"
            case .gpu: "cpu.fill"
            case .memory: "memorychip"
            case .network: "network"
            case .disk: "internaldrive"
            case .storage: "externaldrive"
            case .battery: "battery.100"
            case .thermal: "thermometer.medium"
            }
        case .applications, .application, .process: "app"
        case .networkPorts: "cable.connector"
        case .devServers: "server.rack"
        case .docker: "shippingbox"
        case .homebrew: "mug"
        case .devEnvironments: "chevron.left.forwardslash.chevron.right"
        case .userHome: "house"
        case .agents: "sparkles"
        case .installedApps: "square.grid.3x3"
        case .startupItems: "sunrise"
        case .timeline: "list.bullet.rectangle"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        case .systemDetails: "info.circle"
        case .security: "shield"
        case .baseline: "arrow.triangle.branch"
        case .unavailable: "lock"
        }
    }

    var tint: Color {
        switch self {
        case .resource(.memory), .agents: .purple
        case .resource(.network), .networkPorts: .cyan
        case .resource(.disk), .homebrew: .orange
        case .resource(.battery), .security: .green
        case .resource(.thermal): .red
        case .resource(.storage), .resource(.gpu), .baseline: .indigo
        case .timeline, .history, .devEnvironments: .teal
        case .userHome: .pink
        case .startupItems: .orange
        case .settings, .systemDetails, .unavailable: .gray
        default: .blue
        }
    }
}

struct MonitorSidebar: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        List(selection: Binding<AppRoute?>(get: { store.route.sidebarRoute }, set: { route in
            if let route, route != store.route { store.route = route }
        })) {
            ForEach(MonitorNavigation.sections(settings: settingsStore.settings, hasBattery: store.system?.battery?.isPresent == true)) { section in
                Section {
                    ForEach(section.routes, id: \.self) { route in
                        Button { store.route = route } label: {
                            Label {
                                Text(route.title).lineLimit(1)
                                    .foregroundStyle(store.route.sidebarRoute == route ? Color.white : Color.primary)
                            } icon: {
                                ResourceIcon(systemImage: route.systemImage, color: route.tint, size: 24)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tag(route)
                        .help(route.title)
                    }
                } header: {
                    if !section.title.isEmpty { Text(section.title) }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Pages")
    }
}
