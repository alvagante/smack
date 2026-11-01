import AppKit
import SwiftUI

struct AgentSessionsView: View {
    @ObservedObject var model: AgentMonitor
    @ObservedObject var store: MonitorStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Live sessions (\(model.sessions.filter { $0.endedAt == nil }.count))").font(.headline)
                if model.sessions.isEmpty { Text("No running agents detected").foregroundStyle(.secondary) }
                ForEach(model.sessions) { session in
                    AgentSessionRow(session: session, store: store)
                }
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AgentSessionRow: View {
    let session: AgentSession
    @ObservedObject var store: MonitorStore
    @State private var inspection: ProcessMetrics?
    @State private var inspectionTab = ProcessInspectionTab.fileActivity
    @State private var commandLine: String?

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("Started \(session.startedAt.formatted()) · Uptime \(Int((session.endedAt ?? Date()).timeIntervalSince(session.startedAt))) s")
                if let project = session.project {
                    Text(project.directory).textSelection(.enabled)
                    if let branch = project.git?.branch { Text("Branch: " + branch) }
                }
                if let parent = session.parentSession { Text("Parent session: " + parent) }
                Text("CPU \(session.totals.cpu, specifier: "%.1f")% · Memory \(Formatting.bytes(session.totals.memory))")
                Text("Disk ↓ \(Formatting.rate(session.totals.diskRead)) ↑ \(Formatting.rate(session.totals.diskWrite))")
                Text("Network ↓ \(session.totals.networkReceive.map(Formatting.rate) ?? "Unavailable") ↑ \(session.totals.networkSend.map(Formatting.rate) ?? "Unavailable")")
                Text("MCP servers").font(.headline)
                ForEach(session.mcpServers) { child in childRow(child) }
                Text("Helpers").font(.headline)
                ForEach(session.helpers) { child in childRow(child) }
                Text("Recent commands").font(.headline)
                ForEach(session.recentCommands.reversed()) { command in
                    Text("\(command.name) · \(command.executablePath ?? "") · \(Int(command.duration)) s · Exited \(command.exitedAt.formatted())")
                }
                ForEach(session.listeners) { port in
                    Link("\(port.protocolName) \(port.localAddress)", destination: URL(string: "smack://port/\(port.port)")!)
                }
                ForEach(session.remoteHosts) { host in
                    HStack {
                        Text(host.address).textSelection(.enabled)
                        if let separator = host.address.lastIndex(of: ":"),
                           let address = IPLookup.publicAddress(String(host.address[..<separator])) {
                            ForEach(IPLookup.services(for: address)) { service in
                                if let url = service.url(for: address) { Link(service.id, destination: url) }
                            }
                        }
                    }
                }
                if let log = session.log {
                    Text("\(log.path) · \(log.size) bytes · \(log.modifiedAt.formatted())").textSelection(.enabled)
                    Button("Reveal log") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: log.path)]) }
                } else { Text("No log found").foregroundStyle(.secondary) }
                if store.settingsStore.settings.showAgentCommandLines, session.endedAt == nil {
                    Button(commandLine == nil ? "Show command line" : "Hide command line") {
                        if commandLine != nil { commandLine = nil; return }
                        let identity = session.root
                        Task {
                            let value = await Task.detached {
                                guard ProcessInspection.isCurrentUserProcess(identity) else { return nil as String? }
                                let args = ProcessInspection.launchContext(pid: identity.pid)?.arguments.joined(separator: " ")
                                return ProcessInspection.isCurrent(identity) ? args : nil
                            }.value
                            commandLine = value
                        }
                    }
                    if let commandLine { Text(commandLine).textSelection(.enabled) }
                }
                if let process = store.process(id: session.root.id) {
                    Button("Capture file activity") { inspectionTab = .fileActivity; inspection = process }
                }
            }.font(.caption).padding(.vertical, 6)
        } label: {
            Text("\(AgentDefinition.catalog.first { $0.id == session.agentID }?.name ?? session.agentID) · \(session.project?.name ?? "Unknown project") · PID \(session.root.pid)\(session.endedAt == nil ? "" : " · Ended")")
        }
        .sheet(item: $inspection) { process in
            VStack {
                ProcessInspectionView(store: store, process: process, tab: inspectionTab)
                Button("Close") { inspection = nil }.padding()
            }.frame(width: 800, height: 550)
        }
    }

    private func childRow(_ child: AgentChild) -> some View {
        HStack {
            Text("\(child.name) · \(child.classification) · \(child.executablePath ?? "")")
            if let process = store.process(id: child.id) {
                Button("File activity") { inspectionTab = .fileActivity; inspection = process }
            }
        }
    }
}
