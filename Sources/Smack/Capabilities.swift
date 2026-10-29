import Foundation

enum DistributionFlavor: String, Sendable {
    case direct
    case appStore
}

/// Features that depend on how Smack is distributed. The direct build is not sandboxed and
/// ships the privileged helper; the App Store build is sandboxed and must not reference
/// private APIs or spawn external tools.
enum Capabilities {
#if SMACK_APP_STORE
    static let flavor: DistributionFlavor = .appStore
#else
    static let flavor: DistributionFlavor = .direct
#endif

    static var isSandboxed: Bool { flavor == .appStore }
    static var supportsPrivilegedSampling: Bool { flavor == .direct }
    static var supportsNativeMenuBarIcons: Bool { flavor == .direct }
    static var supportsMenuBarClickForwarding: Bool { flavor == .direct }
    static var supportsNetworkPortInspection: Bool { flavor == .direct }
    static var supportsStartupItems: Bool { flavor == .direct }
}
