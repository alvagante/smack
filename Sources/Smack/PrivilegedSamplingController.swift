import AppKit
import Foundation
import ServiceManagement
import SmackIPC

/// How the root helper gets installed, decided by how this copy of Smack is signed.
enum PrivilegedHelperMode: Equatable {
    /// Developer ID: `SMAppService.daemon`, approved in Login Items.
    case serviceManagement
    /// Self-signed: the bundled script installs a classic launch daemon after an admin prompt.
    case legacyInstall
    /// Ad hoc: there is no stable signer for the helper to pin.
    case unsupported

    init(identity: SigningIdentity) {
        switch identity {
        case .team: self = .serviceManagement
        case .certificate: self = .legacyInstall
        case .adHoc: self = .unsupported
        }
    }
}

enum PrivilegedHelperState: Equatable {
    case unsupported
    case notInstalled
    case requiresApproval
    /// Installed, but no reply: disabled in Login Items, or still starting.
    case notResponding
    case running(updateAvailable: Bool)

    /// Only a live reply counts as running: files on disk say nothing about whether launchd
    /// is allowed to start the daemon.
    static func legacy(installed: Bool, current: Bool, responding: Bool) -> PrivilegedHelperState {
        guard installed else { return .notInstalled }
        guard responding else { return .notResponding }
        return .running(updateAvailable: !current)
    }
}

/// Installs, updates, and removes the root sampling helper, and exposes its state to Settings.
/// Password prompts happen only in response to the user changing the option or pressing a
/// button, never at launch.
@MainActor
final class PrivilegedSamplingController: ObservableObject {
    @Published private(set) var state: PrivilegedHelperState = .notInstalled
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWorking = false
    /// True when a classic daemon is on disk; used to offer removal while the option is off.
    @Published private(set) var legacyInstallPresent = false

    let mode: PrivilegedHelperMode
    private let client: PrivilegedSamplingProviding

    private var service: SMAppService {
        SMAppService.daemon(plistName: SmackIPC.daemonPlistName)
    }

    init(client: PrivilegedSamplingProviding, mode: PrivilegedHelperMode = PrivilegedHelperMode(identity: .current())) {
        self.client = client
        self.mode = mode
    }

    /// Called at launch. Registers with SMAppService if needed (that shows a notification, not
    /// a password prompt); the legacy install is never started without a user action.
    func prepare(enabled: Bool) {
        guard Capabilities.supportsPrivilegedSampling else { return }
        if mode == .serviceManagement {
            if enabled, service.status == .notRegistered, !LegacyHelperInstaller.isInstalled {
                register()
            } else if !enabled, service.status == .enabled || service.status == .requiresApproval {
                unregister()
            }
        }
        Task { await refresh() }
    }

    func setEnabled(_ enabled: Bool) {
        guard Capabilities.supportsPrivilegedSampling else { return }
        errorMessage = nil
        Task {
            if enabled {
                await install()
            } else {
                await remove()
            }
        }
    }

    /// Installs or updates the helper for the current mode.
    func install() async {
        switch mode {
        case .unsupported:
            errorMessage = "Superuser sampling needs a signed build. Ad-hoc builds cannot run the helper."
        case .serviceManagement:
            // Both install methods use the same launchd label, so a classic daemon left by a
            // self-signed build must go before SMAppService can register.
            if LegacyHelperInstaller.isInstalled {
                guard await runScript(.uninstall) else { break }
            }
            if service.status != .enabled, service.status != .requiresApproval {
                register()
            }
        case .legacyInstall:
            _ = await runScript(.install)
        }
        await refresh()
    }

    func remove() async {
        switch mode {
        case .serviceManagement:
            if service.status == .enabled || service.status == .requiresApproval {
                unregister()
            }
            if LegacyHelperInstaller.isInstalled {
                _ = await runScript(.uninstall)
            }
        case .legacyInstall, .unsupported:
            if LegacyHelperInstaller.isInstalled {
                _ = await runScript(.uninstall)
            }
        }
        await refresh()
    }

    func refresh() async {
        guard Capabilities.supportsPrivilegedSampling else {
            state = .unsupported
            client.setAvailable(false)
            return
        }
        legacyInstallPresent = LegacyHelperInstaller.isInstalled
        switch mode {
        case .unsupported:
            state = .unsupported
            client.setAvailable(false)
        case .serviceManagement:
            switch service.status {
            case .enabled:
                state = await probe() ? .running(updateAvailable: false) : .notResponding
            case .requiresApproval:
                state = .requiresApproval
                client.setAvailable(false)
            default:
                state = .notInstalled
                client.setAvailable(false)
            }
        case .legacyInstall:
            let installed = legacyInstallPresent
            let responding = installed ? await probe() : false
            if !installed { client.setAvailable(false) }
            state = .legacy(installed: installed, current: LegacyHelperInstaller.isCurrent, responding: responding)
        }
    }

    func terminalCommand(for action: HelperScriptAction) -> String {
        LegacyHelperInstaller.terminalCommand(for: action)
    }

    func copyTerminalCommand(for action: HelperScriptAction) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(terminalCommand(for: action), forType: .string)
    }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    var statusDescription: String {
        switch state {
        case .unsupported:
            return "This build is ad-hoc signed, so the helper cannot run. Sign it with a certificate."
        case .notInstalled:
            return mode == .legacyInstall
                ? "The helper is not installed. Installing asks for an administrator password."
                : "The helper is not registered. Turn the option on to register it."
        case .requiresApproval:
            return "Approve Smack Helper in System Settings > General > Login Items & Extensions."
        case .notResponding:
            return "The helper is installed but not responding. Check that it is allowed in Login Items & Extensions."
        case .running(let updateAvailable):
            return updateAvailable
                ? "The helper is running, but this version of Smack ships a newer one."
                : "The helper is running. Other users' processes are included."
        }
    }

    /// One snapshot request decides whether the daemon really answers.
    private func probe() async -> Bool {
        client.setAvailable(false)
        client.setAvailable(true)
        let responding = await client.collectSnapshot() != nil
        client.setAvailable(responding)
        return responding
    }

    private func runScript(_ action: HelperScriptAction) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        // Drop the cached connection: the daemon is about to be replaced or removed.
        client.setAvailable(false)
        switch await LegacyHelperInstaller.run(action) {
        case .completed:
            return true
        case .cancelled:
            return false
        case .failed(let message):
            errorMessage = "The helper could not be \(action == .install ? "installed" : "removed"): \(message)"
            return false
        }
    }

    private func register() {
        do {
            try service.register()
        } catch {
            errorMessage = "The sampling helper could not be registered: \(error.localizedDescription)"
        }
    }

    private func unregister() {
        do {
            try service.unregister()
        } catch {
            errorMessage = "The sampling helper could not be removed: \(error.localizedDescription)"
        }
    }
}
