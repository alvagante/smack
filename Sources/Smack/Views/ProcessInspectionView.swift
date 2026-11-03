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
    @State private var segment = 0

    private var traceSeconds: Int { store.settingsStore.settings.sampling.fileActivitySeconds }
    private var traceSegments: Int { max(1, traceSeconds / CollectionSettings.fileActivitySegmentSeconds) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !Capabilities.supportsProfiling {
                Text("This inspection is unavailable in the App Store build.").foregroundStyle(.secondary)
            } else {
                controls
                if loading { ProgressView(tab == .fileActivity ? captureProgress : "Inspecting process…").controlSize(.small) }
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
                if let inlineCaption { Text(inlineCaption).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if tab == .fileActivity {
                    Button("Capture \(traceSeconds) Seconds") { capture = true; refresh += 1 }.disabled(loading)
                } else {
                    RefreshButton { refresh += 1 }.disabled(loading && !live)
                }
            }
        }.controlSize(.small)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .launchContext:
            DetailFactGrid(facts: fields.map { field in
                DetailFact(title: field.label, value: field.value, systemImage: field.label == "Executable" ? "terminal" : "folder",
                           tone: field.label == "Executable" ? .blue : .teal, monospaced: true)
            }, minimumWidth: 260)
            MetricCard(title: "Arguments", systemImage: "chevron.left.forwardslash.chevron.right", color: .blue) {
                Text("Credential options are masked; positional arguments may contain sensitive data.").font(.caption).foregroundStyle(.secondary)
                ArgumentList(arguments: arguments)
            }
            MetricCard(title: "Environment", systemImage: "list.bullet.indent", color: .teal) {
                EnvironmentNames(variables: environment)
            }
        case .security:
            SecurityFields(fields: fields)
        case .startup:
            ProcessStartupInspection(store: store, process: process, model: store.startupItemsModel)
        case .logs:
            Text("Unified logs from the last five minutes, limited to this process lifetime. Live refreshes every three seconds.").font(.caption).foregroundStyle(.secondary)
            let lines = ProcessInspection.logLines(output, filter: filter)
            logSummary(lines)
            outputView(Array(lines.suffix(1_000)))
            MetricCard(title: "Crash Reports", systemImage: "exclamationmark.triangle", color: crashes.isEmpty ? .gray : .red) {
                if crashes.isEmpty { Text("No matching report filenames in accessible DiagnosticReports folders.").font(.callout).foregroundStyle(.secondary) }
                ForEach(crashes, id: \.path) { url in
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Label(url.lastPathComponent, systemImage: url.pathExtension == "hang" ? "hourglass" : "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.link)
                }
            }
        case .fileActivity:
            Text("Captures filesystem calls for this process using the superuser helper. Includes reads, writes, renames and deletions observed during the capture.").font(.caption).foregroundStyle(.secondary)
            outputView(output.split(separator: "\n").filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }.map(String.init))
        }
    }

    /// How many lines of each level the current output holds, so errors stand out before reading the log.
    @ViewBuilder
    private func logSummary(_ lines: [String]) -> some View {
        if !lines.isEmpty {
            let levels = LogLevel.counts(lines)
            HStack(spacing: 6) {
                DetailBadge(text: "\(lines.count.formatted()) lines", color: .secondary)
                ForEach(LogLevel.allCases.filter { levels[$0, default: 0] > 0 }) { level in
                    DetailBadge(text: "\(levels[level, default: 0].formatted()) \(level.rawValue.lowercased())", color: level.color)
                }
            }
        }
    }

    /// Beside the refresh button, for tabs with no other controls on that row.
    private var inlineCaption: String? {
        switch tab {
        case .security: "Signature and entitlements describe the executable on disk."
        case .launchContext: "Read from the running process at inspection time."
        case .startup: "Startup registrations that launch this executable."
        case .logs, .fileActivity: nil
        }
    }

    private var captureProgress: String {
        traceSegments > 1
            ? "Capturing file activity: segment \(max(segment, 1)) of \(traceSegments) (five seconds each)…"
            : "Capturing five seconds of file activity…"
    }

    private func outputView(_ lines: [String]) -> some View {
        Group {
            if lines.isEmpty {
                Text(loading ? "Waiting for output…" : "No matching events captured.").foregroundStyle(.secondary)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(tab == .logs ? LogLevel.highlighted(lines) : AttributedString(lines.joined(separator: "\n")))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 320)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
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
            guard let controller = store.privilegedSampling,
                  let result = await FileActivityTrace.capture(
                      segments: traceSegments,
                      isCurrent: { ProcessInspection.isCurrent(identity) },
                      segment: { await controller.captureFileActivity(identity: identity) },
                      progress: { segment = $0 }) else {
                message = "Enable superuser sampling in Settings › Privileged Helper and update the helper to capture file activity."
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
        VStack(alignment: .leading, spacing: 12) {
            let parent = process.parentPID.flatMap { store.process(pid: $0) }
            HStack(spacing: 10) {
                ResourceIcon(systemImage: "arrow.up.left", color: .teal, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Parent process").font(.caption).foregroundStyle(.secondary)
                    Text(parent.map { "\($0.name) (\($0.identity.pid))" } ?? process.parentPID.map { "PID \($0)" } ?? "Unavailable")
                        .font(.callout.weight(.medium))
                }
                Spacer(minLength: 0)
                if let parent { Button("Inspect parent") { store.route = .process(parent.id) }.buttonStyle(.link) }
            }
            if model.isLoading { ProgressView("Reading startup items…").controlSize(.small) }
            let items = (model.inventory?.items ?? []).filter { ProcessInspection.matches($0, process: process) }
            if items.isEmpty, !model.isLoading {
                Text("No matching startup registration found in the current inventory.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                MetricCard(title: item.name, systemImage: "sunrise", color: .orange) {
                    HStack(spacing: 6) {
                        DetailBadge(text: item.isEnabled ? "Enabled" : "Disabled", systemImage: item.isEnabled ? "checkmark" : "pause",
                                    color: item.isEnabled ? .green : .secondary)
                        DetailBadge(text: item.category.rawValue, color: .orange)
                    }
                    DetailFactGrid(facts: [
                        DetailFact(title: "Registration", value: item.detail, systemImage: "doc.badge.gearshape", monospaced: true),
                        DetailFact(title: "Trigger / restart", value: item.trigger ?? "Unavailable", systemImage: "arrow.clockwise"),
                    ] + (item.path.map { [DetailFact(title: "Configuration", value: $0, systemImage: "doc.text", monospaced: true)] } ?? []),
                    minimumWidth: 220)
                }
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


/// argv as a numbered listing: options in the accent color, masked values in orange.
private struct ArgumentList: View {
    let arguments: [String]

    var body: some View {
        if arguments.isEmpty {
            Text("No arguments available.").font(.callout).foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(arguments.enumerated()), id: \.offset) { index, value in
                    GridRow {
                        Text(String(index)).foregroundStyle(.tertiary).monospacedDigit().gridColumnAlignment(.trailing)
                        Text(value)
                            .foregroundStyle(color(value, index: index))
                            .fontWeight(index == 0 ? .semibold : .regular)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.caption.monospaced())
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func color(_ value: String, index: Int) -> Color {
        if value.contains("••••") { return .orange }
        if index > 0, value.hasPrefix("-") { return .accentColor }
        return .primary
    }
}

/// Variable names only, since values are never shown; names that can inject code or look like credentials are flagged.
private struct EnvironmentNames: View {
    let variables: [InspectionField]

    var body: some View {
        let injection = variables.filter { DetailReadings.risk(ofVariable: $0.label) == .injection }
        let sensitive = variables.filter { DetailReadings.risk(ofVariable: $0.label) == .sensitive }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                DetailBadge(text: "\(variables.count) variables", color: .teal)
                Text("Values hidden").font(.caption).foregroundStyle(.secondary)
                if !injection.isEmpty {
                    DetailBadge(text: "\(injection.count) code injection", systemImage: "exclamationmark.triangle.fill", color: .red)
                        .help("DYLD_ variables can load extra code into the process.")
                }
                if !sensitive.isEmpty {
                    DetailBadge(text: "\(sensitive.count) credential-like", systemImage: "key.fill", color: .orange)
                }
            }
            if variables.isEmpty {
                Text("No environment available.").font(.callout).foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 4, lineSpacing: 4) {
                ForEach(variables) { variable in
                    let risk = DetailReadings.risk(ofVariable: variable.label)
                    let color: Color = risk == .injection ? .red : risk == .sensitive ? .orange : .primary
                    Text(variable.label)
                        .font(.caption.monospaced())
                        .foregroundStyle(color)
                        .strikethrough(variable.value == "(empty)", color: .secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background((risk == .normal ? Color.primary : color).opacity(risk == .normal ? 0.05 : 0.14),
                                    in: RoundedRectangle(cornerRadius: 5))
                        .help(variable.value == "(empty)" ? "\(variable.label) is set but empty" : variable.label)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// Identity and signing facts as tiles, then entitlements with booleans drawn as marks and risky ones flagged.
private struct SecurityFields: View {
    private static let known: Set<String> = ["Effective UID / GID", "Real UID / GID", "Executable signature", "Signing identifier",
                                             "Team", "Certificate", "Hardened runtime", "Sandbox entitlement"]
    let fields: [InspectionField]

    var body: some View {
        let facts = fields.filter { Self.known.contains($0.label) }
        let entitlements = fields.filter { !Self.known.contains($0.label) }
        VStack(alignment: .leading, spacing: MonitorStyle.spacing) {
            if !facts.isEmpty { DetailFactGrid(facts: facts.map(fact)) }
            if !entitlements.isEmpty {
                MetricCard(title: "Entitlements (\(entitlements.count))", systemImage: "checkmark.seal", color: .indigo) {
                    ForEach(entitlements) { field in
                        let risky = DetailReadings.isRiskyEntitlement(field.label)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: risky ? "exclamationmark.triangle.fill" : "seal")
                                .foregroundStyle(risky ? .orange : .secondary).frame(width: 16)
                            Text(field.label).font(.caption.monospaced()).foregroundStyle(risky ? .orange : .primary)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            value(field.value)
                        }
                        .help(risky ? "Weakens code-signing protection or allows attaching a debugger." : field.label)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func value(_ text: String) -> some View {
        switch DetailReadings.entitlementFlag(text) {
        case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case false?: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        case nil:
            Text(text).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(4).multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func fact(_ field: InspectionField) -> DetailFact {
        let value = field.value
        switch field.label {
        case "Effective UID / GID", "Real UID / GID":
            let root = value.hasPrefix("0 ")
            return DetailFact(title: field.label, value: root ? "\(value) (root)" : value, systemImage: root ? "person.badge.key.fill" : "person",
                              tone: root ? .orange : .blue, monospaced: true)
        case "Executable signature":
            let tone: Color = value == "Signed" ? .green : value == "Ad-hoc" ? .orange : value == "Unsigned" ? .red : .gray
            return DetailFact(title: field.label, value: value, systemImage: value == "Signed" ? "checkmark.seal.fill" : "exclamationmark.shield.fill", tone: tone)
        case "Hardened runtime":
            return DetailFact(title: field.label, value: value, systemImage: value == "Yes" ? "lock.shield" : "lock.open",
                              tone: value == "Yes" ? .green : value == "No" ? .orange : nil)
        case "Sandbox entitlement":
            return DetailFact(title: "App Sandbox", value: value, systemImage: "square.dashed.inset.filled", tone: value == "Yes" ? .green : nil)
        default:
            return DetailFact(title: field.label, value: value, systemImage: field.label == "Team" ? "person.2" : field.label == "Certificate" ? "rosette" : "number",
                              tone: value == "Unavailable" ? nil : .indigo, monospaced: true)
        }
    }
}

/// Levels of `log show` messages as `ProcessInspection.logLines` prints them: "<timestamp> [<level>] <message>".
enum LogLevel: String, CaseIterable, Identifiable {
    case fault = "Fault", error = "Error", `default` = "Default", info = "Info", debug = "Debug"
    var id: Self { self }

    var color: Color {
        switch self {
        case .fault: .purple
        case .error: .red
        case .default: .secondary
        case .info: .blue
        case .debug: .gray
        }
    }

    static func level(of line: String) -> LogLevel? {
        guard let open = line.firstIndex(of: "["), let close = line[open...].firstIndex(of: "]") else { return nil }
        return LogLevel(rawValue: String(line[line.index(after: open)..<close]))
    }

    static func counts(_ lines: [String]) -> [LogLevel: Int] {
        lines.reduce(into: [:]) { result, line in if let level = level(of: line) { result[level, default: 0] += 1 } }
    }

    /// Timestamps dimmed, the level tag colored, and error and fault lines colored throughout.
    static func highlighted(_ lines: [String]) -> AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result += AttributedString("\n") }
            guard let level = level(of: line), let open = line.firstIndex(of: "["), let close = line[open...].firstIndex(of: "]") else {
                result += AttributedString(line)
                continue
            }
            var stamp = AttributedString(String(line[..<open]))
            stamp.foregroundColor = .secondary
            var tag = AttributedString(String(line[open...close]))
            tag.foregroundColor = level.color
            var message = AttributedString(String(line[line.index(after: close)...]))
            if level == .error || level == .fault { message.foregroundColor = level.color }
            result += stamp + tag + message
        }
        return result
    }
}
