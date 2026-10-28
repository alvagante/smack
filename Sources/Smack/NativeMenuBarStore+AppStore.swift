#if SMACK_APP_STORE
import AppKit
import Foundation
import SwiftUI

struct NativeMenuBarView: View {
    var menuBarStore: NativeMenuBarStore
    var settingsStore: SettingsStore
    var body: some View { EmptyView() }
}

/// The App Store build cannot use the private window-server APIs or post events to other
/// apps, so native menu-bar icons are not available. This stub keeps the panel controller
/// free of conditional code.
@MainActor
final class NativeMenuBarStore: ObservableObject {
    var onItemActivated: (() -> Void)?

    func setPanelVisible(_ visible: Bool, screen: NSScreen? = nil) {}

    func setFeatureEnabled(_ enabled: Bool) {}

    func requestPermissions() {}

    func refresh() {}

    func relaunch() {}

    func openScreenCaptureSettings() {}

    func openAccessibilitySettings() {}
}
#endif
