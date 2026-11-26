import Foundation
import Testing
@testable import Smack

@MainActor
@Test func environmentMonitoringAppliesDevelopmentSettingsWithoutStartingDiscovery() {
    let suiteName = "EnvironmentMonitoringTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    settings.update {
        $0.devTools.devProjectFolders = ["/tmp/project"]
        $0.devTools.devScanDepth = 2
    }
    let environment = EnvironmentMonitoring(settingsStore: settings)

    environment.apply(settings: settings.settings)

    #expect(environment.projectsModel.folders == ["/tmp/project"])
    #expect(environment.projectsModel.depth == 2)
    #expect(environment.projectsModel.snapshot == nil)
    #expect(environment.devServersModel.devServers == nil)
}
