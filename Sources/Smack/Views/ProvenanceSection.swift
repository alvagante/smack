import SwiftUI

/// Where a process came from: ancestry, origin, signature, architecture and a knowledge base entry.
struct ProvenanceSection: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject private var inspection: ProcessInspectionModel
    let process: ProcessMetrics

    init(store: MonitorStore, process: ProcessMetrics) {
        self.store = store
        inspection = store.inspection
        self.process = process
    }

    var body: some View {
        if let provenance = inspection.provenance, provenance.processID == process.id {
            VStack(alignment: .leading, spacing: MonitorStyle.spacing) {
                verdict(provenance)
                if let knowledge = provenance.knowledge { knowledgeCard(knowledge) }
                MetricCard(title: "Ancestry", systemImage: "arrow.triangle.branch", color: .teal) {
                    ancestry(provenance)
                }
                DetailFactGrid(facts: facts(provenance))
                entitlements(provenance.signature)
                gatekeeper
            }
        } else {
            ProgressView("Reading provenance…").controlSize(.small)
        }
    }

    /// The signature reading, large: the one fact most people open this section for.
    private func verdict(_ provenance: ProcessProvenance) -> some View {
        let info = provenance.signature
        let badge = ApplicationListReadings.signer(info)
        let color = badge?.tone.color ?? .secondary
        let tint = badge?.tone == .apple ? Color.gray : color
        return HStack(alignment: .center, spacing: 14) {
            ResourceIcon(systemImage: badge?.systemImage ?? "questionmark.diamond", color: tint, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(badge?.title ?? "Signature \(info.trustDescription.lowercased())").font(.title3.weight(.semibold))
                Text(badge?.detail ?? "The code signature could not be read.").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let certificate = info.certificateName {
                    Text(certificate + (info.teamIdentifier.map { " · Team \($0)" } ?? ""))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: MonitorStyle.radius))
        .overlay(RoundedRectangle(cornerRadius: MonitorStyle.radius).strokeBorder(tint.opacity(0.3)))
    }

    private func facts(_ provenance: ProcessProvenance) -> [DetailFact] {
        let info = provenance.signature
        var facts = [
            DetailFact(title: "Origin", value: provenance.origin.title, systemImage: originSymbol(provenance.origin), tone: .blue),
            DetailFact(title: "Launchd job",
                       value: Capabilities.supportsStartupItems ? provenance.launchdLabel ?? "None matched" : "Unavailable in App Store build",
                       systemImage: "gearshape.2", tone: provenance.launchdLabel == nil ? nil : .indigo, monospaced: provenance.launchdLabel != nil),
            DetailFact(title: "Architecture", value: architecture(provenance), systemImage: "cpu",
                       tone: provenance.isTranslated == true ? .orange : .teal,
                       help: provenance.isTranslated == true ? "Runs under Rosetta translation." : nil),
            DetailFact(title: "Quarantine", value: provenance.quarantine ?? (process.executablePath == nil ? "Unavailable" : "None"),
                       systemImage: provenance.quarantine == nil ? "checkmark.shield" : "exclamationmark.shield",
                       tone: provenance.quarantine == nil ? nil : .orange,
                       help: "Downloaded files carry a quarantine attribute until Gatekeeper approves them."),
        ]
        if info.trust == .signed || info.trust == .adHoc {
            facts.append(DetailFact(title: "Hardened runtime", value: info.hardenedRuntime ? "Enabled" : "Disabled",
                                    systemImage: info.hardenedRuntime ? "lock.shield" : "lock.open",
                                    tone: info.hardenedRuntime ? .green : .orange))
            if let identifier = info.identifier {
                facts.append(DetailFact(title: "Identifier", value: identifier, systemImage: "number", monospaced: true))
            }
        }
        return facts
    }

    private func architecture(_ provenance: ProcessProvenance) -> String {
        let value = provenance.architecture ?? "Unavailable"
        return provenance.isTranslated == true ? "\(value) (Rosetta)" : value
    }

    private func originSymbol(_ origin: ProcessOrigin) -> String {
        switch origin {
        case .application: "app"
        case .userAgent: "person.crop.circle"
        case .systemDaemon: "gearshape.2"
        case .commandLine: "terminal"
        case .unknown: "questionmark"
        }
    }

    /// launchd first, the process last; running ancestors open their own page.
    private func ancestry(_ provenance: ProcessProvenance) -> some View {
        FlowLayout(spacing: 4, lineSpacing: 6) {
            if provenance.ancestors.isEmpty {
                Text("Unavailable").foregroundStyle(.secondary)
            }
            ForEach(provenance.ancestors.reversed()) { ancestor in
                let running = ancestor.isExited ? nil : store.process(pid: ancestor.pid)
                Button { if let running { store.route = .process(running.id) } } label: {
                    node(ancestor.name, pid: ancestor.pid, exited: ancestor.isExited, current: false)
                }
                .buttonStyle(.plain)
                .disabled(running == nil)
                .help(ancestor.executablePath ?? ancestor.name)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary).frame(height: 24)
            }
            node(process.name, pid: process.identity.pid, exited: false, current: true)
        }
    }

    private func node(_ name: String, pid: Int32, exited: Bool, current: Bool) -> some View {
        HStack(spacing: 4) {
            Text(name).fontWeight(current ? .semibold : .regular).strikethrough(exited)
            Text(String(pid)).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(current ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(current ? Color.accentColor.opacity(0.5) : .clear))
        .foregroundStyle(exited ? .secondary : .primary)
    }

    @ViewBuilder
    private func entitlements(_ info: CodeSignatureInfo) -> some View {
        if (info.trust == .signed || info.trust == .adHoc), !info.entitlementsSummary.isEmpty {
            MetricCard(title: "Entitlements", systemImage: "checkmark.seal", color: .indigo) {
                FlowLayout {
                    ForEach(info.entitlementsSummary, id: \.self) { item in
                        DetailBadge(text: item, color: DetailReadings.isRiskyEntitlement(item) ? .orange : .indigo)
                    }
                }
            }
        }
    }

    private func knowledgeCard(_ knowledge: ProcessKnowledge) -> some View {
        let color = badgeColor(knowledge.safeToQuit)
        return HStack(alignment: .top, spacing: 12) {
            ResourceIcon(systemImage: "book.closed", color: .brown, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(knowledge.title).font(.headline)
                    DetailBadge(text: knowledge.safeToQuitDescription, color: color)
                }
                Text(knowledge.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(knowledge.category).font(.caption).foregroundStyle(.tertiary)
                    if let url = knowledge.url.flatMap(URL.init(string:)) {
                        Link("Learn more", destination: url).font(.caption)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .monitorSurface()
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
                Button("Check with Gatekeeper") { inspection.checkGatekeeper(path: path) }
                    .disabled(inspection.gatekeeperRunning)
                if inspection.gatekeeperRunning { ProgressView().controlSize(.small) }
            }
            if let result = inspection.gatekeeperResult {
                Text(result).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// Provenance at a glance, as badges: signer, origin, architecture, quarantine and quit guidance.
struct ProvenanceHighlights: View {
    @ObservedObject private var inspection: ProcessInspectionModel
    let process: ProcessMetrics
    let open: () -> Void

    init(store: MonitorStore, process: ProcessMetrics, open: @escaping () -> Void) {
        inspection = store.inspection
        self.process = process
        self.open = open
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                if let provenance = inspection.provenance, provenance.processID == process.id {
                    FlowLayout {
                        if let badge = ApplicationListReadings.signer(provenance.signature) {
                            DetailBadge(text: badge.title, systemImage: badge.systemImage, color: badge.tone.color)
                        } else {
                            DetailBadge(text: "Signature unavailable", color: .secondary)
                        }
                        DetailBadge(text: provenance.origin.title, color: .blue)
                        if let architecture = provenance.architecture {
                            DetailBadge(text: provenance.isTranslated == true ? "\(architecture) · Rosetta" : architecture,
                                        color: provenance.isTranslated == true ? .orange : .teal)
                        }
                        if provenance.quarantine != nil { DetailBadge(text: "Quarantined", systemImage: "exclamationmark.shield", color: .orange) }
                        if let knowledge = provenance.knowledge {
                            DetailBadge(text: knowledge.safeToQuitDescription, color: knowledge.safeToQuit == "yes" ? .green : .orange)
                        }
                    }
                } else {
                    Text("Reading provenance…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Provenance")
    }
}
