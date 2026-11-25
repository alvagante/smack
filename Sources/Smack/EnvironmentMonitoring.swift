import Combine
import Foundation

@MainActor
final class EnvironmentMonitoring {
    private let settingsStore: SettingsStore
    let dockerModel = DockerMonitor()
    let homebrewModel = HomebrewMonitor()
    let devEnvironmentModel = DevEnvironmentMonitor()
    let projectsModel = ProjectsMonitor()
    let agentsModel = AgentMonitor()
    let installedAppsModel = InstalledAppsMonitor()
    let devServersModel = DevServersModel()

    private var dockerObservation: AnyCancellable?
    private var networkPorts: NetworkPortSnapshot?
    private var processes: ProcessSnapshot?
    private var route: AppRoute = .summary
    private var panelVisible = false
    private var appliedPages: Set<SummaryPage> = []

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        devEnvironmentModel.onFoldersChanged = { [weak settingsStore] folders in
            settingsStore?.update { $0.devTools.devProjectFolders = folders }
        }
        projectsModel.onFoldersChanged = { [weak settingsStore] folders in
            settingsStore?.update { $0.devTools.devProjectFolders = folders }
        }
        dockerObservation = dockerModel.$snapshot.dropFirst().sink { [weak self] _ in
            // Published delivers before assignment; read the new snapshot on the next actor turn.
            Task { @MainActor [weak self] in self?.refreshDevServers() }
        }
    }

    func apply(settings: CollectionSettings) {
        dockerModel.configure(refreshSeconds: settings.devTools.dockerRefreshSeconds, liveStats: settings.devTools.dockerLiveStats, cache: settings.devTools.inventoryCache)
        homebrewModel.cache = settings.devTools.inventoryCache
        devEnvironmentModel.configure(folders: settings.devTools.devProjectFolders, depth: settings.devTools.devScanDepth, cache: settings.devTools.inventoryCache)
        projectsModel.configure(folders: settings.devTools.devProjectFolders, depth: settings.devTools.devScanDepth, cache: settings.devTools.inventoryCache)
        agentsModel.configure(excluded: settings.devTools.excludedAgents, customFolders: settings.devTools.customAgentFolders, cache: settings.devTools.inventoryCache)
        let shown = Set(SummaryPage.allCases.filter(settings.shows))
        let changed = shown.symmetricDifference(appliedPages)
        appliedPages = shown
        // Only pages whose state changed: re-showing an unchanged one would cancel its in-flight discovery.
        if panelVisible, !changed.isEmpty { setPageMonitorsVisible(true, only: changed) }
        updateDevServerVisibility()
    }

    func update(route: AppRoute) {
        self.route = route
        updateDevServerVisibility()
    }

    func setVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        setPageMonitorsVisible(visible)
        updateDevServerVisibility()
    }

    func receive(_ snapshot: ProcessSnapshot) {
        processes = snapshot
        agentsModel.receive(snapshot.agentSessions, at: snapshot.timestamp)
        if devServersModel.devServers == nil { refreshDevServers() }
    }

    func receive(_ snapshot: NetworkPortSnapshot) {
        networkPorts = snapshot
        refreshDevServers()
    }

    /// Hidden pages skip discovery; hiding one while the panel is open stops its refresh loop.
    private func setPageMonitorsVisible(_ visible: Bool, only pages: Set<SummaryPage> = Set(SummaryPage.allCases)) {
        func show(_ page: SummaryPage) -> Bool { visible && appliedPages.contains(page) }
        if pages.contains(.docker) { dockerModel.setVisible(show(.docker) || devServersWanted) }
        if pages.contains(.homebrew) { homebrewModel.setVisible(show(.homebrew)) }
        if pages.contains(.devEnvironments) { devEnvironmentModel.setVisible(show(.devEnvironments)) }
        if pages.contains(.projects) { projectsModel.setVisible(show(.projects)) }
        if pages.contains(.agents) { agentsModel.setVisible(show(.agents)) }
        if pages.contains(.installedApps) { installedAppsModel.setVisible(show(.installedApps)) }
    }

    private var devServersWanted: Bool {
        Capabilities.supportsNetworkPortInspection &&
            ((panelVisible && (route == .devServers || showsProjectsRoute ||
                (route == .summary && (settingsStore.settings.shows(.devServers) || settingsStore.settings.shows(.projects))))) ||
                settingsStore.settings.devTools.backgroundDevServersEnabled)
    }

    /// Projects and their Detail Pages join dev servers, Docker Compose containers and agent sessions already in memory.
    private var showsProjectsRoute: Bool {
        switch route {
        case .projects, .project: true
        default: false
        }
    }

    private func updateDevServerVisibility() {
        dockerModel.setVisible((panelVisible && settingsStore.settings.shows(.docker)) || devServersWanted)
        if devServersWanted { refreshDevServers() }
        else { devServersModel.cancel() }
    }

    func refreshDevServers() {
        guard devServersWanted,
              let networkPorts, let processes else { return }
        devServersModel.refresh(ports: networkPorts, processes: processes, containers: dockerModel.snapshot?.containers ?? [],
            showSystem: settingsStore.settings.devTools.devServersShowSystem) { [agentsModel] in agentsModel.sessions }
    }

    func project(root: String) -> ProjectRecord? { projectsModel.project(root: root) }

    /// Dev servers, Compose containers, Agent Sessions and Development Environments already in memory that belong to
    /// the repository. Development Environments appear only if their own discovery has run; this never starts it.
    func links(forProject root: String) -> ProjectLinks {
        ProjectRelation.links(forRoot: root, servers: devServersModel.devServers ?? [],
                              containers: dockerModel.snapshot?.containers ?? [], sessions: agentsModel.sessions,
                              environments: devEnvironmentModel.snapshot?.environments ?? [])
    }
}
