import SwiftUI
import AppKit

enum ProcessSort: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case disk = "Disk Activity"
    case energy = "Energy Impact"
    case wakeups = "Wakeups"
    case name = "Application"
    var id: String { rawValue }
}

@MainActor
final class ApplicationListViewModel: ObservableObject {
    @Published var query = ""
    @Published var sort = ProcessSort.cpu
    @Published var ascending = false
    @Published var mode = ProcessListMode.flat
    /// Collapsed tree nodes; everything starts expanded.
    @Published var collapsed: Set<String> = []

    func toggleSort(_ newSort: ProcessSort) {
        if sort == newSort {
            ascending.toggle()
        } else {
            sort = newSort
            ascending = newSort == .name
        }
    }
}

@MainActor
final class ProcessDetailViewModel: ObservableObject {
    @Published var filter = ""
}

struct ApplicationListView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var model: ApplicationListViewModel
    private let metricWidth: CGFloat = 130
    private let diskWidth: CGFloat = 160
    private let wakeupsWidth: CGFloat = 100

    init(store: MonitorStore) {
        self.store = store
        model = store.applicationListViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search applications and processes", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                Picker("View", selection: $model.mode) {
                    ForEach(ProcessListMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Flat list or process tree rooted at launchd")
            }
            .padding([.horizontal, .top])
            if let warning = store.processes?.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            HStack(spacing: 12) {
                sortHeader(.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                sortHeader(.cpu).frame(width: metricWidth, alignment: .trailing)
                sortHeader(.memory).frame(width: metricWidth, alignment: .trailing)
                sortHeader(.disk).frame(width: diskWidth, alignment: .trailing)
                sortHeader(.energy).frame(width: metricWidth, alignment: .trailing)
                sortHeader(.wakeups).frame(width: wakeupsWidth, alignment: .trailing)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            Divider()

            if model.mode == .tree {
                ProcessTreeList(store: store, model: model, metricWidth: metricWidth, diskWidth: diskWidth, wakeupsWidth: wakeupsWidth)
            } else {
            List {
                Section("Applications") {
                    ForEach(filtered(store.processes?.applications ?? [])) { application in
                        Button { store.route = .application(application.id) } label: {
                            HStack(spacing: 12) {
                                HStack(spacing: 10) {
                                    ApplicationIcon(application: application, size: 30)
                                    VStack(alignment: .leading) {
                                        Text(application.name).lineLimit(1)
                                        Text("\(application.processes.count) process\(application.processes.count == 1 ? "" : "es")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                metric(Formatting.percent(application.cpuUsage), width: metricWidth)
                                metric(memory(application.memoryBytes), width: metricWidth)
                                metric(disk(application.diskReadRate + application.diskWriteRate), width: diskWidth)
                                metric(energy(application.energyImpact), width: metricWidth)
                                metric(Self.wakeups(application.wakeupsPerSecond), width: wakeupsWidth)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if store.settingsStore.settings.showBackgroundProcesses {
                    Section("Background Processes") {
                        ForEach(filtered(store.processes?.backgroundProcesses ?? [])) { process in
                            Button { store.route = .process(process.id) } label: {
                                HStack(spacing: 12) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "terminal")
                                            .frame(width: 30, height: 30)
                                            .foregroundStyle(.secondary)
                                        Text(process.name).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    metric(Formatting.percent(process.cpuUsage), width: metricWidth)
                                    metric(memory(process.memoryBytes), width: metricWidth)
                                    metric(disk(process.diskReadRate + process.diskWriteRate), width: diskWidth)
                                    metric(energy(process.energyImpact), width: metricWidth)
                                    metric(Self.wakeups(process.wakeupsPerSecond), width: wakeupsWidth)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.plain)
            }
        }
    }

    /// Sandbox builds cannot read other processes' counters, so zero reads as unavailable.
    static func wakeups(_ value: Double) -> String {
        if Capabilities.isSandboxed, value == 0 { return "—" }
        return Formatting.wakeups(value)
    }

    private func sortHeader(_ sort: ProcessSort) -> some View {
        Button { model.toggleSort(sort) } label: {
            HStack(spacing: 4) {
                if model.sort == sort {
                    Image(systemName: model.ascending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                Text(sort.rawValue).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(model.sort == sort ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help("Sort by \(sort.rawValue)")
    }

    private func metric(_ value: String, width: CGFloat) -> some View {
        Text(value)
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    private func energy(_ value: Double?) -> String {
        if Capabilities.isSandboxed, value == nil || value == 0 { return "—" }
        return value?.formatted(.number.precision(.fractionLength(1))) ?? "—"
    }

    private func memory(_ value: UInt64) -> String {
        if Capabilities.isSandboxed, value == 0 { return "—" }
        return Formatting.bytes(value)
    }

    private func disk(_ value: Double) -> String {
        if Capabilities.isSandboxed, value == 0 { return "—" }
        return Formatting.rate(value)
    }

    private func filtered(_ applications: [ApplicationMetrics]) -> [ApplicationMetrics] {
        let result = model.query.isEmpty ? applications : applications.filter { $0.name.localizedCaseInsensitiveContains(model.query) || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(model.query) == true) }
        return result.sorted { lhs, rhs in
            switch model.sort {
            case .cpu: ordered(lhs.cpuUsage, rhs.cpuUsage)
            case .memory: ordered(lhs.memoryBytes, rhs.memoryBytes)
            case .disk: ordered(lhs.diskReadRate + lhs.diskWriteRate, rhs.diskReadRate + rhs.diskWriteRate)
            case .energy: ordered(lhs.energyImpact ?? -.infinity, rhs.energyImpact ?? -.infinity)
            case .wakeups: ordered(lhs.wakeupsPerSecond, rhs.wakeupsPerSecond)
            case .name: ordered(lhs.name.localizedLowercase, rhs.name.localizedLowercase)
            }
        }
    }

    private func filtered(_ processes: [ProcessMetrics]) -> [ProcessMetrics] {
        let result = model.query.isEmpty ? processes : processes.filter { $0.name.localizedCaseInsensitiveContains(model.query) || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(model.query) == true) }
        return result.sorted { lhs, rhs in
            switch model.sort {
            case .cpu: ordered(lhs.cpuUsage, rhs.cpuUsage)
            case .memory: ordered(lhs.memoryBytes, rhs.memoryBytes)
            case .disk: ordered(lhs.diskReadRate + lhs.diskWriteRate, rhs.diskReadRate + rhs.diskWriteRate)
            case .energy: ordered(lhs.energyImpact ?? -.infinity, rhs.energyImpact ?? -.infinity)
            case .wakeups: ordered(lhs.wakeupsPerSecond, rhs.wakeupsPerSecond)
            case .name: ordered(lhs.name.localizedLowercase, rhs.name.localizedLowercase)
            }
        }
    }

    private func ordered<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> Bool {
        model.ascending ? lhs < rhs : lhs > rhs
    }
}

struct ProcessDetailView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var model: ProcessDetailViewModel
    let id: String

    init(store: MonitorStore, id: String) {
        self.store = store
        self.id = id
        model = store.processDetailViewModel
    }
    var body: some View {
        ScrollView {
            if let process = store.process(id: id) {
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: []) {
                    Text(process.name).font(.title2.bold())
                    KeyValueRow(key: "PID", value: String(process.identity.pid))
                    KeyValueRow(key: "Started", value: process.identity.startTime.formatted())
                    KeyValueRow(key: "Parent PID", value: process.parentPID.map(String.init) ?? "Unavailable")
                    KeyValueRow(key: "User", value: process.userName ?? "Permission denied")
                    KeyValueRow(key: "CPU", value: Formatting.percent(process.cpuUsage))
                    KeyValueRow(
                        key: "Physical Footprint",
                        value: Capabilities.isSandboxed && process.memoryBytes == 0
                            ? "Unavailable in App Sandbox"
                            : Formatting.bytes(process.memoryBytes)
                    )
                    KeyValueRow(key: "Network In / Out", value: process.networkThroughput?.formatted ?? "Unavailable")
                    KeyValueRow(key: "Threads", value: String(process.threadCount))
                    KeyValueRow(
                        key: "Interrupt wakeups",
                        value: Capabilities.isSandboxed && process.wakeupsPerSecond == 0
                            ? "Unavailable in App Sandbox"
                            : Formatting.wakeups(process.interruptWakeupsPerSecond)
                    )
                    KeyValueRow(
                        key: "Package idle wakeups",
                        value: Capabilities.isSandboxed && process.wakeupsPerSecond == 0
                            ? "Unavailable in App Sandbox"
                            : Formatting.wakeups(process.packageIdleWakeupsPerSecond)
                    )
                    KeyValueRow(
                        key: "Disk Read / Write",
                        value: Capabilities.isSandboxed && process.diskReadRate == 0 && process.diskWriteRate == 0
                            ? "Unavailable in App Sandbox"
                            : "\(Formatting.rate(process.diskReadRate)) / \(Formatting.rate(process.diskWriteRate))"
                    )
                    if let path = process.executablePath { KeyValueRow(key: "Executable", value: path) }
                    ProvenanceSection(store: store, process: process)
                    Button("Refresh Live Inventory") { store.loadInventory(for: process) }
                    if store.inventoryLoading { ProgressView("Inspecting process…") }
                    if let inventory = store.inventory {
                        if !inventory.warnings.isEmpty {
                            ForEach(inventory.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                        }
                        TextField("Filter files, connections, and libraries", text: $model.filter).textFieldStyle(.roundedBorder)
                        inventorySection("Open Files", count: inventory.files.count) {
                            ForEach(filtered(inventory.files)) { file in
                                HStack {
                                    FileLookupLinks(path: file.path, checksFileOnDisk: false)
                                    Text(file.path).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        inventorySection("Network Connections", count: inventory.connections.count) {
                            ForEach(filtered(inventory.connections)) { connection in
                                HStack {
                                    IPLookupLinks(host: NetworkPortCollector.endpoint(connection.remoteAddress)?.host ?? "")
                                    VStack(alignment: .leading) {
                                        Text("\(connection.protocolName) · \(connection.state)").font(.caption).foregroundStyle(.secondary)
                                        Text("\(connection.localAddress) → \(connection.remoteAddress)").textSelection(.enabled)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        inventorySection("Threads", count: inventory.threads.count) {
                            ForEach(inventory.threads) { thread in Text(thread.name ?? "Thread \(thread.id)") }
                        }
                        inventorySection("Loaded Libraries", count: inventory.libraries.count) {
                            ForEach(filtered(inventory.libraries)) { library in
                                HStack {
                                    FileLookupLinks(path: library.path)
                                    Text(library.path).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }.padding()
            } else { ContentUnavailableView("Process Exited", systemImage: "terminal", description: Text("Its historical metrics remain available until retention expires.")) }
        }.onAppear {
            if let process = store.process(id: id) {
                store.loadProvenance(for: process)
                store.loadInventory(for: process)
            }
        }
    }

    private func inventorySection<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        Section { content() } header: { SectionHeader(title: "\(title) (\(count))") }
    }

    private func filtered(_ values: [OpenFile]) -> [OpenFile] { model.filter.isEmpty ? values : values.filter { $0.path.localizedCaseInsensitiveContains(model.filter) } }
    private func filtered(_ values: [NetworkConnection]) -> [NetworkConnection] { model.filter.isEmpty ? values : values.filter { "\($0.localAddress) \($0.remoteAddress) \($0.protocolName)".localizedCaseInsensitiveContains(model.filter) } }
    private func filtered(_ values: [LoadedLibrary]) -> [LoadedLibrary] { model.filter.isEmpty ? values : values.filter { $0.path.localizedCaseInsensitiveContains(model.filter) } }
}
