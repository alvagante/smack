import Foundation

@MainActor
final class BaselineCoordinator {
    let model: BaselineModel
    private let settingsStore: SettingsStore
    private let scheduler: CollectionScheduler

    init(model: BaselineModel = BaselineModel(), settingsStore: SettingsStore, scheduler: CollectionScheduler) {
        self.model = model
        self.settingsStore = settingsStore
        self.scheduler = scheduler
    }

    func capture(name: String, sections: [String]? = nil) async throws -> BaselineDocument {
        let settings = settingsStore.settings
        let ids = sections ?? BaselineDiff.rules.keys.sorted()
        async let profiles = ids.contains("profiles") ? scheduler.baselineProfiles() : nil
        async let btm = ids.contains("startup") ? scheduler.baselineBackgroundTasks() : nil
        async let listeners: NetworkPortSnapshot? = (ids.contains("listeners") || ids.contains("posture")) && Capabilities.supportsNetworkPortInspection
            ? scheduler.networkPorts() : nil
        let (profileValue, btmValue, listenerValue) = await (profiles, btm, listeners)
        try Task.checkCancellation()
        return try await BaselineCapture.capture(collectors: ids.map {
            MachineBaselineCollector(id: $0, settings: settings, listeners: listenerValue, profiles: profileValue, backgroundTasks: btmValue)
        }, name: name, progress: { [weak self] id, section in
            await MainActor.run { self?.model.progress[id] = section.status.rawValue }
        })
    }
}
