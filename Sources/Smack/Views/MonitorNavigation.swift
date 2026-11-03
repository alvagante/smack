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
        var activity: [AppRoute] = [.applications, .timeline, .history]
        if Capabilities.supportsNetworkPortInspection { activity.append(.networkPorts) }
        if Capabilities.supportsStartupItems { activity.append(.startupItems) }
        activity.append(.baseline)
        let environment: [AppRoute] = (Capabilities.isSandboxed ? [] : SummaryPage.allCases.filter(settings.shows).map(\.route)) + [.systemDetails]
        return [
            MonitorNavigationSection(title: "", routes: [.summary]),
            MonitorNavigationSection(title: "Performance", routes: [.resource(.cpu), .resource(.gpu), .resource(.memory), .resource(.network), .resource(.disk)]),
            MonitorNavigationSection(title: "Health", routes: health),
            MonitorNavigationSection(title: "Activity", routes: activity),
            MonitorNavigationSection(title: "Environment", routes: environment),
            MonitorNavigationSection(title: "Smack", routes: [.settings])
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

extension MonitorStore {
    /// What a Detail Page is about, shown after the page title; nil for other pages or once it has exited.
    var routeSubject: String? {
        switch route {
        case .application(let id): application(id: id)?.name
        case .process(let id): process(id: id)?.name
        default: nil
        }
    }
}

struct MonitorSidebar: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        // The selection is drawn here rather than by `List(selection:)`: the panel is non-activating, so at launch the
        // window is not key and the system highlight is the inactive gray behind white text.
        ScrollView {
            VStack(alignment: .leading, spacing: SidebarStyle.rowSpacing) {
                ForEach(MonitorNavigation.sections(settings: settingsStore.settings, hasBattery: store.system?.battery?.isPresent == true)) { section in
                    if !section.title.isEmpty { SidebarHeader(title: section.title) }
                    ForEach(section.routes, id: \.self) { route in
                        Button { store.route = route } label: {
                            HStack(spacing: SidebarStyle.iconSpacing) {
                                ResourceIcon(systemImage: route.systemImage, color: route.tint, size: 22)
                                Text(route.title).lineLimit(1)
                            }
                        }
                        .buttonStyle(DetailNavigationStyle(selected: store.route.sidebarRoute == route, prominent: true))
                        .help(route.title)
                    }
                }
            }
            .padding(SidebarStyle.padding)
        }
        // Rows scroll out of sight at the titlebar's lower edge instead of passing under the window controls.
        .clipped()
        .background(MonitorStyle.sidebar)
        .accessibilityLabel("Pages")
    }
}
