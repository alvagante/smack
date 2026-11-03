import Foundation
import Synchronization
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: CollectionSettings
    @Published var errorMessage: String?
    private let defaults: UserDefaults
    /// v2 holds the grouped layout; v1 (flat keys, up to 0.7.0) is migrated on first launch and left in place.
    static let storageKey = "collection-settings-v2"
    static let legacyStorageKey = "collection-settings-v1"
    private let key = SettingsStore.storageKey
    /// Bundle identifier used up to 0.3.0. Its defaults domain is readable only outside the sandbox and only ever
    /// held the v1 layout.
    static let legacyDefaultsDomain = "com.smack.monitor"

    init(defaults: UserDefaults = .standard, legacyDefaults: UserDefaults? = UserDefaults(suiteName: legacyDefaultsDomain),
         loginItemEnabled: () -> Bool = { SMAppService.mainApp.status == .enabled }) {
        self.defaults = defaults
        var migrated = false
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(CollectionSettings.self, from: data) {
            settings = decoded
        } else if let flat = defaults.data(forKey: Self.legacyStorageKey) ?? legacyDefaults?.data(forKey: Self.legacyStorageKey),
                  let decoded = CollectionSettings.migratingFlatLayout(flat) {
            settings = decoded
            migrated = true
        } else {
            settings = CollectionSettings()
            // Nothing saved yet: the login item may still be registered from an earlier install.
            settings.panel.launchAtLogin = loginItemEnabled()
        }
        settings.validate()
        if migrated { persist(settings) }
        MemoryBudget.current.withLock { [budget = settings.sampling.memoryBudget] in $0 = budget }
    }

    /// Updates settings using the provided mutation closure, immediately validating,
    /// persisting to `UserDefaults`, and flushing changes synchronously to disk.
    /// - Parameter change: In-out mutation closure applying configuration changes.
    func update(_ change: (inout CollectionSettings) -> Void) {
        var updated = settings
        change(&updated)
        let oldLoginPreference = settings.panel.launchAtLogin
        updated.validate()
        settings = updated
        MemoryBudget.current.withLock { $0 = updated.sampling.memoryBudget }
        persist(updated)
        if oldLoginPreference != updated.panel.launchAtLogin {
            updateLoginItem(enabled: updated.panel.launchAtLogin)
        }
    }

    /// Explicitly flushes pending preference modifications to persistent disk storage.
    func synchronize() {
        _ = defaults.synchronize()
    }

    /// Serializes settings into JSON, commits to `UserDefaults`, and invokes `defaults.synchronize()`
    /// to guarantee deterministic persistence across immediate application terminations and relaunches.
    private func persist(_ settings: CollectionSettings) {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: key)
            _ = defaults.synchronize()
        } catch {
            errorMessage = "Failed to save settings: \(error.localizedDescription)"
        }
    }

    private func updateLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Launch at Login could not be changed: \(error.localizedDescription)"
            settings.panel.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
