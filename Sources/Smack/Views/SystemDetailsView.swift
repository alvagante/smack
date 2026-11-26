import SwiftUI

struct SystemDetailsView: View {
    @ObservedObject var store: MonitorStore
    /// Serial number and hardware UUID stay masked until revealed, and are masked again on leaving the page.
    @State private var revealsIdentifiers = false

    var body: some View {
        VStack(spacing: 0) {
            DetailPageHeader(padding: MonitorStyle.spacing) {
                ResourceTitle(title: "System Details", systemImage: "info.circle", color: AppRoute.systemDetails.tint,
                              subtitle: SystemInformation.modelName ?? SystemInformation.modelIdentifier)
            } actions: {
                EmptyView()
            } overview: {
                ResourceStatsRow(stats: stats)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(SystemInformation.sections(gpuName: store.system?.gpuName ?? "", gpuCoreCount: store.system?.gpuCoreCount)) { section in
                        SystemInformationCard(section: section, revealsSensitive: $revealsIdentifiers)
                    }
                }
                .padding([.horizontal, .bottom])
            }
        }
    }

    private var stats: [ResourceStat] {
        let macOS = ProcessInfo.processInfo.operatingSystemVersion
        let version = [macOS.majorVersion, macOS.minorVersion, macOS.patchVersion].map(String.init).joined(separator: ".")
        return [
            ResourceStat(title: "Chip", systemImage: "cpu", value: SystemInformation.processorName ?? SystemInformation.string("hw.machine") ?? "Unavailable",
                         detail: "\(ProcessInfo.processInfo.processorCount) cores"),
            ResourceStat(title: "Memory", systemImage: "memorychip", value: Formatting.bytes(ProcessInfo.processInfo.physicalMemory),
                         detail: SystemInformation.integer("hw.pagesize").map { "\(Formatting.bytes($0)) pages" }),
            ResourceStat(title: "macOS", systemImage: "apple.logo", value: version,
                         detail: SystemInformation.string("kern.osversion").map { "Build \($0)" }),
            ResourceStat(title: "Uptime", systemImage: "clock", value: SystemInformation.bootTime.map { CPUReadings.uptime(Date().timeIntervalSince($0)) } ?? "Unavailable",
                         detail: SystemInformation.bootTime.map { "since \($0.formatted(.dateTime.day().month(.abbreviated).hour().minute()))" }),
        ]
    }
}

/// One titled group of key/value facts on the System Details page.
private struct SystemInformationCard: View {
    let section: SystemInformationSection
    @Binding var revealsSensitive: Bool

    var body: some View {
        MetricCard(title: section.title, systemImage: section.systemImage, color: .gray) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(section.rows) { row in
                    // Long values (kernel version, display modes) wrap instead of truncating inside the grid.
                    HStack(alignment: .top) {
                        Text(row.key).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        if row.isSensitive && !revealsSensitive {
                            Text(String(repeating: "•", count: 12)).foregroundStyle(.secondary).textSelection(.disabled)
                                .accessibilityLabel("Hidden")
                        } else {
                            Text(row.value).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                        }
                        if row.isSensitive {
                            Button { revealsSensitive.toggle() } label: {
                                Image(systemName: revealsSensitive ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .hoverHint(revealsSensitive ? "Hide serial number and hardware UUID" : "Show serial number and hardware UUID")
                            .accessibilityLabel(revealsSensitive ? "Hide identifiers" : "Show identifiers")
                        }
                    }
                    .font(.callout)
                    if row.id != section.rows.last?.id { Divider().opacity(0.5) }
                }
            }
        }
        .textSelection(.enabled)
    }
}
