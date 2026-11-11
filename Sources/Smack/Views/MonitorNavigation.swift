import SwiftUI

struct MonitorNavigationSection: Identifiable {
    var id: String { title }
    let title: String
    let routes: [AppRoute]
    var category: RouteCategory? = nil
}

/// One navigation catalogue keeps the sidebar, page titles and detail-page selection in agreement.
enum MonitorNavigation {
    static func sections(settings: CollectionSettings, hasBattery: Bool) -> [MonitorNavigationSection] {
        [MonitorNavigationSection(title: "", routes: [.summary])] + RouteCategory.allCases.map { category in
            MonitorNavigationSection(title: category.title, routes: category.catalog.filter { route in
                switch route {
                case .resource(.battery): hasBattery
                case .security: Capabilities.supportsPostureChecks
                case .networkPorts: Capabilities.supportsNetworkPortInspection
                case .startupItems: Capabilities.supportsStartupItems
                case .documents: !Capabilities.isSandboxed
                default: SummaryPage.allCases.first { $0.route == route }.map { !Capabilities.isSandboxed && settings.shows($0) } ?? true
                }
            }, category: category)
        }.filter { !$0.routes.isEmpty }
    }
}

/// The groups of Pages shared by the sidebar and Summary. Each owns a hue range; its Pages take shades across it.
enum RouteCategory: CaseIterable {
    case performance, health, activity, work, environment, smack

    var title: String {
        switch self {
        case .performance: "Performance"
        case .health: "Health"
        case .activity: "Activity"
        case .work: "Work"
        case .environment: "Environment"
        case .smack: "Smack"
        }
    }

    /// Every Page the category can list, in sidebar order. A Page's shade comes from its place here,
    /// so hiding another Page never recolors it.
    var catalog: [AppRoute] {
        switch self {
        case .performance: [.resource(.cpu), .resource(.gpu), .resource(.memory), .resource(.network), .resource(.disk)]
        case .health: [.resource(.storage), .resource(.thermal), .resource(.battery), .security]
        case .activity: [.applications, .timeline, .history, .insights, .networkPorts, .startupItems, .baseline]
        case .work: [.projects, .documents, .devServers, .docker, .agents]
        case .environment: [.homebrew, .devEnvironments, .userHome, .installedApps, .systemDetails]
        case .smack: [.settings]
        }
    }

    /// Hue range on the color wheel, 0 to 1; ranges never overlap.
    var hues: ClosedRange<Double> {
        switch self {
        case .performance: 0.53...0.66
        case .health: 0.27...0.44
        case .activity: 0.02...0.12
        case .work: 0.70...0.79
        case .environment: 0.84...0.94
        case .smack: 0...0
        }
    }

    /// Shade of the Page at `index` in `catalog`: hues spread evenly, alternating brightness separates neighbors.
    func tone(_ index: Int) -> (hue: Double, saturation: Double, brightness: Double) {
        guard self != .smack else { return (0, 0, 0.56) }
        let step = catalog.count > 1 ? Double(index) / Double(catalog.count - 1) : 0.5
        return (hues.lowerBound + (hues.upperBound - hues.lowerBound) * step, 0.72, index.isMultiple(of: 2) ? 0.92 : 0.8)
    }

    /// The middle shade, for headers that stand for the whole category.
    var color: Color {
        guard self != .smack else { return .gray }
        return Color(hue: (hues.lowerBound + hues.upperBound) / 2, saturation: 0.72, brightness: 0.86)
    }
}

extension SummaryPage {
    var route: AppRoute {
        switch self {
        case .devServers: .devServers
        case .docker: .docker
        case .homebrew: .homebrew
        case .devEnvironments: .devEnvironments
        case .projects: .projects
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
        case .project: .projects
        case .document: .documents
        case .agentSession: .agents
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
        case .projects: "Projects"
        case .documents: "Documents"
        case .document: "Document details"
        case .project: "Project detail"
        case .userHome: "User home"
        case .agents: "AI agents"
        case .agentSession: "Agent session"
        case .installedApps: "Installed apps"
        case .startupItems: "Startup items"
        case .timeline: "Timeline"
        case .history: "Historical data"
        case .insights: "Insights"
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
        case .projects, .project: "folder"
        case .documents, .document: "doc.on.doc"
        case .userHome: "house"
        case .agents, .agentSession: "sparkles"
        case .installedApps: "square.grid.3x3"
        case .startupItems: "sunrise"
        case .timeline: "list.bullet.rectangle"
        case .history: "clock.arrow.circlepath"
        case .insights: "lightbulb"
        case .settings: "gearshape"
        case .systemDetails: "info.circle"
        case .security: "shield"
        case .baseline: "arrow.triangle.branch"
        case .unavailable: "lock"
        }
    }

    /// The category a Page belongs to; detail pages belong to their parent's. Nil for Summary and Unavailable.
    var category: RouteCategory? {
        guard let route = sidebarRoute else { return nil }
        return RouteCategory.allCases.first { $0.catalog.contains(route) }
    }

    var tint: Color {
        guard let route = sidebarRoute, let category, let index = category.catalog.firstIndex(of: route) else { return .gray }
        let tone = category.tone(index)
        return Color(hue: tone.hue, saturation: tone.saturation, brightness: tone.brightness)
    }
}

extension MonitorStore {
    /// What a Detail Page is about, shown after the page title; nil for other pages or once it has exited.
    var routeSubject: String? {
        switch route {
        case .application(let id): application(id: id)?.name
        case .process(let id): process(id: id)?.name
        case .project(let root): project(root: root)?.name
        case .document(let path): URL(fileURLWithPath: path).lastPathComponent
        case .agentSession(let id): agentsModel.live.sessions.first { $0.id == id }.map { session in
            [session.agentName, session.project?.name].compactMap { $0 }.joined(separator: " · ")
        }
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
                    if !section.title.isEmpty { SidebarHeader(title: section.title, color: section.category?.color) }
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
