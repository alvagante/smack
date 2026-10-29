import AppKit
import SwiftUI

struct StartupSummaryCard: View {
    @ObservedObject var model: StartupItemsModel
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            MetricCard(title: "Startup", systemImage: "sunrise") {
                if let items = model.inventory?.items.filter({ $0.category != .apple }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(items.filter(\.isEnabled).count) enabled")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Label("\(items.count) items", systemImage: "list.bullet")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                } else {
                    Text("Review and turn off login items, agents, daemons, and cron jobs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
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
            HStack(spacing: 16) {
                summary("Enabled", value: items.filter(\.isEnabled).count, color: .green)
                summary("Disabled", value: items.filter { !$0.isEnabled }.count, color: .secondary)
                summary("Running", value: items.filter { $0.pid != nil }.count, color: .primary)
                Spacer()
                if let timestamp = model.inventory?.timestamp {
                    Text(timestamp, style: .time)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button { model.load() } label: {
                    if model.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isLoading)
                .hoverHint(model.inventory?.includesBackgroundTasks == true
                    ? "Repeats the full scan; macOS asks for an administrator password again."
                    : "Rescans items visible without a password.")
            }
            .padding()

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

    private func summary(_ title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(value))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StartupItemRow: View {
    let item: StartupItem
    let isPending: Bool
    let setEnabled: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if let trigger = item.trigger { Text(trigger) }
                    if let developer = item.developer { Text("·"); Text(developer) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let note = item.note {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if let url = FileLookup.googleURL(searching: item.searchTerm) {
                Link(destination: url) {
                    Image(systemName: "magnifyingglass")
                }
                .font(.caption)
                .hoverHint("Google: search for \"\(item.searchTerm)\" macOS")
                .accessibilityLabel("Search Google for \(item.searchTerm)")
            }
            if let pid = item.pid {
                Text("PID \(pid)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.green)
                    .hoverHint("Running now")
            }
            if item.requiresAdministrator {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                    .hoverHint("Changing this daemon asks for an administrator password.")
            }
            if isPending {
                ProgressView().controlSize(.small)
            }
            Toggle(item.isEnabled ? "Enabled" : "Disabled", isOn: Binding(get: { item.isEnabled }, set: { setEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(item.isReadOnly || isPending)
                .accessibilityLabel("Start \(item.name) automatically")
        }
        .padding(.vertical, 4)
        .help(item.program ?? item.detail)
        .contextMenu {
            if let path = item.path {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            if let program = item.program {
                Button("Copy Program Path") { copy(program) }
            }
            Button("Copy \(item.category == .scheduled ? "Schedule" : "Identifier")") { copy(item.detail) }
        }
    }

    @ViewBuilder private var icon: some View {
        if let path = item.path, path.hasSuffix(".app") {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
        } else {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
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
