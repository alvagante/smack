import SwiftUI
import AppKit

struct HomebrewSummaryTile: View {
    @ObservedObject var model: HomebrewMonitor
    var open: () -> Void

    var body: some View {
        if model.installed {
            Button(action: open) {
                MetricCard(title: "Homebrew", systemImage: "mug") {
                    Text(model.snapshot?.packages.map { "\($0.count) installed" } ?? (model.loading ? "Collecting…" : "Installed count unavailable"))
                        .font(.title3.weight(.semibold))
                    Text(model.snapshot?.updateCount.map { "\($0) updates available" } ?? "Updates unavailable")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum BrewSection: String, CaseIterable, Sendable {
    case installed = "Installed", updates = "Updates", unused = "Not used lately"
    case services = "Services", cleanup = "Clean up", discover = "Find packages"
}

struct HomebrewDetailView: View {
    @ObservedObject var model: HomebrewMonitor
    @State private var section = BrewSection.installed
    @State private var query = ""
    @State private var kind = BrewKind.formula
    @State private var pending: BrewOperation?
    @State private var inspectedPackage: BrewPackage?
    @State private var inspectionRead = BrewPackageRead.info

    private var blocked: Bool { model.busy || model.loading || model.searching }
    private var packages: [BrewPackage] {
        (model.snapshot?.packages ?? []).filter {
            (section != .updates || $0.isOutdated) &&
            (query.isEmpty || "\($0.name) \($0.fullName) \($0.description)".localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(BrewSection.allCases, id: \.self) { item in
                        Button { section = item } label: {
                            HStack {
                                Text(item.rawValue)
                                Spacer()
                                if item == .installed, let count = model.snapshot?.packages?.count { Text("\(count)") }
                                if item == .updates, let count = model.snapshot?.updateCount { Text("\(count)") }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(section == item ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(10).frame(width: 175)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let snapshot = model.snapshot {
                            ForEach(snapshot.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                            }
                        }
                        if model.busy || !model.output.isEmpty { commandResult }
                        content
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: section) {
            model.section = section
            await model.showDetails()
        }
        .onDisappear { model.detailsWanted = false }
        .sheet(item: $inspectedPackage) { package in
            BrewPackageDetailView(model: model, package: package, read: inspectionRead)
        }
        .confirmationDialog(pending?.title ?? "Homebrew", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            if let action = pending {
                Button(action.confirmationLabel, role: action.destructive ? .destructive : nil) {
                    pending = nil
                    Task { await model.perform(action) }
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("brew \(pending?.arguments.joined(separator: " ") ?? "")\n" +
                 (pending?.explanation ?? "Homebrew may change dependencies or restart services.") +
                 "\nCommands requiring an interactive administrator password must be run in Terminal.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Label("Homebrew", systemImage: "mug").font(.title2.weight(.semibold))
                if let snapshot = model.snapshot, let packages = snapshot.packages {
                    Text("\(packages.filter { $0.kind == .formula }.count) tools · \(packages.filter { $0.kind == .cask }.count) apps")
                        .font(.caption).foregroundStyle(.secondary)
                    if let bytes = snapshot.managedBytes {
                        Text("\(Formatting.bytes(bytes)) tool storage (Cellar)")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("Formula files only. Cask application bundles and caches are excluded.")
                    }
                    Text("Checked \(snapshot.timestamp.formatted(date: .omitted, time: .shortened)) against local metadata")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if blocked { ProgressView().controlSize(.small) }
            Button("Refresh") { Task { await model.refresh() } }.disabled(blocked)
            Button("Check for updates") {
                pending = BrewOperation(title: "Refresh Homebrew repositories?", arguments: ["update"])
            }.disabled(blocked)
        }.padding()
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .installed, .updates:
            Text(section.rawValue).font(.headline)
            TextField("Filter installed names and descriptions", text: $query)
                .textFieldStyle(.roundedBorder)
            if section == .updates {
                Text("Version changes are shown per package. Dependency changes and service restarts are determined by Homebrew.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Update all") { pending = BrewOperation(title: "Upgrade all outdated packages?", arguments: ["upgrade"]) }
                    .disabled(blocked || model.snapshot?.updateCount == nil || model.snapshot?.updateCount == 0)
            }
            if model.snapshot?.packages == nil {
                Text(model.loading ? "Collecting installed packages…" : "Installed packages unavailable.")
            } else if section == .updates && model.snapshot?.updatesKnown != true {
                Text("Available updates could not be checked. Refresh to try again.")
            } else if packages.isEmpty {
                Text(query.isEmpty ? (section == .updates ? "All packages are up to date." : "No installed packages.") : "No matching packages.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(packages) { package in packageRow(package, installed: true); Divider() }
                }
            }
        case .unused:
            Text("Usage history unavailable").font(.headline)
            Text("Homebrew does not record when tools or apps were last used. Smack cannot reliably identify unused packages.")
                .foregroundStyle(.secondary)
        case .services:
            Text("User services").font(.headline)
            Text("Start registers a service at login. Stop unregisters it. System services managed as root are excluded.")
                .font(.caption).foregroundStyle(.secondary)
            if let services = model.snapshot?.services {
                if services.isEmpty { Text("No Homebrew services.").foregroundStyle(.secondary) }
                ForEach(services) { service in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(service.name).font(.headline)
                            Text("\(service.status)\(service.user.map { " · \($0)" } ?? "")").foregroundStyle(.secondary)
                        }
                        Spacer()
                        ForEach(["start", "stop", "restart"], id: \.self) { verb in
                            Button(verb.capitalized) {
                                let name = model.snapshot?.packages?.first { $0.kind == .formula && $0.name == service.name }?.fullName ?? service.name
                                pending = BrewOperation(title: "\(verb.capitalized) \(service.name)?", arguments: ["services", verb, name])
                            }.disabled(blocked)
                        }
                    }
                    Divider()
                }
            } else { Text(model.loading ? "Checking services…" : "Services unavailable.") }
        case .cleanup:
            Text("Old versions and cached downloads").font(.headline)
            Text("Preview from Homebrew. Cleanup removes eligible old versions and downloads; it does not uninstall current packages.")
                .font(.caption).foregroundStyle(.secondary)
            if let preview = model.snapshot?.cleanup {
                Text(preview.isEmpty ? "Nothing eligible for cleanup." : preview)
                    .font(.caption.monospaced()).textSelection(.enabled)
                Button("Clean up…") { pending = BrewOperation(title: "Remove old versions and cached downloads?", arguments: ["cleanup"]) }
                    .disabled(blocked || preview.isEmpty)
            } else { Text(model.loading ? "Estimating cleanup…" : "Cleanup estimate unavailable.") }
        case .discover:
            Text("Find packages to install").font(.headline)
            HStack {
                TextField("Package name", text: $query).textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Picker("Type", selection: $kind) {
                    Text("Tools").tag(BrewKind.formula)
                    Text("Apps").tag(BrewKind.cask)
                }.frame(width: 145)
                Button("Search") { search() }.disabled(blocked || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Search uses Homebrew's package catalog. Installations and upgrades may download software.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.results) { package in
                let installed = model.snapshot?.packages?.first { $0.id == package.id || ($0.kind == package.kind && $0.name == package.name) }
                packageRow(installed ?? package, installed: installed != nil)
                Divider()
            }
        }
    }

    private func search() {
        Task { await model.search(query, kind: kind) }
    }

    private func packageRow(_ package: BrewPackage, installed: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: package.kind == .formula ? "terminal" : "app").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(package.name).font(.headline)
                Text(package.fullName).font(.caption.monospaced()).foregroundStyle(.secondary)
                if !package.description.isEmpty { Text(package.description).font(.caption).foregroundStyle(.secondary) }
                Text(package.kind.label + (installed && !package.installedVersion.isEmpty ? " · \(package.installedVersion)" : "") + (package.pinned ? " · Pinned" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                if let available = package.availableVersion {
                    Text("\(package.installedVersion) → \(available)").font(.callout.monospaced()).foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                HStack {
                    Button("Details", systemImage: "info.circle") { inspectionRead = .info; inspectedPackage = package }
                        .disabled(blocked)
                    if installed {
                        Button("Uninstall…", role: .destructive) {
                            pending = BrewPackageAction.uninstall.operation(for: package)
                        }.disabled(blocked)
                    } else {
                        Button("Install…") {
                            pending = BrewOperation(title: "Install \(package.name)?", arguments: package.arguments("install"))
                        }.disabled(blocked)
                    }
                }
                if installed {
                    HStack {
                        if BrewPackageAction.upgrade.isAvailable(for: package) {
                            Button("Update…") { pending = BrewPackageAction.upgrade.operation(for: package) }
                                .disabled(blocked)
                        }
                        Menu("More", systemImage: "ellipsis.circle") {
                            Button("Show installed files") { inspectionRead = .files; inspectedPackage = package }
                            Divider()
                            ForEach([BrewPackageAction.reinstall, .pin, .unpin].filter { $0.isAvailable(for: package) }, id: \.self) { action in
                                Button(action.title + "…") { pending = action.operation(for: package) }
                            }
                        }.disabled(blocked)
                    }
                }
            }
            .buttonStyle(.bordered)
            .fixedSize()

        }
        .textSelection(.enabled)
    }

    private var commandResult: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(model.busy ? (model.operation?.title ?? "Running Homebrew") : model.failed ? "Command failed" : "Completed",
                          systemImage: model.busy ? "hourglass" : model.failed ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(model.failed ? Color.red : Color.primary)
                    Spacer()
                    if !model.busy {
                        Button("Close") { model.output = ""; model.operation = nil }
                    }
                }
                if let operation = model.operation {
                    Text("brew \(operation.arguments.joined(separator: " "))").font(.caption.monospaced())
                }
                if model.busy { Text("Homebrew is running. Output appears when it finishes.").font(.caption) }
                else {
                    Text(model.output).font(.caption.monospaced()).textSelection(.enabled)
                    HStack {
                        Button("Copy output") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.output, forType: .string) }
                        if model.failed, let action = model.operation {
                            Button("Try again…") { pending = action }.disabled(blocked)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BrewPackageDetailView: View {
    @ObservedObject var model: HomebrewMonitor
    let package: BrewPackage
    @State var read = BrewPackageRead.info
    @Environment(\.dismiss) private var dismiss
    @State private var output = ""
    @State private var error: String?
    @State private var loading = true
    @State private var refreshID = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(package.name).font(.title2.weight(.semibold))
                    Text(package.fullName).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { refreshID += 1 }.disabled(loading)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }.disabled(loading || error != nil)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Details", selection: $read) {
                ForEach(BrewPackageRead.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Text("brew " + read.arguments(for: package).joined(separator: " "))
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            if loading {
                ProgressView("Reading Homebrew details…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(error ?? (output.isEmpty ? "No details reported." : output))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(error == nil ? Color.primary : Color.red)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .frame(minWidth: 600, idealWidth: 800, minHeight: 400, idealHeight: 550)
        .task(id: read.rawValue + String(refreshID)) {
            loading = true
            error = nil
            do {
                let value = try await model.inspect(package, read: read)
                guard !Task.isCancelled else { return }
                output = value
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
