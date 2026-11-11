import AppKit
import SwiftUI

struct StartupSummaryCard: View {
    @ObservedObject var model: StartupItemsModel
    var open: () -> Void

    var body: some View {
        let items = model.inventory?.items.filter { $0.category != .apple }
        SummaryTile(route: .startupItems,
            headline: items.map { "\($0.count(where: \.isEnabled)) enabled" } ?? "Review items",
            caption: items.map { "\($0.count { $0.pid != nil }) running · \($0.count { !$0.isEnabled }) disabled" } ?? "Login items, agents, daemons and cron jobs",
            open: open) {
            if let items, !items.isEmpty {
                SegmentBar(segments: [.init(value: Double(items.count { $0.isEnabled && $0.pid != nil }), color: .green),
                                      .init(value: Double(items.count { $0.isEnabled && $0.pid == nil }), color: .yellow)],
                           total: Double(items.count))
            }
        }
    }
}

struct StartupItemsView: View {
    @ObservedObject var model: StartupItemsModel

    private var visibleItems: [StartupItem] {
        let items = model.inventory?.items ?? []
        let query = model.query
        return items.filter { item in
            (model.showApple || item.category != .apple)
                && (query.isEmpty || "\(item.name) \(item.detail) \(item.program ?? "") \(item.developer ?? "")".localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        let items = visibleItems
        VStack(spacing: 0) {
            DetailPageHeader(padding: MonitorStyle.spacing) {
                ResourceTitle(title: "Startup", systemImage: "sunrise", color: AppRoute.startupItems.tint, subtitle: "Login items, launch agents and daemons")
            } actions: {
                if let timestamp = model.inventory?.timestamp {
                    Text(timestamp, style: .time)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                RefreshButton(isLoading: model.isLoading, hint: model.inventory?.includesBackgroundTasks == true
                    ? "Refresh: repeats the full scan; macOS asks for an administrator password again."
                    : "Refresh: rescans items visible without a password.") { model.load() }
                .disabled(model.isLoading)
            } overview: {
                ResourceStatsRow(headline: model.inventory == nil ? "–" : String(items.filter(\.isEnabled).count), unit: "enabled", stats: [
                    ResourceStat(title: "Disabled", systemImage: "pause.circle", value: model.inventory == nil ? "Unavailable" : String(items.filter { !$0.isEnabled }.count)),
                    ResourceStat(title: "Running", systemImage: "play.circle", value: model.inventory == nil ? "Unavailable" : String(items.filter { $0.pid != nil }.count))
                ], headlineWidth: 150)
            }

            if model.inventory?.includesBackgroundTasks == false {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Open at Login apps and app background items are not shown")
                            .font(.callout.weight(.semibold))
                        Text("Only macOS Background Task Management lists them. Reading it runs `sfltool dumpbtm`, and macOS asks for an administrator password. Smack only reads the list, and changing items afterwards does not need that password.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button("Scan for All Items") { model.load(includeBackgroundTasks: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isLoading)
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .bottom])
            }

            HStack {
                TextField("Search names, labels, programs, and developers", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                Toggle("Show Apple items", isOn: $model.showApple)
                    .hoverHint("Apple launch agents and daemons are listed read-only: disabling them can break macOS.")
            }
            .padding(.horizontal)

            ForEach(model.inventory?.warnings ?? [], id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top])
            }

            if model.inventory == nil {
                ProgressView("Inspecting startup items…")
                    .frame(maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(
                    model.query.isEmpty ? "No Startup Items" : "No Matching Items",
                    systemImage: "sunrise",
                    description: Text(model.query.isEmpty ? "Nothing is registered to start at login or boot." : "Try a different name, label, or program.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(StartupCategory.allCases) { category in
                        let rows = items.filter { $0.category == category }
                        if !rows.isEmpty {
                            Section("\(category.rawValue) (\(rows.count))") {
                                ForEach(rows) { item in
                                    StartupItemRow(item: item, isPending: model.pending.contains(item.id)) { enabled in
                                        model.setEnabled(enabled, for: item)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }

            Text("Changes apply at the next login or restart; running processes are not stopped.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
        .onAppear { if model.inventory == nil { model.load() } }
        .alert("Startup", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }


}

private struct StartupItemRow: View {
    let item: StartupItem
    let isPending: Bool
    let setEnabled: (Bool) -> Void

    @State private var expanded = false
    @State private var showingContents = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                icon.frame(width: 36, height: 36)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.headline).lineLimit(1)
                            HStack(spacing: 8) {
                                Label(item.isEnabled ? "Enabled" : "Disabled", systemImage: item.isEnabled ? "checkmark.circle.fill" : "pause.circle.fill")
                                    .foregroundStyle(item.isEnabled ? Color.green : Color.secondary)
                                if item.pid != nil {
                                    Label("Running", systemImage: "circle.fill").foregroundStyle(.green)
                                }
                                if item.note != nil {
                                    Label("Needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                }
                            }
                            .font(.caption)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.name), \(item.isEnabled ? "enabled" : "disabled"), \(item.pid != nil ? "running" : "not reported running")")
                .accessibilityHint(expanded ? "Hide details" : "Show details")
                if isPending { ProgressView().controlSize(.small) }
                Toggle(item.isEnabled ? "Enabled" : "Disabled", isOn: Binding(get: { item.isEnabled }, set: { setEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(item.isReadOnly || isPending)
                    .accessibilityLabel("Start \(item.name) automatically")
            }
            .padding(.vertical, 8)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    detailRow(item.category == .scheduled ? "Schedule" : "Identifier", item.detail)
                    if let trigger = item.trigger { detailRow("Starts", trigger) }
                    if let developer = item.developer { detailRow("Developer", developer) }
                    if let program = item.program { detailRow("Program", program) }
                    if let path = item.path { detailRow("Location", path) }
                    if let pid = item.pid { detailRow("Process", "PID \(pid)") }
                    if item.isReadOnly { detailRow("Control", "Read-only") }
                    if item.requiresAdministrator { detailRow("Control", "Requires administrator password") }
                    if let note = item.note {
                        Label(note, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if let path = item.path {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            if URL(fileURLWithPath: path).pathExtension.lowercased() != "app" {
                                Button("Show File Contents") { showingContents = true }
                            }
                        }
                        if let url = FileLookup.googleURL(searching: item.searchTerm) {
                            Link("Search online", destination: url)
                        }
                    }.padding(.top, 4)
                }
                .font(.caption)
                .padding(.leading, 48).padding(.bottom, 12)
                .textSelection(.enabled)
            }
        }
        .sheet(isPresented: $showingContents) {
            if let path = item.path {
                StartupFileContentsView(url: URL(fileURLWithPath: path))
            }
        }
        .contextMenu {
            if let path = item.path {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            if let program = item.program { Button("Copy Program Path") { copy(program) } }
            Button("Copy \(item.category == .scheduled ? "Schedule" : "Identifier")") { copy(item.detail) }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var icon: some View {
        if let appPath = [item.path, item.program].compactMap({ $0 }).compactMap({ path -> String? in
            guard let range = path.range(of: ".app", options: .caseInsensitive),
                  range.upperBound == path.endIndex || path[range.upperBound] == "/" else { return nil }
            return String(path[..<range.upperBound])
        }).first {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appPath)).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
        }
    }

    private var symbol: String {
        switch item.category {
        case .loginItems, .backgroundItems: return "app"
        case .agents: return "person.crop.circle"
        case .daemons: return "gearshape.2"
        case .scheduled: return "calendar.badge.clock"
        case .apple: return "apple.logo"
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct StartupFileContentsView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var preview: HomePreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("File Contents").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(url.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Divider()
            if let preview {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let message = preview.message {
                            Text(message).foregroundStyle(.secondary)
                        }
                        Text(preview.text).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView("Reading contents…")
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        .task {
            let worker = Task.detached(priority: .utility) { UserHomeCollector().preview(url) }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            if !Task.isCancelled { preview = result }
        }
    }
}
