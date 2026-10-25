import SwiftUI

struct SystemDetailsView: View {
    @ObservedObject var store: MonitorStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "System Details")
                KeyValueRow(key: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                KeyValueRow(key: "Logical Cores", value: String(ProcessInfo.processInfo.processorCount))
                KeyValueRow(key: "Physical Memory", value: Formatting.bytes(UInt64(ProcessInfo.processInfo.physicalMemory)))
                KeyValueRow(key: "GPU", value: store.system?.gpuName.isEmpty == false ? store.system!.gpuName : "Unavailable")
                KeyValueRow(key: "Thermal State", value: store.system?.thermalCondition.rawValue.capitalized ?? "Unavailable")
                SectionHeader(title: "Availability")
                Text("Exact temperatures, fan RPM, systemwide GPU utilization, and per-application network throughput are not collected because macOS has no supported lightweight public API for them.")
                Text("Processes owned by other users or protected by macOS can show Permission denied or Unavailable. Smack does not install a privileged helper.")
                SectionHeader(title: "Camera Hot Zone")
                Text("Hover detection uses a best-effort screen region beside the camera housing. The menu-bar icon is the reliable trigger on every display, including displays without a housing.")
            }.padding().textSelection(.enabled)
        }
    }
}
