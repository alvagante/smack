import Foundation

struct ProcessAncestor: Identifiable, Sendable, Equatable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    var executablePath: String?
    var isExited: Bool
}

struct CodeSignatureInfo: Sendable, Equatable {
    enum Trust: String, Sendable { case signed, adHoc, unsigned, unavailable }
    var trust: Trust
    var identifier: String?
    var teamIdentifier: String?
    var certificateName: String?
    var hardenedRuntime: Bool
    var entitlementsSummary: [String]

    static let unavailable = CodeSignatureInfo(
        trust: .unavailable, identifier: nil, teamIdentifier: nil, certificateName: nil,
        hardenedRuntime: false, entitlementsSummary: []
    )

    var trustDescription: String {
        switch trust {
        case .signed: "Signed"
        case .adHoc: "Ad-hoc"
        case .unsigned: "Unsigned"
        case .unavailable: "Unavailable"
        }
    }
}

enum ProcessOrigin: String, Sendable {
    case application, userAgent, systemDaemon, commandLine, unknown

    var title: String {
        switch self {
        case .application: "Application"
        case .userAgent: "Launch agent"
        case .systemDaemon: "System daemon"
        case .commandLine: "Command line"
        case .unknown: "Unknown"
        }
    }
}

struct ProcessKnowledge: Sendable, Equatable {
    var title: String
    var summary: String
    var category: String
    var safeToQuit: String
    var url: String?

    var safeToQuitDescription: String {
        switch safeToQuit {
        case "yes": "Safe to quit"
        case "withCare": "Quit with care"
        case "no": "Do not quit"
        case "never": "Never quit"
        default: "Unknown"
        }
    }
}

struct ProcessProvenance: Sendable, Equatable {
    var processID: String
    /// Nearest first, launchd last.
    var ancestors: [ProcessAncestor]
    var launchdLabel: String?
    var origin: ProcessOrigin
    var architecture: String?
    var isTranslated: Bool?
    var signature: CodeSignatureInfo
    var quarantine: String?
    var knowledge: ProcessKnowledge?
}
