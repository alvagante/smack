import SwiftUI

extension PostureStatus {
    var title: String {
        switch self {
        case .pass: "Passed"
        case .warn: "Warning"
        case .fail: "Failed"
        case .unknown: "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .pass: .green
        case .warn: .orange
        case .fail: .red
        case .unknown: .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .pass: "checkmark.shield.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }

    /// Lower sorts first: problems before unknowns before passes.
    var severityRank: Int {
        switch self {
        case .fail: 0
        case .warn: 1
        case .unknown: 2
        case .pass: 3
        }
    }
}

extension PostureArea {
    var title: String {
        switch self {
        case .system: "System Protection"
        case .network: "Network Services"
        case .privacy: "Privacy"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "lock.shield"
        case .network: "network"
        case .privacy: "hand.raised"
        }
    }
}

extension PostureCheck {
    /// Human-readable name for the check identifier.
    var title: String {
        switch id {
        case "sip": "System Integrity Protection"
        case "authenticated-root": "Authenticated Root Volume"
        case "filevault": "FileVault"
        case "gatekeeper": "Gatekeeper"
        case "firewall": "Firewall"
        case "firewall-stealth": "Firewall Stealth Mode"
        case "auto-update": "Automatic Updates"
        case "xprotect": "XProtect"
        case "mdm": "MDM Enrollment"
        case "config-profiles": "Configuration Profiles"
        case "system-extensions": "System Extensions"
        case "remote-login": "Remote Login (SSH)"
        case "screen-sharing": "Screen Sharing"
        case "file-sharing": "File Sharing"
        case "auto-login": "Automatic Login"
        case "guest": "Guest Account"
        case "lockdown": "Lockdown Mode"
        case "tcc-user": "Privacy Permissions (User)"
        case "tcc-system": "Privacy Permissions (System)"
        default: id
        }
    }
}

struct SecurityView: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ResourceTitle(title: "Security", systemImage: "shield", color: .green)
                DetailStatsGrid(stats: stats, color: .green)
                Spacer(minLength: 0)
                if let timestamp = store.posture?.timestamp {
                    Text(Calendar.current.isDateInToday(timestamp)
                         ? timestamp.formatted(date: .omitted, time: .shortened)
                         : timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("Last checked \(timestamp.formatted())")
                }
            }
            .padding()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let snapshot = store.posture {
                        ForEach([PostureArea.system, .network, .privacy], id: \.self) { area in
                            let checks = snapshot.checks.filter { $0.area == area }.sorted { $0.status.severityRank < $1.status.severityRank }
                            if !checks.isEmpty {
                                Label(area.title, systemImage: area.systemImage).font(.headline)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                                    ForEach(checks) { PostureCheckCard(check: $0) }
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            Capabilities.supportsPostureChecks ? "Awaiting Checks" : "Unavailable",
                            systemImage: "shield",
                            description: Text(Capabilities.supportsPostureChecks
                                ? "Awaiting scheduled collection. Configure posture checks in Settings > Security."
                                : "Not available in this edition.")
                        )
                    }
                    Text("Offline observations, collected after 60 seconds and on the configured background schedule. Unknown means the setting could not be verified. Smack never changes security settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding([.horizontal, .bottom])
            }
        }
    }

    private var stats: [ResourceStat] {
        func count(_ status: PostureStatus) -> String {
            store.posture.map { String($0.checks.filter { $0.status == status }.count) } ?? "–"
        }
        return [
            ResourceStat(title: "Passed", systemImage: PostureStatus.pass.systemImage, value: count(.pass), color: .green),
            ResourceStat(title: "Warnings", systemImage: PostureStatus.warn.systemImage, value: count(.warn), color: .orange),
            ResourceStat(title: "Failed", systemImage: PostureStatus.fail.systemImage, value: count(.fail), color: .red),
            ResourceStat(title: "Unknown", systemImage: PostureStatus.unknown.systemImage, value: count(.unknown),
                         help: "Settings that could not be verified, for example without Full Disk Access.", color: .gray),
        ]
    }
}

private struct PostureCheckCard: View {
    let check: PostureCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: check.status.systemImage).foregroundStyle(check.status.color)
                Text(check.title).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                Text(check.status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(check.status.color)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(check.status.color.opacity(0.15), in: Capsule())
            }
            Text(check.summary).font(.callout).lineLimit(3)
            if let reason = check.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            if !check.evidence.isEmpty, check.evidence != check.summary {
                DisclosureGroup("Evidence") {
                    Text(check.evidence)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
            if check.status != .pass {
                if let remediation = check.remediation { Text(remediation).font(.caption).foregroundStyle(.secondary) }
                if let url = check.settingsURL { Link("Open security settings", destination: url).font(.caption) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(check.status.color.opacity(check.status == .pass ? 0.08 : 0.35), lineWidth: 1)
        }
    }
}
