import SwiftUI

enum SummaryApplicationRanking {
    struct Row: Identifiable {
        let application: ApplicationMetrics
        let value: Double
        var id: String { application.id }
    }

    static func top(_ applications: [ApplicationMetrics], resource: ResourceKind,
                    gpuUsage: (String) -> Double? = { _ in nil }) -> [Row] {
        applications.compactMap { application -> Row? in
            let value: Double?
            switch resource {
            case .cpu: value = application.cpuUsage
            case .memory: value = Double(application.memoryBytes)
            case .disk: value = application.diskReadRate + application.diskWriteRate
            case .network: value = application.networkThroughput?.total
            case .gpu: value = gpuUsage(application.id)
            default: value = nil
            }
            guard let value, value.isFinite, value >= 0 else { return nil }
            return Row(application: application, value: value)
        }.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return ($0.application.name, $0.id) < ($1.application.name, $1.id)
        }.prefix(5).map { $0 }
    }

    static func formatted(_ value: Double, resource: ResourceKind) -> String {
        switch resource {
        case .memory: Formatting.bytes(UInt64(value))
        case .network, .disk: Formatting.rate(value)
        default: Formatting.percent(value)
        }
    }
}

struct SummaryTopApplications: View {
    let applications: [ApplicationMetrics]
    let resource: ResourceKind
    var gpuUsage: (String) -> Double? = { _ in nil }
    var unavailable: String? = nil
    let open: (String) -> Void

    var body: some View {
        let rows = SummaryApplicationRanking.top(applications, resource: resource, gpuUsage: gpuUsage)
        VStack(alignment: .leading, spacing: 6) {
            Text("Top applications").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let unavailable {
                Text(unavailable).font(.caption).foregroundStyle(.secondary)
            } else if rows.isEmpty {
                Text(resource == .gpu ? "No per-application GPU samples available" :
                     resource == .network ? "No per-application network samples available" : "Awaiting application samples")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    Button { open(row.id) } label: {
                        HStack(spacing: 8) {
                            ApplicationIcon(application: row.application, size: 16)
                            Text(row.application.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(SummaryApplicationRanking.formatted(row.value, resource: resource))
                                .monospacedDigit().foregroundStyle(.secondary).fixedSize()
                        }
                        .font(.caption)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open " + row.application.name)
                }
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
