import Foundation

/// Logical cores grouped by performance level (for example "Super" and "Performance" on M5, "Performance" and
/// "Efficiency" on earlier Apple silicon), so per-core usage can be shown per cluster type.
struct CPUTopology: Sendable, Equatable {
    struct Group: Sendable, Equatable, Identifiable {
        var id: String { name }
        let name: String
        /// Indexes into `CPUSample.coreUsage`.
        let cores: Range<Int>
    }

    let processorName: String?
    let groups: [Group]

    /// Read once: the hardware does not change while Smack runs.
    static let current: CPUTopology = {
        let levels = Int(SystemInformation.integer("hw.nperflevels") ?? 0)
        let perfLevels = (0..<levels).compactMap { level -> (name: String, count: Int)? in
            guard let count = SystemInformation.integer("hw.perflevel\(level).logicalcpu") else { return nil }
            return (SystemInformation.string("hw.perflevel\(level).name") ?? "Cluster \(level + 1)", Int(count))
        }
        return CPUTopology(
            processorName: SystemInformation.string("machdep.cpu.brand_string"),
            perfLevels: perfLevels,
            coreCount: Int(SystemInformation.integer("hw.logicalcpu") ?? 0)
        )
    }()

    init(processorName: String?, groups: [Group]) {
        self.processorName = processorName
        self.groups = groups
    }

    /// `perfLevels` is in sysctl order, fastest first. Apple silicon numbers logical CPUs from the slowest level
    /// up, so groups are sliced in reverse and then listed fastest first. Counts that do not add up (Intel, a
    /// missing sysctl) give one "Cores" group.
    init(processorName: String?, perfLevels: [(name: String, count: Int)], coreCount: Int) {
        self.processorName = processorName
        guard perfLevels.count > 1, perfLevels.allSatisfy({ $0.count > 0 }),
              perfLevels.reduce(0, { $0 + $1.count }) == coreCount else {
            groups = coreCount > 0 ? [Group(name: "Cores", cores: 0..<coreCount)] : []
            return
        }
        var start = 0
        var sliced: [Group] = []
        for level in perfLevels.reversed() {
            sliced.append(Group(name: level.name, cores: start..<(start + level.count)))
            start += level.count
        }
        groups = sliced.reversed()
    }

    /// Groups clipped to the cores actually sampled; one group when the sample does not match the topology.
    func groups(forCoreCount count: Int) -> [Group] {
        guard count > 0 else { return [] }
        if groups.map(\.cores.upperBound).max() == count { return groups }
        return [Group(name: "Cores", cores: 0..<count)]
    }
}