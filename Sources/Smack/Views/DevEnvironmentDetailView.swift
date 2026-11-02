import SwiftUI
import AppKit

struct DevEnvironmentSummaryTile: View {
    @ObservedObject var model: DevEnvironmentMonitor
    var open: () -> Void

    var body: some View {
        if !Capabilities.isSandboxed {
            SummaryNavigationRow(route: .devEnvironments,
                value: model.snapshot.map { "\($0.environments.count) environments" } ?? (model.loading ? "Discovering…" : "Explore runtimes"),
                detail: model.snapshot.map { "\(Set($0.environments.map(\.language)).count) languages detected" } ?? "Languages, packages and paths", open: open)
        }
    }
}

struct DevEnvironmentDetailView: View {
    @ObservedObject var model: DevEnvironmentMonitor
    @State private var language: DevLanguage?
    @State private var selected: String?
    @State private var query = ""
    @State private var packageQuery = ""
    @State private var showingDiscoveryScope = false

    private var environments: [DevEnvironment] {
        (model.snapshot?.environments ?? []).filter {
            (language == nil || $0.language == language) &&
            (query.isEmpty || "\($0.language.rawValue) \($0.source) \($0.executable)".localizedCaseInsensitiveContains(query))
        }
    }
    private var current: DevEnvironment? { environments.first { $0.id == selected } ?? environments.first }

    private var overview: some View {
        DetailStatsGrid(stats: [
            ResourceStat(title: "Installations", systemImage: "terminal", value: model.snapshot.map { String($0.environments.count) } ?? "Unavailable"),
            ResourceStat(title: "Languages", systemImage: "chevron.left.forwardslash.chevron.right", value: model.snapshot.map { String(Set($0.environments.map(\.language)).count) } ?? "Unavailable"),
            ResourceStat(title: "On PATH", systemImage: "point.topleft.down.to.point.bottomright.curvepath", value: model.snapshot.map { String($0.environments.filter(\.onPath).count) } ?? "Unavailable")
        ], color: .teal)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    ResourceTitle(title: "Dev environments", systemImage: "chevron.left.forwardslash.chevron.right", color: .teal)
                    if let snapshot = model.snapshot {
                        Text("\(snapshot.environments.count) installations · Checked \(snapshot.timestamp.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                overview
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                ToolbarIconButton(title: "Discovery scope and limitations", systemImage: "info.circle", color: .teal) { showingDiscoveryScope.toggle() }
                    .popover(isPresented: $showingDiscoveryScope, arrowEdge: .bottom) {
                        discoveryScope
                    }
                ToolbarIconButton(title: "Add project folder…", systemImage: "folder.badge.plus", color: .blue, action: addFolder).disabled(model.loading)
                RefreshButton { Task { await model.refresh() } }.disabled(model.loading || model.inspecting != nil)
            }.padding()
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        languageButton(nil)
                        ForEach(DevLanguage.allCases) { language in languageButton(language) }
                    }.padding(10)
                }.frame(width: 165)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Filter language, manager or path", text: $query).textFieldStyle(.roundedBorder)
                        Text("Discovers concrete runtimes in PATH, standard locations and common version managers. Versions and package details load when selected. PATH refers to Smack's inherited environment; shell activation may differ.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let snapshot = model.snapshot {
                            ForEach(snapshot.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        if environments.isEmpty {
                            ContentUnavailableView(model.loading ? "Discovering environments" : "No matching environments", systemImage: "terminal",
                                description: Text("Add a project or installation folder to discover local virtualenvs and custom runtimes."))
                        } else {
                            Text("\(environments.count) matching installations").font(.headline)
                            Picker("Installation", selection: Binding(
                                get: { current?.id ?? "" }, set: { selected = $0; packageQuery = "" }
                            )) {
                                ForEach(environments) { item in
                                    Text("\(item.language.rawValue) · \(item.executable)").tag(item.id)
                                }
                            }
                            if let item = current {
                                Text(item.source + (item.onPath ? " · On inherited PATH" : " · Outside inherited PATH"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let item = current { details(item) }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task { if model.snapshot == nil { await model.refresh() } }
        .task(id: "\(current?.id ?? ""):\(model.snapshot?.timestamp.timeIntervalSince1970 ?? 0)") { if let item = current { await model.inspect(item) } }
        .onChange(of: model.snapshot?.timestamp) {
            selected = nil
            packageQuery = ""
        }
    }

    private var discoveryScope: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Discovery scope and limitations").font(.headline)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Supports \(DevLanguage.allCases.map(\.rawValue).joined(separator: ", ")). Project scans stop at \(model.depth) directory levels (set in Settings › Development) and skip dependency caches. Version-manager shims are skipped to avoid selecting or installing a runtime implicitly.")
                    Text("Python uses isolated mode, excluding PYTHONPATH; user-site packages are listed separately. Ruby gems, Node global packages, R packages, Cargo binaries, OTP libraries and runtime search paths are queried where supported. Project dependencies and language-server environments are not inferred. Go modules and Rust crates are project-specific; cache paths and installed tools are shown instead. Missing tools and failed probes are reported explicitly.")
                    Text("Runtime probes execute the selected local installation with a 10-second limit per command. No login shell is loaded. Custom runtime startup hooks can still run.")
                    ForEach(model.folders, id: \.self) { Text("Project: " + $0).font(.caption.monospaced()) }
                    ForEach(model.snapshot?.roots ?? [], id: \.self) { Text($0).font(.caption.monospaced()) }
                }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 520, height: 440)
    }

    private func languageButton(_ item: DevLanguage?) -> some View {
        let count = (model.snapshot?.environments ?? []).filter { item == nil || $0.language == item }.count
        return Button { language = item; selected = nil; packageQuery = "" } label: {
            HStack {
                Text(item?.rawValue ?? "All languages")
                Spacer()
                Text("\(count)").foregroundStyle(.secondary)
            }
            .font(.callout).padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(language == item ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func details(_ item: DevEnvironment) -> some View {
        Divider()
        Text("\(item.language.rawValue) installation").font(.headline)
        VStack(alignment: .leading, spacing: 6) {
            Text("Executable: " + item.executable)
            Text("Resolved path: " + item.resolvedPath)
            Button("Reveal executable") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.executable)]) }
        }.font(.caption.monospaced()).textSelection(.enabled)
        if let inspection = model.inspections[item.id] {
            TextField("Filter package and diagnostic output", text: $packageQuery).textFieldStyle(.roundedBorder)
            if inspection.reports.count == 1 {
                Text("Only runtime version metadata is available for this language. Project package inventories are not collected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(inspection.reports) { report in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(report.title, systemImage: report.failed ? "exclamationmark.triangle" : "terminal")
                            .font(.headline).foregroundStyle(report.failed ? Color.orange : Color.primary)
                        DisclosureGroup("Command") { Text(report.command).font(.caption.monospaced()).textSelection(.enabled) }
                        let lines = report.output.components(separatedBy: .newlines).filter {
                            packageQuery.isEmpty || $0.localizedCaseInsensitiveContains(packageQuery)
                        }
                        Text(lines.isEmpty ? "No matching output." : lines.joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Copy output") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report.output, forType: .string)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            ProgressView("Reading runtime and packages…").controlSize(.small)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let path = panel.url?.path {
            Task { await model.addFolder(path) }
        }
    }
}
