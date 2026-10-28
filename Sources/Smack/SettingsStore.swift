import Foundation
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: CollectionSettings
    @Published var errorMessage: String?
    private let defaults: UserDefaults
    private let key = "collection-settings-v1"
    /// Bundle identifier used up to 0.3.0. Its defaults domain is readable only outside the sandbox.
    static let legacyDefaultsDomain = "com.smack.monitor"

    init(defaults: UserDefaults = .standard, legacyDefaults: UserDefaults? = UserDefaults(suiteName: legacyDefaultsDomain)) {
        self.defaults = defaults
        if defaults.data(forKey: key) == nil, let legacy = legacyDefaults?.data(forKey: key) {
            defaults.set(legacy, forKey: key)
        }
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(CollectionSettings.self, from: data) {
            settings = decoded
        } else {
            settings = CollectionSettings()
        }
        settings.validate()
    }

    func update(_ change: (inout CollectionSettings) -> Void) {
        var updated = settings
        change(&updated)
        let oldLoginPreference = settings.launchAtLogin
        updated.validate()
        settings = updated
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: key)
        }
        if oldLoginPreference != updated.launchAtLogin {
            updateLoginItem(enabled: updated.launchAtLogin)
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
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
