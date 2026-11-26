import Foundation

/// One condition worth the user's attention right now, shown at the top of Summary and linked to its Page.
struct SummaryConcern: Equatable {
    enum Level: Int, Comparable, Sendable {
        case notice, warning, critical
        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var level: Level
    var text: String
    var route: AppRoute
}

/// Derives concerns from the latest Live Data only; nothing here samples.
enum SummaryConcerns {
    static let busyCPU: Double = 85
    static let lowBattery: Double = 20
    static let criticalBattery: Double = 10

    static func evaluate(system: SystemSample?, posture: PostureSnapshot?) -> [SummaryConcern] {
        var concerns: [SummaryConcern] = []
        if let system {
            switch system.thermalCondition {
            case .serious, .critical:
                concerns.append(SummaryConcern(level: .critical, text: "Thermal State \(system.thermalCondition.rawValue)", route: .resource(.thermal)))
            case .fair:
                concerns.append(SummaryConcern(level: .notice, text: "Thermal State fair", route: .resource(.thermal)))
            case .nominal, .unavailable: break
            }
            switch system.memory.pressure {
            case .critical: concerns.append(SummaryConcern(level: .critical, text: "Memory pressure critical", route: .resource(.memory)))
            case .warning: concerns.append(SummaryConcern(level: .warning, text: "Memory pressure warning", route: .resource(.memory)))
            case .normal, .unavailable: break
            }
            if let battery = system.battery, battery.isPresent, !battery.isCharging, battery.isOnBattery == true,
               let charge = battery.chargePercent, charge <= lowBattery {
                concerns.append(SummaryConcern(level: charge <= criticalBattery ? .warning : .notice, text: "Battery \(Int(charge))%", route: .resource(.battery)))
            }
        }
        if let posture {
            let findings = posture.checks.count { $0.status == .warn || $0.status == .fail }
            if findings > 0 {
                concerns.append(SummaryConcern(level: .warning, text: "\(findings) security \(findings == 1 ? "finding" : "findings")", route: .security))
            }
        }
        if let cpu = system?.cpu, cpu.hasUsage, cpu.totalUsage >= busyCPU {
            concerns.append(SummaryConcern(level: .notice, text: "CPU busy \(Int(cpu.totalUsage.rounded()))%", route: .resource(.cpu)))
        }
        return concerns.enumerated()
            .sorted { $0.element.level != $1.element.level ? $0.element.level > $1.element.level : $0.offset < $1.offset }
            .map(\.element)
    }
}
