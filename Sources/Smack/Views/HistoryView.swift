import SwiftUI
import Charts

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var metric = SystemMetric.cpu
    @Published var processMetric = ProcessMetric.cpuUsage
    @Published var hours = 1.0
    @Published var points: [HistoricalPoint] = []
    @Published var loading = false
    @Published var query = ""
    @Published var processes: [HistoricalProcess] = []
    @Published var selectedProcess: HistoricalProcess?
    var requestID: String { "\(selectedProcess?.id ?? metric.rawValue)-\(processMetric.rawValue)-\(hours)" }
}

struct HistoryView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var model: HistoryViewModel

    init(store: MonitorStore) {
        self.store = store
        model = store.historyViewModel
    }

    var body: some View {
        VStack(alignment: .leading) {
            if let process = model.selectedProcess {
                HStack {
                    Button("All History") { model.selectedProcess = nil }
                    Text(process.name).font(.headline)
                }.padding([.horizontal, .top])
                Picker("Metric", selection: $model.processMetric) {
                    ForEach(ProcessMetric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.padding(.horizontal)
            } else {
                Picker("Metric", selection: $model.metric) { ForEach(SystemMetric.allCases) { Text($0.rawValue).tag($0) } }
                    .padding([.horizontal, .top])
            }
            Picker("Range", selection: $model.hours) {
                Text("1 hour").tag(1.0)
                Text("24 hours").tag(24.0)
                Text("7 days").tag(168.0)
            }.padding(.horizontal)
            if model.loading { ProgressView().frame(maxWidth: .infinity) }
            Chart(model.points) { point in
                LineMark(x: .value("Time", point.timestamp), y: .value("Average", point.average))
                LineMark(x: .value("Time", point.timestamp), y: .value("Peak", point.peak)).foregroundStyle(.orange).lineStyle(StrokeStyle(dash: [3]))
            }.frame(minHeight: 180).padding()
            if model.selectedProcess == nil {
                TextField("Search current and exited process history", text: $model.query).textFieldStyle(.roundedBorder).padding(.horizontal)
                List(model.processes) { process in
                    Button { model.selectedProcess = process } label: {
                        HStack {
                            Text(process.name)
                            Spacer()
                            Text(process.lastSeen, style: .relative).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }.frame(minHeight: 160)
            }
            Text("Full resolution lasts 24 hours; older one-minute points preserve averages and peaks. Disabling collection does not delete history.")
                .font(.caption).foregroundStyle(.secondary).padding([.horizontal, .bottom])
        }
        .task(id: model.requestID) { await reload() }
        .task(id: model.query) { await searchProcesses() }
    }

    private func reload() async {
        model.loading = true
        if let process = model.selectedProcess {
            model.points = await store.processHistory(processID: process.id, metric: model.processMetric, hours: model.hours)
        } else {
            model.points = await store.systemHistory(model.metric, hours: model.hours)
        }
        model.loading = false
    }

    private func searchProcesses() async {
        do { model.processes = try await store.history.historicalProcesses(matching: model.query) }
        catch { store.errorMessage = error.localizedDescription }
    }
}
