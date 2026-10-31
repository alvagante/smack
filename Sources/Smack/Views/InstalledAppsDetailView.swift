import SwiftUI
import AppKit

struct InstalledAppsSummaryTile: View {
    @ObservedObject var model: InstalledAppsMonitor
    var open: () -> Void

    var body: some View {
        if !Capabilities.isSandboxed {
            Button(action: open) {
                MetricCard(title: "Installed apps", systemImage: "square.grid.3x3") {
                    Text(model.snapshot.map { "\($0.apps.count) apps" } ?? (model.loading ? "Discovering…" : "Browse installed apps"))
                        .font(.title3.weight(.semibold))
                    Text(model.snapshot.map { value in
                        value.apps.contains { $0.sizeBytes != nil } || value.measured
                            ? "\(Formatting.bytes(value.totalBytes))\(value.measured ? "" : " measured")" : "Sizes not measured"
                    } ?? "Sizes and uninstall")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task { if model.snapshot == nil { await model.refresh() } }
        }
    }
}

struct InstalledAppsDetailView: View {
    @ObservedObject var model: InstalledAppsMonitor
    @State private var query = ""
    @State private var selection: Set<String> = []
    @State private var confirming = false
    @State private var request = 0
    @State private var sizing = false
    @AppStorage("installedApps.listLayout") private var listLayout = false

    private var apps: [InstalledApp] {
        (model.snapshot?.apps ?? [])
            .filter { query.isEmpty || "\($0.name) \($0.bundleIdentifier ?? "")".localizedCaseInsensitiveContains(query) }
            .sorted {
                switch ($0.sizeBytes, $1.sizeBytes) {
                case let (left?, right?) where left != right: return left > right
                case (.some, nil): return true
                case (nil, .some): return false
                default: return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
    }
    private var selected: [InstalledApp] { (model.snapshot?.apps ?? []).filter { selection.contains($0.id) } }
    private var selectedBytes: UInt64 { selected.reduce(0) { $0 &+ ($1.sizeBytes ?? 0) } }
    private var selectedSize: String {
        selected.contains { $0.sizeBytes == nil } ? "size unavailable" : Formatting.bytes(selectedBytes)
    }
    private var appsLabel: String { selected.count == 1 ? "1 App" : "\(selected.count) Apps" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let message = model.message { result(message) }
                    if model.snapshot == nil {
                        Text(model.loading ? "Discovering applications…" : "Installed applications unavailable.")
                            .foregroundStyle(.secondary)
                    } else if apps.isEmpty {
                        Text(query.isEmpty ? "No applications found." : "No matching applications.").foregroundStyle(.secondary)
                    } else if listLayout {
                        LazyVStack(spacing: 0) {
                            ForEach(apps) { app in listRow(app); Divider() }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                            ForEach(apps) { app in gridCell(app) }
                        }
                    }
                }
                .padding()
                .padding(.bottom, selection.isEmpty ? 0 : 64)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) { if !selection.isEmpty { selectionBar } }
        .tint(.teal)
        .task(id: request) {
            while model.loading && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            guard !Task.isCancelled else { return }
            if sizing { await model.measure() } else { await model.refresh() }
        }
        .onChange(of: model.snapshot?.apps.map(\.id)) { _, ids in
            selection.formIntersection(ids ?? [])
        }
        .confirmationDialog("Move \(appsLabel.lowercased()) to the Trash?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                let ids = selection
                Task { selection.subtract(await model.uninstall(ids)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(selected.map(\.name).joined(separator: ", ")) (\(selectedSize))\nSettings, caches and other support files in your Library are kept. Restore from the Trash if needed.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Installed apps", systemImage: "square.grid.3x3").font(.title2.weight(.semibold))
                if let snapshot = model.snapshot {
                    Text("\(snapshot.apps.count) apps · \(Formatting.bytes(snapshot.totalBytes))\(snapshot.measured ? "" : " measured so far")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Checked \(snapshot.timestamp.formatted(date: .omitted, time: .shortened)) · /Applications and ~/Applications")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                HStack {
                    if model.loading || model.measuring || model.busy { ProgressView().controlSize(.small) }
                    if let fraction = model.snapshot?.volumeUsedFraction {
                        Text("\(Formatting.percent(fraction * 100)) used")
                            .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                            .help("Space used on the volume holding /Applications")
                    }
                    Button("Measure sizes") { sizing = true; request += 1 }.disabled(model.loading || model.measuring || model.busy)
                    Button("Refresh") { sizing = false; request += 1 }.disabled(model.loading || model.measuring || model.busy)
                }
                HStack {
                    TextField("Search apps", text: $query).textFieldStyle(.roundedBorder).frame(width: 220)
                    Picker("Layout", selection: $listLayout) {
                        Image(systemName: "square.grid.2x2").tag(false).accessibilityLabel("Grid")
                        Image(systemName: "list.bullet").tag(true).accessibilityLabel("List")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 80)
                }
            }
        }.padding()
    }

    private func toggle(_ app: InstalledApp) {
        guard app.removable else { return }
        if selection.remove(app.id) == nil { selection.insert(app.id) }
    }

    private func gridCell(_ app: InstalledApp) -> some View {
        let isSelected = selection.contains(app.id)
        return Button { toggle(app) } label: {
            VStack(spacing: 6) {
                ApplicationIcon(bundlePath: app.path, size: 64)
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3).symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .offset(x: 8, y: -8)
                        }
                    }
                Text(app.name).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(app.sizeBytes.map(Formatting.bytes) ?? (app.sizeIncomplete ? "Incomplete" : "Not measured")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.vertical, 12).padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if isSelected { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.6), lineWidth: 2) }
            }
            .opacity(app.removable ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip(app))
        .contextMenu { menu(app) }
    }

    private func listRow(_ app: InstalledApp) -> some View {
        let isSelected = selection.contains(app.id)
        return Button { toggle(app) } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .opacity(app.removable ? 1 : 0)
                ApplicationIcon(bundlePath: app.path, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text([app.version, app.bundleIdentifier, app.fromAppStore ? "App Store" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(app.path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(app.sizeBytes.map(Formatting.bytes) ?? (app.sizeIncomplete ? "Incomplete" : "Not measured")).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .opacity(app.removable ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip(app))
        .contextMenu { menu(app) }
    }

    private func tooltip(_ app: InstalledApp) -> String {
        app.removable ? app.path : "\(app.path)\nProtected: cannot be uninstalled from Smack."
    }

    @ViewBuilder private func menu(_ app: InstalledApp) -> some View {
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
        Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(app.path, forType: .string) }
        if app.removable {
            Divider()
            Button(selection.contains(app.id) ? "Deselect" : "Select") { toggle(app) }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            Text("\(selected.count) app\(selected.count == 1 ? "" : "s") selected · \(selectedSize)")
                .font(.headline).monospacedDigit()
            Button("Clear") { selection.removeAll() }.buttonStyle(.link)
            Spacer()
            Button("Uninstall \(appsLabel)") { confirming = true }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.busy || model.loading)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08), lineWidth: 1) }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func result(_ message: String) -> some View {
        GroupBox {
            HStack(alignment: .top) {
                Label(message, systemImage: model.failed ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(model.failed ? Color.orange : Color.primary)
                    .textSelection(.enabled)
                Spacer()
                Button("Open Trash") {
                    if let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first {
                        NSWorkspace.shared.open(trash)
                    }
                }
                Button("Close") { model.message = nil }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
