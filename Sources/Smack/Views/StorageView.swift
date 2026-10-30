import SwiftUI
import AppKit
import SmackIPC

struct StorageView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject private var model: StorageScanModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: MonitorStore) {
        self.store = store
        model = store.storageScanModel
    }

    private let palette: [Color] = [.cyan, .indigo, .mint, .orange, .purple, .pink, .teal, .blue]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Storage").font(.title2.bold())
                        Text("Find what takes up space").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "internaldrive").font(.title).foregroundStyle(.cyan)
                }
                volumes
                scanControls
                if model.scope == .disk {
                    permissions
                } else if Capabilities.isSandboxed {
                    Text("Choose your home folder to grant read access for this scan.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.isScanning { scanProgress }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if let result = model.result, let directory = model.current {
                    directoryContent(directory, result: result)
                } else if !model.isScanning {
                    VStack(spacing: 10) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 36)).foregroundStyle(.cyan)
                        Text("Your space, mapped out").font(.headline)
                        Text("Scan your home folder, then select a folder to explore its contents.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
                }
            }
            .padding()
        }
    }

    private var volumes: some View {
        ForEach(store.system?.volumes ?? []) { volume in
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(volume.name).font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(Formatting.bytes(volume.availableBytes)) free").foregroundStyle(.secondary)
                }
                .font(.caption)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.secondary.opacity(0.12))
                        Capsule().fill(LinearGradient(colors: [.indigo, .cyan], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geometry.size.width * min(1, Double(volume.usedBytes) / Double(max(1, volume.totalBytes))))
                    }
                }
                .frame(height: 8)
                Text("\(Formatting.bytes(volume.usedBytes)) used of \(Formatting.bytes(volume.totalBytes))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var scanControls: some View {
        HStack {
            Picker("Scan scope", selection: $model.scope) {
                Text("Home").tag(StorageScanScope.home)
                if !Capabilities.isSandboxed { Text("Full Disk").tag(StorageScanScope.disk) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220)
            .disabled(model.isScanning)
            Spacer(minLength: 8)
            if model.isScanning {
                Button("Cancel") { model.cancel() }
            } else {
                if model.result != nil {
                    Button("Clear Results") { model.clearResults() }
                }
                Button(action: startScan) {
                    Label(model.result == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Scan with administrator access", isOn: $model.useAdministrator)
                .font(.callout).disabled(model.isScanning || !helperReady)
            HStack {
                Button("Superuser Setup", systemImage: "lock.shield") { model.showSetup.toggle() }
                Button("Full Disk Access", systemImage: "hand.raised") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .controlSize(.small)
            Text("Full Disk scans the startup disk; external volumes are excluded. Unreadable items are skipped. Root access does not bypass macOS privacy protection: grant Full Disk Access to Smack (and Smack Helper for administrator scans), then rescan.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.showSetup, let controller = store.privilegedSampling {
                Text("Enabling this helper also enables sampling of other users' processes. In Full Disk Access, use + to add Smack. For administrator scans, add Smack Helper too; Show Helper locates it in Finder.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show Helper in Finder") {
                    let path = controller.mode == .legacyInstall
                        ? SmackIPC.installedHelperPath
                        : Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SmackHelper").path
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .controlSize(.small)
                PrivilegedSamplingSection(controller: controller, settings: store.settingsStore, onChange: { store.settingsChanged() }, toggleTitle: "Enable superuser helper")
                    .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var helperReady: Bool {
        model.helperReady
    }

    private var scanProgress: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                ProgressView().controlSize(.small)
                Text("Scanning…").font(.callout.weight(.semibold))
                Spacer()
                Text("\(model.progress?.files ?? 0) files").font(.caption).monospacedDigit()
            }
            Text(model.progress?.currentPath ?? "Preparing scan…")
                .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Text("\(Formatting.bytes(model.progress?.bytes ?? 0)) found · \(model.progress?.skipped ?? 0) unreadable items")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12).background(.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func directoryContent(_ directory: StorageDirectory, result: StorageScanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.trail.enumerated()), id: \.element) { index, path in
                        if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        Button(index == 0 ? (path == "/" ? "Startup Disk" : URL(fileURLWithPath: path).lastPathComponent) : URL(fileURLWithPath: path).lastPathComponent) {
                            navigate(path)
                        }
                        .buttonStyle(.plain).foregroundStyle(index == model.trail.count - 1 ? Color.primary : .secondary)
                    }
                }
                .font(.callout.weight(.medium))
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Formatting.bytes(directory.bytes)).font(.system(size: 30, weight: .bold, design: .rounded))
                Text(fileCount(directory.files)).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if model.trail.count > 1 {
                    Button { navigate(model.trail[model.trail.count - 2]) } label: { Image(systemName: "arrow.up") }
                        .accessibilityLabel("Parent folder")
                }
            }
            Text(directory.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            if directory.bytes > 0 {
                treemap(directory)
                Text("Select a tile or folder to drill down").font(.caption2).foregroundStyle(.secondary)
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(model.currentChildren.enumerated()), id: \.element.id) { index, child in
                    directoryRow(child, index: index, total: directory.bytes)
                    Divider().opacity(0.5)
                }
                if directory.directFiles > 0 {
                    HStack {
                        Image(systemName: "doc").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Files in this folder").font(.callout)
                            Text(fileCount(directory.directFiles)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Formatting.bytes(directory.directBytes)).font(.callout).monospacedDigit()
                    }.padding(.vertical, 10)
                }
            }
            if directory.files == 0, model.currentChildren.isEmpty {
                Text("No readable files in this folder.").font(.callout).foregroundStyle(.secondary)
            }
            Text("Allocated file size · Scan completed \(resultDate)\(result.skipped > 0 ? " · Partial results: \(result.skipped) unreadable items" : "")")
                .font(.caption2).foregroundStyle(result.skipped > 0 ? Color.orange : .secondary)
            Text("Snapshots, filesystem metadata, compression and shared APFS blocks can make these totals differ from volume usage.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var resultDate: String { model.completedAt?.formatted(date: .omitted, time: .shortened) ?? "" }

    private func directoryRow(_ child: StorageDirectory, index: Int, total: UInt64) -> some View {
        Button { navigate(child.path) } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").font(.title3).foregroundStyle(palette[index % palette.count])
                VStack(alignment: .leading, spacing: 4) {
                    Text(child.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(fileCount(child.files))
                        Text("·")
                        Text((Double(child.bytes) / Double(max(1, total))).formatted(.percent.precision(.fractionLength(1))))
                    }.font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(Formatting.bytes(child.bytes)).font(.callout.weight(.semibold)).monospacedDigit()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 9).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(child.name), \(Formatting.bytes(child.bytes)), \(child.files) files")
    }

    private func treemap(_ directory: StorageDirectory) -> some View {
        let entries = StorageMapEntry.entries(directory: directory, children: model.currentChildren)
        return GeometryReader { geometry in
            let tiles = StorageMapEntry.layout(entries, in: CGRect(origin: .zero, size: geometry.size))
            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    let color = palette[tile.entry.colorIndex % palette.count]
                    Button {
                        if let path = tile.entry.path { navigate(path) }
                    } label: {
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(LinearGradient(colors: [color.opacity(model.hovered == tile.id ? 0.9 : 0.7), color.opacity(0.3)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                            RoundedRectangle(cornerRadius: 9).strokeBorder(color.opacity(0.5), lineWidth: 1)
                            if tile.rect.width > 64, tile.rect.height > 40 {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tile.entry.name).font(.callout.weight(.semibold)).lineLimit(1)
                                    Text(Formatting.bytes(tile.entry.bytes)).font(.caption).monospacedDigit()
                                    if tile.rect.height > 75 {
                                        Text(fileCount(tile.entry.files)).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }.padding(9)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .frame(width: max(0, tile.rect.width - 3), height: max(0, tile.rect.height - 3))
                    .offset(x: tile.rect.minX, y: tile.rect.minY)
                    .onHover { model.hovered = $0 ? tile.id : nil }
                    .help("\(tile.entry.name): \(Formatting.bytes(tile.entry.bytes)), \(tile.entry.files) files")
                    .accessibilityLabel("\(tile.entry.name), \(Formatting.bytes(tile.entry.bytes)), \(tile.entry.files) files")
                    .accessibilityHint(tile.entry.path == nil ? "Summary tile" : "Open folder")
                }
            }
        }
        .frame(height: 230)
    }

    private func navigate(_ path: String) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { model.open(path) }
    }

    private func startScan() {
        guard !model.useAdministrator || model.scope == .home || helperReady else {
            model.showSetup = true
            return
        }
        if Capabilities.isSandboxed {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.message = "Select your home folder to scan its disk usage."
            panel.prompt = "Scan Folder"
            panel.directoryURL = URL(fileURLWithPath: "/Users/\(NSUserName())")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            model.scan(root: url)
        } else {
            model.scan(root: model.scope == .home ? FileManager.default.homeDirectoryForCurrentUser : URL(fileURLWithPath: "/"))
        }
    }
}

private func fileCount(_ count: UInt64) -> String {
    "\(count.formatted()) \(count == 1 ? "file" : "files")"
}
