import SwiftUI

struct SystemDetailsView: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "System Details")
                KeyValueRow(key: "Mac Model", value: SystemInformation.modelIdentifier)
                KeyValueRow(key: "macOS", value: SystemInformation.macOSDescription)
                KeyValueRow(key: "Logical Cores", value: String(ProcessInfo.processInfo.processorCount))
                KeyValueRow(key: "Physical Memory", value: Formatting.bytes(ProcessInfo.processInfo.physicalMemory))
                KeyValueRow(key: "GPU", value: store.system?.gpuName.isEmpty == false ? store.system!.gpuName : "Unavailable")
                KeyValueRow(key: "Thermal State", value: store.system?.thermalCondition.rawValue.capitalized ?? "Unavailable")
                Button("Advanced") { store.route = .advancedSystemDetails }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .textSelection(.enabled)
        }
    }
}

struct AdvancedSystemDetailsView: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(SystemInformation.advancedSections(
                    gpuName: store.system?.gpuName ?? "",
                    volumes: store.system?.volumes ?? []
                )) { section in
                    SectionHeader(title: section.title)
                    ForEach(section.rows) { row in
                        KeyValueRow(key: row.key, value: row.value)
                    }
                }
            }
            .padding()
            .textSelection(.enabled)
        }
    }
}
