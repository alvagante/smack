import Foundation

struct ProcessTreeNode: Identifiable, Sendable {
    var id: String
    /// nil for a synthetic node (launchd that is not visible, or an exited parent).
    var process: ProcessMetrics?
    var title: String
    var isExitedParent: Bool
    var children: [ProcessTreeNode] = []
}

struct ProcessTreeRow: Identifiable, Sendable {
    var node: ProcessTreeNode
    var depth: Int
    var hasChildren: Bool
    var isCollapsed: Bool
    var id: String { node.id }
}

enum ProcessListMode: String, CaseIterable, Identifiable {
    case flat = "Flat"
    case tree = "Tree"
    var id: Self { self }
}

enum ProcessTreeBuilder {
    /// Deduplicates by identity (helpers appear in both an application group and the background list), links
    /// children to parents, adds synthetic nodes for missing parents, and breaks cycles.
    static func build(applications: [ApplicationMetrics], background: [ProcessMetrics]) -> [ProcessTreeNode] {
        var byIdentity: [String: ProcessMetrics] = [:]
        for process in applications.flatMap(\.processes) + background { byIdentity[process.id] = process }
        return build(processes: Array(byIdentity.values))
    }

    static func build(processes: [ProcessMetrics]) -> [ProcessTreeNode] {
        var byPID: [Int32: ProcessMetrics] = [:]
        for process in processes { byPID[process.identity.pid] = process }

        // Children per parent PID. Parentless, self-parented and negative parents are orphans at the root.
        var childrenOf: [Int32: [ProcessMetrics]] = [:]
        var orphans: [ProcessMetrics] = []
        for process in byPID.values.sorted(by: { $0.identity.pid < $1.identity.pid }) {
            guard let parent = process.parentPID, parent > 0, parent != process.identity.pid else {
                orphans.append(process)
                continue
            }
            childrenOf[parent, default: []].append(process)
        }

        var visited: Set<Int32> = []

        func node(for process: ProcessMetrics) -> ProcessTreeNode {
            visited.insert(process.identity.pid)
            var result = ProcessTreeNode(id: process.id, process: process, title: process.name, isExitedParent: false)
            for child in childrenOf[process.identity.pid] ?? [] where !visited.contains(child.identity.pid) {
                result.children.append(node(for: child))
            }
            return result
        }

        var roots: [ProcessTreeNode] = []

        // launchd first when visible, or synthetic when its children exist but it is hidden (sandbox).
        if let launchd = byPID[1] {
            roots.append(node(for: launchd))
        } else if let children = childrenOf[1], !children.isEmpty {
            var synthetic = ProcessTreeNode(id: "synthetic-launchd", process: nil, title: "launchd", isExitedParent: false)
            for child in children where !visited.contains(child.identity.pid) { synthetic.children.append(node(for: child)) }
            roots.append(synthetic)
        }

        // Parents that are not in the snapshot: group their children under one synthetic node each.
        for parentPID in childrenOf.keys.sorted() where byPID[parentPID] == nil && parentPID != 1 {
            let children = (childrenOf[parentPID] ?? []).filter { !visited.contains($0.identity.pid) }
            guard !children.isEmpty else { continue }
            var synthetic = ProcessTreeNode(id: "exited-parent-\(parentPID)", process: nil, title: "Exited parent (\(parentPID))", isExitedParent: true)
            for child in children { synthetic.children.append(node(for: child)) }
            roots.append(synthetic)
        }

        for orphan in orphans where !visited.contains(orphan.identity.pid) { roots.append(node(for: orphan)) }

        // Anything still unvisited sits on a cycle: cut it at the lowest PID.
        for process in byPID.values.sorted(by: { $0.identity.pid < $1.identity.pid }) where !visited.contains(process.identity.pid) {
            roots.append(node(for: process))
        }
        return roots
    }

    /// Flattens for a List. Rows below a collapsed node are skipped. A query keeps nodes that match or have a
    /// matching descendant, and expands them.
    static func flatten(
        _ roots: [ProcessTreeNode],
        collapsed: Set<String>,
        query: String,
        areInIncreasingOrder: (ProcessTreeNode, ProcessTreeNode) -> Bool
    ) -> [ProcessTreeRow] {
        let searching = !query.isEmpty
        func matches(_ node: ProcessTreeNode) -> Bool {
            node.title.localizedCaseInsensitiveContains(query)
                || node.process?.bundleIdentifier?.localizedCaseInsensitiveContains(query) == true
        }
        func keeps(_ node: ProcessTreeNode) -> Bool {
            !searching || matches(node) || node.children.contains(where: keeps)
        }
        var rows: [ProcessTreeRow] = []
        func visit(_ node: ProcessTreeNode, depth: Int) {
            guard keeps(node) else { return }
            let visibleChildren = node.children.filter(keeps).sorted(by: areInIncreasingOrder)
            let isCollapsed = !searching && collapsed.contains(node.id)
            rows.append(ProcessTreeRow(node: node, depth: depth, hasChildren: !visibleChildren.isEmpty, isCollapsed: isCollapsed))
            guard !isCollapsed else { return }
            for child in visibleChildren { visit(child, depth: depth + 1) }
        }
        for root in roots { visit(root, depth: 0) }
        return rows
    }
}
