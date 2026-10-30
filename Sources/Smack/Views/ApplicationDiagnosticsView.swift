import AppKit
import SwiftUI

@MainActor
final class ApplicationProfileModel: ObservableObject {
    /// Full output kept across all reports. Older reports keep their highlights and release their text first, so
    /// Run All on a large process cannot hold five 16 MB dumps.
    static let retainedOutputBudget = ProfileRunner.outputLimit

    struct PendingRun: Equatable {
        var tools: [ProfileTool]
        var pid: Int32
    }

    @Published var selectedPID: Int32?
    @Published private(set) var reports: [ProfileTool: ProfileReport] = [:]
    @Published private(set) var running: ProfileTool?
    @Published var showFullOutput: Set<ProfileTool> = []
    /// A run that suspends its target, waiting for the user to confirm.
    @Published var pendingRun: PendingRun?
    private var task: Task<Void, Never>?
    /// Bumped on every start and cancel, so a cancelled run that is still winding down cannot touch the state of
    /// the run that replaced it.
    private var generation = 0
    private let runner: @Sendable (ProfileTool, Int32) async -> ProfileReport

    init(runner: @escaping @Sendable (ProfileTool, Int32) async -> ProfileReport = { await ProfileRunner.run($0, pid: $1) }) {
        self.runner = runner
    }

    var isRunning: Bool { running != nil }

    /// Asks first when a tool would suspend the process.
    func request(_ tools: [ProfileTool], pid: Int32) {
        guard !isRunning else { return }
        if tools.contains(where: \.pausesProcess) {
            pendingRun = PendingRun(tools: tools, pid: pid)
        } else {
            run(tools, pid: pid)
        }
    }

    func confirmPendingRun() {
        guard let pending = pendingRun else { return }
        pendingRun = nil
        run(pending.tools, pid: pending.pid)
    }

    /// Runs the tools one after another; `leaks` pauses its target, so two never overlap.
    func run(_ tools: [ProfileTool], pid: Int32) {
        guard !isRunning, let first = tools.first else { return }
        generation += 1
        let current = generation
        let previous = task
        running = first
        task = Task {
            // A cancelled run stops its tool on cancellation; wait for it so two tools never inspect the target at once.
            await previous?.value
            for tool in tools {
                guard !Task.isCancelled, current == generation else { return }
                running = tool
                let report = await runner(tool, pid)
                guard !Task.isCancelled, current == generation else { return }
                store(report)
            }
            if current == generation { running = nil }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        running = nil
        pendingRun = nil
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

    private func store(_ report: ProfileReport) {
        reports[report.tool] = report
        var budget = Self.retainedOutputBudget - report.output.utf8.count
        for tool in reports.keys.sorted(by: { reports[$0]!.finishedAt > reports[$1]!.finishedAt }) where tool != report.tool {
            guard var older = reports[tool], !older.output.isEmpty else { continue }
            let size = older.output.utf8.count
            if size <= budget {
                budget -= size
            } else {
                older.releaseOutput()
                reports[tool] = older
                showFullOutput.remove(tool)
            }
        }
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
                    Button(tool.title) { model.request([tool], pid: process.identity.pid) }
                        .help("\(tool.summary)\n\(tool.commandLine(pid: process.identity.pid))")
                }
                Button("Run All") { model.request(ProfileTool.allCases, pid: process.identity.pid) }
                    .help("Runs every tool in turn; this can take a minute.")
            }
            .controlSize(.small)
            .disabled(model.isRunning || model.pendingRun != nil)
            if let pending = model.pendingRun, pending.pid == process.identity.pid {
                pauseConfirmation(pending, process: process)
            } else {
                Label("Heap and Leaks suspend the process while they scan it. Nothing runs until you press a button.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Shown inside the window, like the kill confirmation, before a tool that freezes the process.
    private func pauseConfirmation(_ pending: ApplicationProfileModel.PendingRun, process: ProcessMetrics) -> some View {
        let pausing = pending.tools.filter(\.pausesProcess)
        let longest = Int(pausing.map(\.timeout).max() ?? 0)
        return VStack(alignment: .leading, spacing: 6) {
            Label("Suspend \(process.name)?", systemImage: "pause.circle.fill").font(.headline).foregroundStyle(.orange)
            Text("\(pausing.map(\.title).joined(separator: " and ")) freeze\(pausing.count == 1 ? "es" : "") the process while scanning its memory, up to \(longest) seconds per tool on a large process. It stops responding meanwhile; audio, calls or transfers in it may break.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Run Anyway") { model.confirmPendingRun() }
                Button("Cancel") { model.pendingRun = nil }.keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.4)))
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
            if report.outputReleased {
                Text("Full output was released to save memory; run the tool again to see it.").font(.caption).foregroundStyle(.secondary)
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
