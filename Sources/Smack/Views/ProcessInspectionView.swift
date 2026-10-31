import AppKit
import SwiftUI

/// Used by both application details (one selected process) and individual process details.
struct ProcessInspectionView: View {
    @ObservedObject var store: MonitorStore
    let process: ProcessMetrics
    let tab: ProcessInspectionTab
    @State private var fields: [InspectionField] = []
    @State private var arguments: [String] = []
    @State private var environment: [InspectionField] = []
    @State private var output = ""
    @State private var message: String?
    @State private var loading = false
    @State private var refresh = 0
    @State private var filter = ""
    @State private var severity = "All"
    @State private var live = false
    @State private var capture = false
    @State private var crashes: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !Capabilities.supportsProfiling {
                Text("This inspection is unavailable in the App Store build.").foregroundStyle(.secondary)
            } else {
                controls
                if loading { ProgressView(tab == .fileActivity ? "Capturing five seconds of file activity…" : "Inspecting process…").controlSize(.small) }
                if let message { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                content
            }
        }
        .task(id: "\(process.id)#\(tab.rawValue)#\(refresh)#\(severity)#\(live)#\(capture)") {
            guard Capabilities.supportsProfiling else { return }
            await load()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tab == .logs || tab == .fileActivity {
                TextField("Filter output", text: $filter).textFieldStyle(.roundedBorder)
            }
            HStack {
                if tab == .logs {
                    Picker("Severity", selection: $severity) {
                        Text("All levels").tag("All")
                        Text("Errors and faults").tag("Errors")
                    }.labelsHidden().fixedSize()
                    Toggle("Live", isOn: $live).toggleStyle(.button)
                }
                Spacer()
                if tab == .fileActivity {
                    Button("Capture 5 Seconds") { capture = true; refresh += 1 }.disabled(loading)
                } else {
                    Button("Refresh") { refresh += 1 }.disabled(loading && !live)
                }
            }
        }.controlSize(.small)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .launchContext:
            ForEach(fields) { InspectionValueRow(key: $0.label, value: $0.value) }
            Text("Arguments").font(.headline)
            Text("Credential options are masked; positional arguments may contain sensitive data.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(arguments.enumerated()), id: \.offset) { index, value in
                InspectionValueRow(key: "argv[\(index)]", value: value)
            }
            Text("Environment (values hidden)").font(.headline)
            ForEach(environment) { InspectionValueRow(key: $0.label, value: $0.value) }
        case .security:
            Text("Signature and entitlements describe the executable on disk.").font(.caption).foregroundStyle(.secondary)
            ForEach(fields) { InspectionValueRow(key: $0.label, value: $0.value) }
        case .startup:
            ProcessStartupInspection(store: store, process: process, model: store.startupItemsModel)
        case .logs:
            Text("Unified logs from the last five minutes, limited to this process lifetime. Live refreshes every three seconds.").font(.caption).foregroundStyle(.secondary)
            outputView
            Text("Crash Reports").font(.headline)
            if crashes.isEmpty { Text("No matching report filenames in accessible DiagnosticReports folders.").foregroundStyle(.secondary) }
            ForEach(crashes, id: \.path) { url in
                Button(url.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link)
            }
        case .fileActivity:
            Text("Captures filesystem calls for this process using the superuser helper. Includes reads, writes, renames and deletions observed during the capture.").font(.caption).foregroundStyle(.secondary)
            outputView
        }
    }

    private var outputView: some View {
        let text: String = {
            if tab == .logs { return ProcessInspection.logLines(output, filter: filter).suffix(1_000).joined(separator: "\n") }
            return output.split(separator: "\n").filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n")
        }()
        return Group {
            if text.isEmpty {
                Text(loading ? "Waiting for output…" : "No matching events captured.").foregroundStyle(.secondary)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 320)
            }
        }
    }

    private func load() async {
        guard ProcessInspection.isCurrent(process.identity) else { message = "The process exited or its PID was reused."; return }
        loading = true
        message = nil
        defer { loading = false }
        let identity = process.identity
        switch tab {
        case .launchContext:
            let result = await Task.detached(priority: .utility) {
                (ProcessInspection.launchContext(pid: identity.pid), ProcessInspection.workingDirectory(pid: identity.pid))
            }.value
            guard !Task.isCancelled, ProcessInspection.isCurrent(identity) else { return }
            fields = [InspectionField(label: "Executable", value: process.executablePath ?? "Unavailable"),
                      InspectionField(label: "Working directory", value: result.1 ?? "Permission denied or unavailable")]
            arguments = result.0?.arguments ?? []
            environment = result.0?.environment ?? []
            if result.0 == nil { message = "Arguments and environment are inaccessible for this process." }
        case .security:
            let path = process.executablePath
            let result = await Task.detached(priority: .utility) { ProcessInspection.security(pid: identity.pid, path: path) }.value
            guard !Task.isCancelled, ProcessInspection.isCurrent(identity) else { return }
            fields = result
            if result.isEmpty { message = "Security information is inaccessible for this process." }
        case .startup:
            if refresh > 0 { store.startupItemsModel.load() }
            if store.startupItemsModel.inventory == nil { store.startupItemsModel.load(includeBackgroundTasks: false) }
        case .logs:
            let name = process.name
            crashes = await Task.detached(priority: .utility) {
                let folders = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
                               URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")]
                return folders.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
                    .filter { ($0.lastPathComponent.hasPrefix(name + "-") || $0.lastPathComponent.hasPrefix(name + "_")) && ["ips", "crash", "hang"].contains($0.pathExtension) }
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(30).map { $0 }
            }.value
            repeat {
                guard !Task.isCancelled, ProcessInspection.isCurrent(identity) else { return }
                let result = await CommandRunner.run("/usr/bin/log",
                    ProcessInspection.logArguments(identity: identity, since: Date().addingTimeInterval(-300), severity: severity),
                    timeout: 10, outputLimit: 1_048_576)
                guard !Task.isCancelled, ProcessInspection.isCurrent(identity) else { return }
                output = result.output
                message = failure(result)
                loading = false
                guard live else { break }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            } while !Task.isCancelled
        case .fileActivity:
            guard capture else { return }
            guard let result = await store.privilegedSampling?.captureFileActivity(identity: identity) else {
                message = "Enable superuser sampling in Settings and update the helper to capture file activity."
                return
            }
            guard !Task.isCancelled else { return }
            output = result.output
            message = result.error
        }
    }

    private func failure(_ result: CommandRunner.Result) -> String? {
        if result.timedOut { return "Log collection exceeded ten seconds; output may be incomplete." }
        if result.status != 0 { return result.error.isEmpty ? "Log access failed (status \(result.status))." : String(result.error.prefix(2_000)) }
        return result.truncated ? "Output limited to 1 MB. Narrow the severity or refresh for recent events." : nil
    }
}

private struct ProcessStartupInspection: View {
    @ObservedObject var store: MonitorStore
    let process: ProcessMetrics
    @ObservedObject var model: StartupItemsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectionValueRow(key: "Parent PID", value: process.parentPID.map(String.init) ?? "Unavailable")
            if let parent = process.parentPID.flatMap({ store.process(pid: $0) }) {
                Button("Inspect parent: \(parent.name)") { store.route = .process(parent.id) }.buttonStyle(.link)
            }
            if model.isLoading { ProgressView("Reading startup items…").controlSize(.small) }
            let items = (model.inventory?.items ?? []).filter { ProcessInspection.matches($0, process: process) }
            if items.isEmpty, !model.isLoading {
                Text("No matching startup registration found in the current inventory.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                Text(item.name).font(.headline)
                InspectionValueRow(key: "Registration", value: item.detail)
                InspectionValueRow(key: "Category", value: item.category.rawValue)
                InspectionValueRow(key: "Enabled", value: item.isEnabled ? "Yes" : "No")
                InspectionValueRow(key: "Trigger / restart", value: item.trigger ?? "Unavailable")
                if let path = item.path { InspectionValueRow(key: "Configuration", value: path) }
            }
            if let inventory = model.inventory {
                ForEach(inventory.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                if !inventory.includesBackgroundTasks {
                    Text("Login and app background items require Scan for All Items on the Startup page.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Open Startup Items") { store.route = .startupItems }.buttonStyle(.link)
        }
    }
}

struct ApplicationInspectionTab: View {
    @ObservedObject var store: MonitorStore
    let app: ApplicationMetrics
    let tab: ProcessInspectionTab
    @State private var selectedID: String?

    var body: some View {
        let selected = app.processes.first { $0.id == selectedID }
            ?? app.processes.first { $0.executablePath == app.executablePath } ?? app.processes.first
        VStack(alignment: .leading, spacing: 10) {
            if let selected {
                Picker("Process", selection: Binding(get: { selected.id }, set: { selectedID = $0 })) {
                    ForEach(app.processes) { Text("\($0.name) (\($0.identity.pid))").tag($0.id) }
                }.fixedSize()
                ProcessInspectionView(store: store, process: selected, tab: tab).id("\(selected.id)#\(tab.rawValue)")
            } else { Text("No process to inspect.").foregroundStyle(.secondary) }
        }
    }
}


private struct InspectionValueRow: View {
    let key: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
