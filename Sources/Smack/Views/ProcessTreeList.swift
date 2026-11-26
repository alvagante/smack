import SwiftUI

/// Tree mode of the process list. Same metric columns as the flat list.
struct ProcessTreeList: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var model: ApplicationListViewModel
    let layout: ApplicationListLayout
    let context: ApplicationListContext

    var body: some View {
        let roots = ProcessTreeBuilder.build(
            applications: store.processes?.applications ?? [],
            background: store.processes?.backgroundProcesses ?? []
        )
        let rows = ProcessTreeBuilder.flatten(roots, collapsed: model.collapsed, query: model.query, areInIncreasingOrder: ordered)
        let currentUser = NSUserName()
        List(rows) { row in
            HStack(spacing: ApplicationListLayout.spacing) {
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
                    let entry = ApplicationListEntry(process: process, currentUser: currentUser, context: context)
                    ForEach(layout.columns) { column in
                        ApplicationListCell(entry: entry, column: column)
                        // Live points are kept per application and background process, not per member process.
                        if column == .cpu, layout.showsTrend { Color.clear.frame(width: ApplicationListLayout.trendWidth, height: 1) }
                    }
                    ApplicationListActions(entry: entry) { model.requestKill(entry) }
                } else {
                    Color.clear.frame(width: placeholderWidth, height: 1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if let process = row.node.process { store.route = .process(process.id) } }
        }
        .listStyle(.plain)
    }

    /// Width of the value columns and actions, kept by exited parents so their children stay aligned.
    private var placeholderWidth: CGFloat {
        let values = layout.columns.reduce(0) { $0 + $1.columnWidth } + (layout.showsTrend ? ApplicationListLayout.trendWidth : 0)
        let cells = layout.columns.count + (layout.showsTrend ? 1 : 0) + 1
        return values + ApplicationListLayout.actionsWidth + CGFloat(cells - 1) * ApplicationListLayout.spacing
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

    private func value(_ node: ProcessTreeNode) -> Double {
        guard let process = node.process else { return 0 }
        return switch model.sort {
        case .cpu: process.cpuUsage
        case .memory: Double(process.memoryBytes)
        case .disk: process.diskReadRate + process.diskWriteRate
        case .network: process.networkThroughput?.total ?? 0
        case .energy: process.energyImpact ?? 0
        case .wakeups: process.wakeupsPerSecond
        case .threads: Double(process.threadCount)
        case .ports: Double(context.portsByPID?[process.identity.pid]?.count ?? 0)
        case .uptime: -process.identity.startTime.timeIntervalSince1970
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
