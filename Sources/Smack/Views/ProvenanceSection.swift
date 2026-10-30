import SwiftUI

/// Where a process came from: ancestry, origin, signature, architecture and a knowledge base entry.
struct ProvenanceSection: View {
    @ObservedObject var store: MonitorStore
    let process: ProcessMetrics

    var body: some View {
        if let provenance = store.provenance, provenance.processID == process.id {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Provenance")
                breadcrumb(provenance)
                KeyValueRow(key: "Origin", value: provenance.origin.title)
                if Capabilities.supportsStartupItems {
                    KeyValueRow(key: "Launchd job", value: provenance.launchdLabel ?? "None matched")
                } else {
                    KeyValueRow(key: "Launchd job", value: "Unavailable in App Store build")
                }
                KeyValueRow(key: "Architecture", value: provenance.architecture ?? "Unavailable")
                KeyValueRow(key: "Translated (Rosetta)", value: translated(provenance.isTranslated))
                signature(provenance.signature)
                KeyValueRow(key: "Quarantine", value: provenance.quarantine ?? (process.executablePath == nil ? "Unavailable" : "None"))
                if let knowledge = provenance.knowledge { knowledgeCard(knowledge) }
                gatekeeper
            }
        }
    }

    private func translated(_ value: Bool?) -> String {
        switch value {
        case true?: "Yes"
        case false?: "No"
        case nil: "Unavailable"
        }
    }

    private func breadcrumb(_ provenance: ProcessProvenance) -> some View {
        let chain = provenance.ancestors.reversed().map { ancestor in
            ancestor.isExited ? "\(ancestor.name) (\(ancestor.pid), exited)" : "\(ancestor.name) (\(ancestor.pid))"
        } + ["\(process.name) (\(process.identity.pid))"]
        return KeyValueRow(key: "Ancestry", value: provenance.ancestors.isEmpty ? "Unavailable" : chain.joined(separator: " › "))
    }

    @ViewBuilder
    private func signature(_ info: CodeSignatureInfo) -> some View {
        KeyValueRow(key: "Signature", value: info.trustDescription)
        if info.trust == .signed || info.trust == .adHoc {
            if let identifier = info.identifier { KeyValueRow(key: "Identifier", value: identifier) }
            if let team = info.teamIdentifier { KeyValueRow(key: "Team ID", value: team) }
            if let certificate = info.certificateName { KeyValueRow(key: "Certificate", value: certificate) }
            KeyValueRow(key: "Hardened runtime", value: info.hardenedRuntime ? "Yes" : "No")
            if !info.entitlementsSummary.isEmpty {
                KeyValueRow(key: "Entitlements", value: info.entitlementsSummary.joined(separator: "\n"))
            }
        }
    }

    private func knowledgeCard(_ knowledge: ProcessKnowledge) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(knowledge.title).font(.headline)
                Spacer()
                Text(knowledge.safeToQuitDescription)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(badgeColor(knowledge.safeToQuit).opacity(0.2), in: Capsule())
            }
            Text(knowledge.summary).font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(knowledge.category).font(.caption).foregroundStyle(.tertiary)
                if let url = knowledge.url.flatMap(URL.init(string:)) {
                    Link("Learn more", destination: url).font(.caption)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func badgeColor(_ value: String) -> Color {
        switch value {
        case "yes": .green
        case "withCare": .orange
        case "no", "never": .red
        default: .secondary
        }
    }

    @ViewBuilder
    private var gatekeeper: some View {
        if Capabilities.supportsGatekeeperCheck, let path = process.executablePath {
            HStack {
                Button("Check with Gatekeeper") { store.checkGatekeeper(path: path) }
                    .disabled(store.gatekeeperRunning)
                if store.gatekeeperRunning { ProgressView().controlSize(.small) }
            }
            if let result = store.gatekeeperResult {
                Text(result).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
            }
        }
    }
}

/// One-line provenance for an application's main process, linking to the process page.
struct ProvenanceSummaryRow: View {
    @ObservedObject var store: MonitorStore
    let process: ProcessMetrics

    var body: some View {
        Button { store.route = .process(process.id) } label: {
            HStack {
                Text("Provenance").foregroundStyle(.secondary)
                Spacer()
                Text(summary).multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .font(.callout)
        }
        .buttonStyle(.plain)
        .onAppear { store.loadProvenance(for: process) }
    }

    private var summary: String {
        guard let provenance = store.provenance, provenance.processID == process.id else { return "Loading…" }
        var parts = [provenance.signature.trustDescription]
        if let architecture = provenance.architecture { parts.append(architecture) }
        if let knowledge = provenance.knowledge { parts.append(knowledge.safeToQuitDescription) }
        return parts.joined(separator: " · ")
    }
}
