import SwiftUI
import AppKit

enum ProcessSort: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case disk = "Disk"
    case name = "Name"
    var id: String { rawValue }
}

@MainActor
final class ApplicationListViewModel: ObservableObject {
    @Published var query = ""
    @Published var sort = ProcessSort.cpu
}

@MainActor
final class ProcessDetailViewModel: ObservableObject {
    @Published var filter = ""
}

struct ApplicationListView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var model: ApplicationListViewModel

    init(store: MonitorStore) {
        self.store = store
        model = store.applicationListViewModel
    }

    var body: some View {
        VStack {
            HStack {
                TextField("Search applications and processes", text: $model.query).textFieldStyle(.roundedBorder)
                Picker("Sort", selection: $model.sort) { ForEach(ProcessSort.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 100)
            }.padding([.horizontal, .top])
            List {
                Section("Applications") {
                    ForEach(filtered(store.processes?.applications ?? [])) { application in
                        Button { store.route = .application(application.id) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(application.name)
                                    Text("\(application.processes.count) process\(application.processes.count == 1 ? "" : "es")").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(metric(application)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                if store.settingsStore.settings.showBackgroundProcesses {
                    Section("Background Processes") {
                        ForEach(filtered(store.processes?.backgroundProcesses ?? [])) { process in
                            Button { store.route = .process(process.id) } label: {
                                HStack { Text(process.name); Spacer(); Text(metric(process)).monospacedDigit().foregroundStyle(.secondary) }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.listStyle(.plain)
        }
    }

    private func filtered(_ applications: [ApplicationMetrics]) -> [ApplicationMetrics] {
        let result = model.query.isEmpty ? applications : applications.filter { $0.name.localizedCaseInsensitiveContains(model.query) || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(model.query) == true) }
        return result.sorted { lhs, rhs in
            switch model.sort {
            case .cpu: lhs.cpuUsage > rhs.cpuUsage
            case .memory: lhs.memoryBytes > rhs.memoryBytes
            case .disk: lhs.diskReadRate + lhs.diskWriteRate > rhs.diskReadRate + rhs.diskWriteRate
            case .name: lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func filtered(_ processes: [ProcessMetrics]) -> [ProcessMetrics] {
        let result = model.query.isEmpty ? processes : processes.filter { $0.name.localizedCaseInsensitiveContains(model.query) || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(model.query) == true) }
        return result.sorted { lhs, rhs in
            switch model.sort {
            case .cpu: lhs.cpuUsage > rhs.cpuUsage
            case .memory: lhs.memoryBytes > rhs.memoryBytes
            case .disk: lhs.diskReadRate + lhs.diskWriteRate > rhs.diskReadRate + rhs.diskWriteRate
            case .name: lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func metric(_ app: ApplicationMetrics) -> String {
        switch model.sort {
        case .cpu: Formatting.percent(app.cpuUsage)
        case .memory: Formatting.bytes(app.memoryBytes)
        case .disk: Formatting.rate(app.diskReadRate + app.diskWriteRate)
        case .name: Formatting.percent(app.cpuUsage)
        }
    }

    private func metric(_ process: ProcessMetrics) -> String {
        switch model.sort {
        case .cpu: Formatting.percent(process.cpuUsage)
        case .memory: Formatting.bytes(process.memoryBytes)
        case .disk: Formatting.rate(process.diskReadRate + process.diskWriteRate)
        case .name: Formatting.percent(process.cpuUsage)
        }
    }
}

struct ApplicationDetailView: View {
    @ObservedObject var store: MonitorStore
    let id: String
    var body: some View {
        ScrollView {
            if let app = store.application(id: id) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(app.name).font(.title2.bold())
                    KeyValueRow(key: "Bundle", value: app.bundleIdentifier ?? "Unavailable")
                    KeyValueRow(key: "CPU", value: Formatting.percent(app.cpuUsage))
                    KeyValueRow(key: "Memory", value: Formatting.bytes(app.memoryBytes))
                    KeyValueRow(key: "Disk Read / Write", value: "\(Formatting.rate(app.diskReadRate)) / \(Formatting.rate(app.diskWriteRate))")
                    KeyValueRow(key: "Energy Impact", value: app.energyImpact.map { $0.formatted() } ?? "Unavailable")
                    if let path = app.executablePath {
                        KeyValueRow(key: "Executable", value: path)
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    }
                    SectionHeader(title: "Processes")
                    ForEach(app.processes) { process in
                        Button { store.route = .process(process.id) } label: {
                            HStack { Text("\(process.name) (\(process.identity.pid))"); Spacer(); Text(Formatting.percent(process.cpuUsage)).monospacedDigit(); Image(systemName: "chevron.right") }
                        }.buttonStyle(.plain)
                    }
                }.padding()
            } else { ContentUnavailableView("Application Exited", systemImage: "app.dashed", description: Text("Its metrics remain in Historical Data until retention expires.")) }
        }
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
                    KeyValueRow(key: "Physical Footprint", value: Formatting.bytes(process.memoryBytes))
                    KeyValueRow(key: "Threads", value: String(process.threadCount))
                    KeyValueRow(key: "Disk Read / Write", value: "\(Formatting.rate(process.diskReadRate)) / \(Formatting.rate(process.diskWriteRate))")
                    if let path = process.executablePath { KeyValueRow(key: "Executable", value: path) }
                    Button("Refresh Live Inventory") { store.loadInventory(for: process) }
                    if store.inventoryLoading { ProgressView("Inspecting process…") }
                    if let inventory = store.inventory {
                        if !inventory.warnings.isEmpty {
                            ForEach(inventory.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                        }
                        TextField("Filter files, connections, and libraries", text: $model.filter).textFieldStyle(.roundedBorder)
                        inventorySection("Open Files", count: inventory.files.count) {
                            ForEach(filtered(inventory.files)) { file in Text(file.path).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                        inventorySection("Network Connections", count: inventory.connections.count) {
                            ForEach(filtered(inventory.connections)) { connection in
                                VStack(alignment: .leading) {
                                    Text("\(connection.protocolName) · \(connection.state)").font(.caption).foregroundStyle(.secondary)
                                    Text("\(connection.localAddress) → \(connection.remoteAddress)").textSelection(.enabled)
                                }
                            }
                        }
                        inventorySection("Threads", count: inventory.threads.count) {
                            ForEach(inventory.threads) { thread in Text(thread.name ?? "Thread \(thread.id)") }
                        }
                        inventorySection("Loaded Libraries", count: inventory.libraries.count) {
                            ForEach(filtered(inventory.libraries)) { library in Text(library.path).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                    }
                }.padding()
            } else { ContentUnavailableView("Process Exited", systemImage: "terminal", description: Text("Its historical metrics remain available until retention expires.")) }
        }.onAppear { if let process = store.process(id: id) { store.loadInventory(for: process) } }
    }

    private func inventorySection<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        Section { content() } header: { SectionHeader(title: "\(title) (\(count))") }
    }

    private func filtered(_ values: [OpenFile]) -> [OpenFile] { model.filter.isEmpty ? values : values.filter { $0.path.localizedCaseInsensitiveContains(model.filter) } }
    private func filtered(_ values: [NetworkConnection]) -> [NetworkConnection] { model.filter.isEmpty ? values : values.filter { "\($0.localAddress) \($0.remoteAddress) \($0.protocolName)".localizedCaseInsensitiveContains(model.filter) } }
    private func filtered(_ values: [LoadedLibrary]) -> [LoadedLibrary] { model.filter.isEmpty ? values : values.filter { $0.path.localizedCaseInsensitiveContains(model.filter) } }
}
