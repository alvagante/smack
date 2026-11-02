import SwiftUI

struct SummaryView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject private var settingsStore: SettingsStore

    init(store: MonitorStore) {
        self.store = store
        settingsStore = store.settingsStore
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                macOverview
                if store.system == nil {
                    ProgressView("Collecting system metrics…")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                SummarySection("Performance", subtitle: "Live usage and recent trends") {
                    performance
                }
                SummarySection("Health") {
                    health
                }
                SummarySection("Activity") {
                    ActivityDiffCard(store: store)
                    activity
                }
                if !Capabilities.isSandboxed && SummaryPage.allCases.contains(where: settingsStore.settings.shows) {
                    SummarySection("Environment") {
                        environment
                    }
                }
            }
            .frame(maxWidth: 1000)
            .padding(MonitorStyle.inset)
            .frame(maxWidth: .infinity)
        }
    }

    private var macOverview: some View {
        Button { store.route = .systemDetails } label: {
            HStack(spacing: 16) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(SystemInformation.modelName ?? SystemInformation.modelIdentifier)
                        .font(MonitorStyle.title)
                    Text([SystemInformation.processorName, Formatting.bytes(ProcessInfo.processInfo.physicalMemory) + " memory"].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(16)
            .monitorSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("View system details")
    }

    private var performance: some View {
        VStack(spacing: 0) {
            metric(.cpu, value: store.system.map { $0.cpu.hasUsage ? Formatting.percent($0.cpu.totalUsage) : "Measuring…" } ?? "Collecting…",
                   detail: store.system.map { "\($0.cpu.coreUsage.count) \($0.cpu.coreUsage.count == 1 ? "core" : "cores")" } ?? "Processor usage",
                   series: [SparklineSeries(values: store.recentMetrics.points.map(\.cpuUsage), color: .blue)], domain: 0...100)
            metric(.gpu, value: store.system?.gpu.utilizationPercent.map(Formatting.percent) ?? "Unavailable",
                   detail: store.system?.gpuName ?? "Graphics usage",
                   series: [SparklineSeries(values: store.recentMetrics.points.compactMap(\.gpuUsage), color: .indigo)], domain: 0...100)
            metric(.memory, value: store.system.map { Formatting.bytes($0.memory.usedBytes) } ?? "Collecting…",
                   detail: store.system.map { "of \(Formatting.bytes($0.memory.totalBytes)) · \(Formatting.pressure($0.memory.pressure)) pressure" } ?? "Memory usage",
                   series: [SparklineSeries(values: store.recentMetrics.points.map(\.memoryUsage), color: .purple)], domain: 0...100)
            metric(.network, value: store.system.map { "↓ \(Formatting.rate($0.receiveRate))   ↑ \(Formatting.rate($0.sendRate))" } ?? "Collecting…",
                   detail: "Received / sent",
                   series: [SparklineSeries(values: store.recentMetrics.points.map(\.receiveRate), color: .cyan),
                            SparklineSeries(values: store.recentMetrics.points.map(\.sendRate), color: .mint)])
            metric(.disk, value: store.system.map { "R \(Formatting.rate($0.diskReadRate))   W \(Formatting.rate($0.diskWriteRate))" } ?? "Collecting…",
                   detail: "Read / written",
                   series: [SparklineSeries(values: store.recentMetrics.points.map(\.diskReadRate), color: .orange),
                            SparklineSeries(values: store.recentMetrics.points.map(\.diskWriteRate), color: .pink)])
        }
        .monitorSurface()
    }

    private func metric(_ resource: ResourceKind, value: String, detail: String, series: [SparklineSeries], domain: ClosedRange<Double>? = nil) -> some View {
        let route = AppRoute.resource(resource)
        return Button { store.route = route } label: {
            HStack(spacing: 16) {
                ResourceIcon(systemImage: route.systemImage, color: route.tint, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(route.title).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        Sparkline(series: series, domain: domain, minHeight: 32, maxHeight: 32)
                            .frame(width: 120)
                            .accessibilityHidden(true)
                        Text(value).font(.body.weight(.medium)).monospacedDigit()
                            .frame(width: 210, alignment: .trailing)
                    }
                    Text(value).font(.body.weight(.medium)).monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
                .layoutPriority(1)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(minHeight: 68)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(MonitorStyle.separator.opacity(0.5)).frame(height: 0.5).padding(.leading, 60) }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var health: some View {
        VStack(spacing: 0) {
            SummaryNavigationRow(route: .resource(.thermal), value: store.system?.thermalCondition.rawValue.capitalized ?? "Collecting…", detail: "Temperature sensors and fans") { store.route = .resource(.thermal) }
            if let volumes = store.system?.volumes, !volumes.isEmpty {
                let total = volumes.reduce(UInt64(0)) { $0 &+ $1.totalBytes }
                let used = volumes.reduce(UInt64(0)) { $0 &+ $1.usedBytes }
                SummaryNavigationRow(route: .resource(.storage), value: "\(Formatting.bytes(used)) of \(Formatting.bytes(total))", detail: "Used across mounted volumes") { store.route = .resource(.storage) }
            }
            if let battery = store.system?.battery, battery.isPresent {
                SummaryNavigationRow(route: .resource(.battery), value: battery.chargePercent.map { "\(Int($0))%" } ?? "Unavailable",
                                     detail: battery.isCharging ? "Charging" : (battery.isOnBattery == false ? "Connected to power" : "On battery")) { store.route = .resource(.battery) }
            }
            if Capabilities.supportsPostureChecks {
                securityRow
            }
            BaselineSummaryTile(model: store.baselines, settingsStore: settingsStore) { store.route = .baseline }
        }
        .monitorSurface()
    }

    private var securityRow: some View {
        let checks = store.posture?.checks ?? []
        let problems = checks.filter { [.warn, .fail].contains($0.status) }.count
        let unknown = checks.filter { $0.status == .unknown }.count
        let value = store.posture == nil ? "Awaiting checks" : (problems == 0 ? (unknown == checks.count ? "Unverified" : "No findings") : "\(problems) findings")
        return SummaryNavigationRow(route: .security, value: value,
                                    detail: store.posture == nil ? "System security checks" : "\(checks.count) checks · \(unknown) unverified") { store.route = .security }
    }

    private var activity: some View {
        VStack(spacing: 0) {
            SummaryNavigationRow(route: .applications, value: store.processes.map { "\($0.applications.count) running" } ?? "Collecting…",
                                 detail: store.processes?.applications.max(by: { $0.cpuUsage < $1.cpuUsage }).map { "Most active: \($0.name) · \(Formatting.percent($0.cpuUsage)) CPU" } ?? "Applications and processes") { store.route = .applications }
            if Capabilities.supportsNetworkPortInspection {
                SummaryNavigationRow(route: .networkPorts, value: store.networkPorts.map { "\($0.ports.count) listening" } ?? "Collecting…",
                                     detail: store.networkPorts.map { "\($0.totalConnectionCount) total connections" } ?? "Listening ports and connections") { store.route = .networkPorts }
            }
            if Capabilities.supportsStartupItems {
                StartupSummaryCard(model: store.startupItemsModel) { store.route = .startupItems }
            }
            SummaryNavigationRow(route: .history, value: "Explore trends", detail: "System and per-program history") { store.route = .history }
        }
        .monitorSurface()
    }

    private var environment: some View {
        let settings = settingsStore.settings
        return VStack(spacing: 0) {
            if settings.shows(.devServers) {
                SummaryNavigationRow(route: .devServers, value: store.devServers.map { "\($0.count) servers" } ?? "Awaiting collection", detail: "Projects, listeners and containers") { store.route = .devServers }
            }
            if settings.shows(.docker) { DockerSummaryTile(model: store.dockerModel) { store.route = .docker } }
            if settings.shows(.homebrew) { HomebrewSummaryTile(model: store.homebrewModel) { store.route = .homebrew } }
            if settings.shows(.devEnvironments) { DevEnvironmentSummaryTile(model: store.devEnvironmentModel) { store.route = .devEnvironments } }
            if settings.shows(.agents) { AgentsSummaryTile(model: store.agentsModel) { store.route = .agents } }
            if settings.shows(.userHome) { UserHomeSummaryTile { store.route = .userHome } }
            if settings.shows(.installedApps) { InstalledAppsSummaryTile(model: store.installedAppsModel) { store.route = .installedApps } }
        }
        .monitorSurface()
    }
}

private struct SummarySection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 4)
            content
        }
    }
}

/// Summary links share the same layout as a macOS grouped settings row.
struct SummaryNavigationRow: View {
    let route: AppRoute
    let value: String
    var detail: String? = nil
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                ResourceIcon(systemImage: route.systemImage, color: route.tint, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(route.title).font(.body.weight(.medium))
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 12)
                Text(value).font(.body).foregroundStyle(.secondary).monospacedDigit()
                    .multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(MonitorStyle.separator.opacity(0.5)).frame(height: 0.5).padding(.leading, 56) }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

struct BaselineSummaryTile: View {
    @ObservedObject var model: BaselineModel
    @ObservedObject var settingsStore: SettingsStore
    let open: () -> Void

    var body: some View {
        let settings = settingsStore.settings
        let golden = settings.goldenBaselineID.flatMap { id in model.rows.first { $0.0.lastPathComponent == id }?.1 }
        SummaryNavigationRow(route: .baseline, value: model.rows.isEmpty ? "None saved" : "\(model.rows.count) saved",
                             detail: golden.map { "Golden: \($0.name.isEmpty ? "Unnamed" : $0.name)" + (settings.scheduledDriftCheck ? " · daily check" : "") } ?? "Capture configuration and detect drift", open: open)
            .task { if model.rows.isEmpty { await model.refresh() } }
    }
}
