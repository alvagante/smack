import SwiftUI

/// Tree mode of the process list. Same metric columns as the flat list.
struct ProcessTreeList: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var model: ApplicationListViewModel
    let metricWidth: CGFloat
    let diskWidth: CGFloat
    let wakeupsWidth: CGFloat

    var body: some View {
        let roots = ProcessTreeBuilder.build(
            applications: store.processes?.applications ?? [],
            background: store.processes?.backgroundProcesses ?? []
        )
        let rows = ProcessTreeBuilder.flatten(roots, collapsed: model.collapsed, query: model.query, areInIncreasingOrder: ordered)
        List(rows) { row in
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Color.clear.frame(width: CGFloat(min(row.depth, 12)) * 14, height: 1)
                    disclosure(row)
                    Image(systemName: row.node.isExitedParent ? "questionmark.circle" : "terminal")
                        .foregroundStyle(.secondary)
                    Text(row.node.title).lineLimit(1)
                        .foregroundStyle(row.node.isExitedParent ? .secondary : .primary)
                    if let process = row.node.process {
                        Text("\(process.identity.pid)").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let process = row.node.process {
                    metric(Formatting.percent(process.cpuUsage), metricWidth)
                    metric(Capabilities.isSandboxed && process.memoryBytes == 0 ? "—" : Formatting.bytes(process.memoryBytes), metricWidth)
                    metric(Capabilities.isSandboxed && process.diskReadRate + process.diskWriteRate == 0 ? "—" : Formatting.rate(process.diskReadRate + process.diskWriteRate), diskWidth)
                    metric(process.energyImpact.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—", metricWidth)
                    metric(ApplicationListView.wakeups(process.wakeupsPerSecond), wakeupsWidth)
                } else {
                    Spacer().frame(width: metricWidth * 3 + diskWidth + wakeupsWidth - metricWidth)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if let process = row.node.process { store.route = .process(process.id) } }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func disclosure(_ row: ProcessTreeRow) -> some View {
        if row.hasChildren {
            Button {
                if row.isCollapsed { model.collapsed.remove(row.id) } else { model.collapsed.insert(row.id) }
            } label: {
                Image(systemName: row.isCollapsed ? "chevron.right" : "chevron.down").font(.caption2).frame(width: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.isCollapsed ? "Expand" : "Collapse")
        } else {
            Color.clear.frame(width: 12, height: 1)
        }
    }

    private func metric(_ value: String, _ width: CGFloat) -> some View {
        Text(value).font(.callout).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    private func value(_ node: ProcessTreeNode) -> Double {
        guard let process = node.process else { return 0 }
        return switch model.sort {
        case .cpu: process.cpuUsage
        case .memory: Double(process.memoryBytes)
        case .disk: process.diskReadRate + process.diskWriteRate
        case .energy: process.energyImpact ?? 0
        case .wakeups: process.wakeupsPerSecond
        case .name: 0
        }
    }

    private func ordered(_ lhs: ProcessTreeNode, _ rhs: ProcessTreeNode) -> Bool {
        if model.sort == .name {
            let result = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            return model.ascending ? result == .orderedAscending : result == .orderedDescending
        }
        let (a, b) = (value(lhs), value(rhs))
        if a == b { return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
        return model.ascending ? a < b : a > b
    }
}
