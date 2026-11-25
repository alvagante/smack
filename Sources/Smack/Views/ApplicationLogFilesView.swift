import SwiftUI

struct ApplicationLogFilesView: View {
    let app: ApplicationMetrics
    let inventory: ApplicationInventory?
    let loading: Bool
    let refresh: () -> Void
    @State private var files: [AggregatedPath] = []
    @State private var processID = ""
    @State private var selectedPath: String?
    @State private var output = ""
    @State private var error: String?
    @State private var live = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Open Log Files").font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                RefreshButton(hint: "Inspect the processes again", action: refresh).disabled(loading)
            }
            Text("Nonempty files modified in the last seven days. Only files open at inspection time are shown.")
                .font(.caption).foregroundStyle(.secondary)
            if let inventory, inventory.isPartial {
                Text("Inspected \(inventory.inspected) of \(inventory.total) processes.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(inventory?.warnings ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            Picker("Process", selection: $processID) {
                Text("All processes").tag("")
                ForEach(app.processes) { Text("\($0.name) (\($0.identity.pid))").tag($0.id) }
            }.fixedSize()
            let shown = files.filter { processID.isEmpty || $0.processes.contains { $0.id == processID } }
            if shown.isEmpty && !loading { Text("No recent open log files found.").foregroundStyle(.secondary) }
            ForEach(shown) { file in
                Button { selectedPath = file.path; live = false } label: {
                    VStack(alignment: .leading) {
                        Text(file.path).textSelection(.enabled)
                        Text(file.processes.map(\.label).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.link)
            }
            if let selectedPath {
                HStack {
                    Text(selectedPath).font(.caption.monospaced()).textSelection(.enabled)
                    Spacer()
                    Toggle("Tail", isOn: $live).toggleStyle(.button)
                    Button("Close") { self.selectedPath = nil; live = false }
                }
                if let error { Text(error).foregroundStyle(.orange) }
                ScrollView([.vertical, .horizontal]) {
                    Text(output.isEmpty ? "No content available." : output).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 300)
            }
        }
        .task(id: inventory?.files.map { $0.id + $0.processes.map(\.id).joined(separator: "#") } ?? []) {
            let paths = inventory?.files ?? []
            let discovered = await Task.detached(priority: .utility) { ApplicationLogFiles.discover(paths) }.value
            guard !Task.isCancelled else { return }
            files = discovered
        }
        .task(id: "\(selectedPath ?? "")#\(live)") {
            guard let selectedPath else { return }
            repeat {
                let result = await Task.detached(priority: .utility) { Result { try ApplicationLogFiles.read(selectedPath) } }.value
                guard !Task.isCancelled else { return }
                switch result {
                case .success(let text): output = text; error = nil
                case .failure(let failure): output = ""; error = failure.localizedDescription
                }
                if !live { break }
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            } while !Task.isCancelled
        }
    }
}
