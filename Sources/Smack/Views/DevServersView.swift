import SwiftUI

enum ProjectApplications {
    static let terminals = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "com.github.wez.wezterm", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty"]
    static let editors = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "com.sublimetext.4", "com.panic.Nova", "com.apple.dt.Xcode", "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm", "com.jetbrains.goland", "com.jetbrains.rustrover", "com.jetbrains.CLion",
        "com.jetbrains.RubyMine", "com.jetbrains.PhpStorm", "com.jetbrains.rider", "com.jetbrains.datagrip"]

    @MainActor static func installed(_ ids: [String]) -> [(id: String, name: String)] {
        ids.compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return (id, FileManager.default.displayName(atPath: url.path))
        }
    }

    @MainActor static func open(_ path: String, with bundle: String, store: MonitorStore) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            store.errorMessage = "The configured application is not installed."
            return
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app,
            configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Task { @MainActor in store.errorMessage = error.localizedDescription } }
            }
    }
}

struct DevServersView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject private var settings: SettingsStore
    @State private var stopping: DevServer?
    @State private var containerOperation: DockerContainerOperation?

    init(store: MonitorStore) { self.store = store; settings = store.settingsStore }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                ResourceTitle(title: "Dev servers", systemImage: "server.rack", color: .cyan)
                Spacer()
                Toggle("Show system listeners", isOn: Binding(
                    get: { settings.settings.devServersShowSystem },
                    set: { value in settings.update { $0.devServersShowSystem = value }; store.refreshDevServers() }))
                RefreshButton(isLoading: store.networkPortsLoading) { store.loadNetworkPorts() }
            }.padding()
            if let port = store.navigationFilters.port {
                HStack {
                    Text("Port \(port)")
                    Button("Clear filter") { store.navigate(to: URL(string: "smack://devservers")!) }
                }.padding(.horizontal)
            }
            if let warning = store.networkPorts?.warning { Text(warning).font(.caption).padding(.horizontal) }
            List {
                ForEach((store.devServers ?? []).filter { row in
                    store.navigationFilters.port == nil || row.ports.contains { $0.port == store.navigationFilters.port }
                }) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.project?.name ?? row.container?.name ?? "Other listeners").font(.headline)
                        Text("\(row.processName) · PID \(row.process.pid)").font(.caption)
                        if let project = row.project {
                            Text(project.directory).textSelection(.enabled)
                            Text([project.root, project.kind?.rawValue, project.git?.branch ?? project.git?.commit]
                                .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        if let container = row.container {
                            Text([container.name, container.composeProject, container.composeWorkingDirectory]
                                .compactMap { $0 }.joined(separator: " · ")).font(.caption)
                        }
                        ForEach(row.ports) { port in
                            HStack {
                                Text("\(port.localAddress) · \(port.scope.rawValue)").monospaced()
                                if let url = port.browserURL { Link("Open", destination: url) }
                                Menu("Copy") {
                                    if let url = port.browserURL { Button("URL") { copy(url.absoluteString) } }
                                    Button("Host:port") { copy(port.localAddress) }
                                    if let path = row.project?.root ?? row.project?.directory { Button("Project path") { copy(path) } }
                                    Button("Summary") { copy("\(row.project?.name ?? row.processName): \(port.localAddress)") }
                                }.fixedSize()
                            }
                        }
                        HStack {
                            if let path = row.project?.root ?? row.project?.directory {
                                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                Button("Terminal") { ProjectApplications.open(path, with: settings.settings.terminalApp, store: store) }
                                if let editor = settings.settings.editorApp {
                                    Button("Editor") { ProjectApplications.open(path, with: editor, store: store) }
                                }
                            }
                            if let binding = row.container,
                               let container = store.dockerModel.snapshot?.containers?.first(where: { $0.id == binding.containerID }) {
                                ForEach(DockerContainerAction.allCases.filter { $0.isAvailable(for: container) }, id: \.self) { action in
                                    Button(action.title) { containerOperation = DockerContainerOperation(action: action, container: container) }
                                }
                            } else if row.container == nil, Capabilities.supportsProcessTermination,
                                      row.process.startTime != .distantPast {
                                Button("Stop", role: .destructive) { stopping = row }
                            }
                        }
                    }.padding(.vertical, 6)
                }
            }.listStyle(.plain)
            if store.devServers?.isEmpty == true { Text("No dev servers reported.").padding() }
        }
        .onAppear { store.refreshDevServers(); if store.networkPorts == nil { store.loadNetworkPorts() } }
        .confirmationDialog("Stop \(stopping?.processName ?? "server")?", isPresented: Binding(
            get: { stopping != nil }, set: { if !$0 { stopping = nil } }), titleVisibility: .visible) {
                if let row = stopping {
                    Button("Stop", role: .destructive) {
                        let current = (store.processes?.applications.flatMap(\.processes) ?? []) + (store.processes?.backgroundProcesses ?? [])
                        let result = ProcessTerminator.terminate(targets: [row.process], current: current.map(\.identity),
                            force: false, requestQuit: { _ in nil })
                        store.errorMessage = result.summary
                        stopping = nil
                    }
                }
        }
        .confirmationDialog(containerOperation?.title ?? "Container action", isPresented: Binding(
            get: { containerOperation != nil }, set: { if !$0 { containerOperation = nil } }), titleVisibility: .visible) {
                if let operation = containerOperation {
                    Button(operation.action.title, role: .destructive) {
                        containerOperation = nil
                        Task {
                            await store.dockerModel.perform(operation)
                            store.errorMessage = store.dockerModel.operationOutput
                            store.refreshDevServers()
                        }
                    }
                }
        }
    }

    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}
