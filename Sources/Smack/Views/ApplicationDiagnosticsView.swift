import AppKit
import SwiftUI

@MainActor
final class ApplicationProfileModel: ObservableObject {
    @Published var selectedPID: Int32?
    @Published private(set) var reports: [ProfileTool: ProfileReport] = [:]
    @Published private(set) var running: ProfileTool?
    @Published var showFullOutput: Set<ProfileTool> = []
    private var task: Task<Void, Never>?

    var isRunning: Bool { running != nil }

    /// Runs the tools one after another; `leaks` pauses its target, so two never overlap.
    func run(_ tools: [ProfileTool], pid: Int32) {
        guard !isRunning else { return }
        task = Task {
            for tool in tools {
                running = tool
                let report = await ProfileRunner.run(tool, pid: pid)
                guard !Task.isCancelled else { break }
                reports[tool] = report
            }
            running = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        running = nil
    }

    func select(_ pid: Int32?) {
        guard pid != selectedPID else { return }
        reset()
        selectedPID = pid
    }

    func reset() {
        cancel()
        reports = [:]
        showFullOutput = []
        selectedPID = nil
    }
}

/// On-demand profiling of one process of the application with the macOS developer command-line tools.
struct ApplicationDiagnosticsTab: View {
    let app: ApplicationMetrics
    @ObservedObject var model: ApplicationProfileModel

    private var processes: [ProcessMetrics] { app.processes.sorted { $0.memoryBytes > $1.memoryBytes } }

    private var selected: ProcessMetrics? {
        if let pid = model.selectedPID, let match = app.processes.first(where: { $0.identity.pid == pid }) { return match }
        return app.processes.first { $0.executablePath == app.executablePath } ?? processes.first
    }

    var body: some View {
        if !Capabilities.supportsProfiling {
            Text("Profiling runs macOS command-line tools, which the App Store build cannot launch.").foregroundStyle(.secondary)
        } else if let process = selected {
            VStack(alignment: .leading, spacing: 10) {
                controls(process)
                ForEach(ProfileTool.allCases) { tool in
                    if let report = model.reports[tool], report.pid == process.identity.pid {
                        ProfileReportCard(report: report, showFull: binding(tool))
                    }
                }
            }
        } else {
            Text("No process to inspect.").foregroundStyle(.secondary)
        }
    }

    private func binding(_ tool: ProfileTool) -> Binding<Bool> {
        Binding(
            get: { model.showFullOutput.contains(tool) },
            set: { if $0 { model.showFullOutput.insert(tool) } else { model.showFullOutput.remove(tool) } }
        )
    }

    private func controls(_ process: ProcessMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Process").font(.caption).foregroundStyle(.secondary)
                Picker("Process", selection: Binding(get: { process.identity.pid }, set: { model.select($0) })) {
                    ForEach(processes) { Text("\($0.name) (\($0.identity.pid)) · \(Formatting.bytes($0.memoryBytes))").tag($0.identity.pid) }
                }
                .labelsHidden().fixedSize().disabled(model.isRunning)
                Spacer()
                if let running = model.running {
                    ProgressView().controlSize(.small)
                    Text("Running \(running.title)…").font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { model.cancel() }.controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                ForEach(ProfileTool.allCases) { tool in
                    Button(tool.title) { model.run([tool], pid: process.identity.pid) }
                        .help("\(tool.summary)\n\(tool.commandLine(pid: process.identity.pid))")
                }
                Button("Run All") { model.run(ProfileTool.allCases, pid: process.identity.pid) }
                    .help("Runs every tool in turn; this can take a minute.")
            }
            .controlSize(.small)
            .disabled(model.isRunning)
            Label("Heap and Leaks suspend the process while they scan it. Nothing runs until you press a button.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ProfileReportCard: View {
    let report: ProfileReport
    @Binding var showFull: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(report.tool.title).font(.headline)
                Text(report.tool.commandLine(pid: report.pid)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(String(format: "%.1fs", report.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if let failure = report.failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            ForEach(report.highlights) { highlight in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(highlight.severity)).foregroundStyle(color(highlight.severity)).frame(width: 16)
                    Text(highlight.label).fontWeight(.medium).frame(width: 190, alignment: .leading).lineLimit(2)
                    Text(highlight.value).foregroundStyle(highlight.severity == .normal ? Color.primary : color(highlight.severity)).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.callout)
            }
            if report.failure == nil, report.highlights.isEmpty {
                Text("Nothing stood out; see the full output.").font(.callout).foregroundStyle(.secondary)
            }
            if report.truncated {
                Text("Output was cut at \(ProfileRunner.outputLimit / 1_048_576) MB.").font(.caption).foregroundStyle(.secondary)
            }
            if !report.output.isEmpty {
                HStack {
                    Toggle(showFull ? "Hide full output" : "Show full output", isOn: $showFull).toggleStyle(.button).controlSize(.small)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.output, forType: .string)
                    }
                    .controlSize(.small)
                    Text("\(report.output.utf8.count.formatted()) bytes").font(.caption).foregroundStyle(.secondary)
                }
                if showFull {
                    ProfileOutputView(id: report.id, text: report.output)
                        .frame(height: 360)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3)))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func icon(_ severity: ProfileSeverity) -> String {
        switch severity {
        case .normal: "chart.bar.fill"
        case .notable: "exclamationmark.circle.fill"
        case .alert: "exclamationmark.triangle.fill"
        }
    }

    private func color(_ severity: ProfileSeverity) -> Color {
        switch severity {
        case .normal: .accentColor
        case .notable: .orange
        case .alert: .red
        }
    }
}

/// An NSTextView copes with multi-megabyte dumps that would stall a SwiftUI Text.
private struct ProfileOutputView: NSViewRepresentable {
    let id: UUID
    let text: String

    final class Coordinator { var shown: UUID? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.drawsBackground = false
            view.isHorizontallyResizable = true
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        scroll.hasHorizontalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.shown != id, let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.shown = id
        view.string = text
        view.scrollToBeginningOfDocument(nil)
    }
}
