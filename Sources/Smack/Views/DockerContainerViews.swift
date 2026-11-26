import AppKit
import SwiftUI

/// Container pieces shared by the Docker page and a Project's Docker tab.

extension DockerContainerAction {
    /// The actions a container's current state supports, in toolbar order.
    static func available(for container: DockerContainer) -> [DockerContainerAction] {
        [.start, .stop, .restart, container.state == "paused" ? .unpause : .pause].filter { $0.isAvailable(for: container) }
    }
}

/// One container: state, Confirmed Action buttons, inspect, live statistics and published ports.
struct DockerContainerRow: View {
    @ObservedObject var model: DockerMonitor
    let container: DockerContainer
    let snapshot: DockerSnapshot?
    var act: (DockerContainerAction) -> Void
    var inspect: () -> Void

    var body: some View {
        let stats = snapshot?.stats.first { $0.ID == container.id || container.id.hasPrefix($0.ID) }
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(container.isRunning ? .green : .secondary).frame(width: 7, height: 7)
                Text(container.displayName).font(.headline)
                Spacer()
                Text(container.status).font(.caption).foregroundStyle(.secondary)
                ForEach(DockerContainerAction.available(for: container), id: \.self) { action in
                    Button { act(action) } label: {
                        Image(systemName: action.systemImage).foregroundStyle(action.color).frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .help(action.title)
                    .accessibilityLabel("\(action.title) \(container.displayName)")
                    .disabled(model.busy)
                }
                Button(action: inspect) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.blue).frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Inspect")
                .accessibilityLabel("Inspect \(container.displayName)")
            }
            Text("\(container.image) · \(container.id.prefix(12))").font(.caption).foregroundStyle(.secondary)
            if let stats, container.isRunning {
                Text("CPU \(stats.CPUPerc) · Memory \(stats.MemUsage) (\(stats.MemPerc)) · PIDs \(stats.PIDs) · Network I/O \(stats.NetIO) · Block I/O \(stats.BlockIO)")
                    .font(.callout).monospacedDigit()
            } else if container.isRunning {
                Text(model.liveStats ? "Resource statistics unavailable" : "Resource statistics: Off")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DockerPortPairs(ports: container.ports).font(.caption.monospaced())
        }.textSelection(.enabled)
    }
}

/// The running or finished container command, its output and a way to dismiss it.
struct DockerOperationResult: View {
    @ObservedObject var model: DockerMonitor

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Label(model.busy ? "Running Docker command…" : model.operationFailed ? "Command failed" : "Completed",
                          systemImage: model.operationFailed ? "exclamationmark.triangle" : "terminal")
                        .foregroundStyle(model.operationFailed ? Color.red : Color.primary)
                    Spacer()
                    if !model.busy { Button("Close") { model.dismissOperation() } }
                }
                if let operation = model.operation {
                    Text("docker " + operation.arguments.joined(separator: " ")).font(.caption.monospaced())
                }
                if !model.operationOutput.isEmpty {
                    Text(model.operationOutput).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Copy output") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.operationOutput, forType: .string)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// The Confirmed Action dialog for a container command: the exact command and its target, then run it.
    func dockerContainerConfirmation(model: DockerMonitor, pending: Binding<DockerContainerOperation?>) -> some View {
        confirmationDialog(pending.wrappedValue?.title ?? "Docker", isPresented: Binding(
            get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }
        ), titleVisibility: .visible) {
            if let value = pending.wrappedValue {
                Button(value.action.title) {
                    pending.wrappedValue = nil
                    Task { await model.perform(value) }
                }
            }
            Button("Cancel", role: .cancel) { pending.wrappedValue = nil }
        } message: {
            if let value = pending.wrappedValue {
                Text("docker \(value.arguments.joined(separator: " "))\nApplies to \(value.container.displayName) in the selected Docker engine.")
            }
        }
    }
}
