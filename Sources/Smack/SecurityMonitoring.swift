import Foundation

protocol SecurityMonitoringControlling: Sendable {
    func restoreSecurityCache() async
    func updateFeatureSettings(_ value: CollectionSettings) async
    func scanPersistence(hourly: Bool) async
    func stop() async
}

@MainActor
final class SecurityMonitoring {
    private let controller: any SecurityMonitoringControlling
    private var started = false
    private var enrichmentEnabled: Bool?
    private var persistenceWatcher: PersistenceWatcher?

    init(controller: any SecurityMonitoringControlling) {
        self.controller = controller
    }

    func start(settings: CollectionSettings) {
        started = true
        Task { await controller.restoreSecurityCache() }
        if persistenceWatcher == nil {
            persistenceWatcher = PersistenceWatcher { [controller] hourly in
                await controller.scanPersistence(hourly: hourly)
            }
        }
        apply(settings: settings)
    }

    func apply(settings: CollectionSettings) {
        guard started else { return }
        Task { await controller.updateFeatureSettings(settings) }
        if enrichmentEnabled != settings.security.persistenceEnrichmentEnabled { persistenceWatcher?.stop() }
        enrichmentEnabled = settings.security.persistenceEnrichmentEnabled
        if settings.security.watchPersistence { persistenceWatcher?.start(pollInterval: settings.security.persistencePollInterval) }
        else { persistenceWatcher?.stop() }
    }

    func stop() {
        started = false
        persistenceWatcher?.stop()
        Task { await controller.stop() }
    }
}

extension CollectionScheduler: SecurityMonitoringControlling {}
