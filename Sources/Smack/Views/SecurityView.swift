import SwiftUI

struct SecurityView: View {
    @ObservedObject var store: MonitorStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Security").font(.title2)
                Text("Offline observations, collected after 60 seconds and on the configured background schedule. Unknown means the setting could not be verified.")
                    .foregroundStyle(.secondary)
                if let snapshot = store.posture {
                    Text("Last checked: \(snapshot.timestamp.formatted())").font(.caption)
                    ForEach(snapshot.checks) { check in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(check.id): \(check.status.rawValue)").font(.headline)
                                Text(check.summary)
                                if let reason = check.reason { Text(reason).foregroundStyle(.secondary) }
                                if !check.evidence.isEmpty { Text(check.evidence).font(.caption.monospaced()).textSelection(.enabled) }
                                if let remediation = check.remediation { Text(remediation).font(.caption) }
                                if let url = check.settingsURL { Link("Open security settings", destination: url).font(.caption) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    Text(Capabilities.supportsPostureChecks ? "Awaiting scheduled collection. Configure posture checks in Settings > Security." : "Not available in this edition.")
                }
            }.padding(14)
        }
    }
}
