import SwiftUI

/// How each baseline section reads on screen; unknown sections fall back to their raw ID.
enum BaselineSectionStyle {
    static func title(_ id: String) -> String {
        switch id {
        case "system": "System"
        case "posture": "Security posture"
        case "startup": "Startup items"
        case "listeners": "Listening ports"
        case "apps": "Apps"
        case "homebrew": "Homebrew"
        case "runtimes": "Runtimes"
        case "agents": "Agents"
        case "profiles": "Profiles"
        case "systemExtensions": "System extensions"
        case "docker": "Docker"
        default: id
        }
    }

    static func systemImage(_ id: String) -> String {
        switch id {
        case "system": "desktopcomputer"
        case "posture": "checkmark.shield"
        case "startup": "power"
        case "listeners": "dot.radiowaves.left.and.right"
        case "apps": "app.badge"
        case "homebrew": "mug"
        case "runtimes": "chevron.left.forwardslash.chevron.right"
        case "agents": "sparkles"
        case "profiles": "person.badge.key"
        case "systemExtensions": "puzzlepiece.extension"
        case "docker": "shippingbox"
        default: "square.dashed"
        }
    }
}

/// The three kinds of drift, with one colour and glyph each across the summary, bars and rows.
enum BaselineChangeKind: CaseIterable {
    case added, removed, changed

    var title: String {
        switch self {
        case .added: "Added"
        case .removed: "Removed"
        case .changed: "Changed"
        }
    }

    var color: Color {
        switch self {
        case .added: .green
        case .removed: .red
        case .changed: .orange
        }
    }

    var systemImage: String {
        switch self {
        case .added: "plus"
        case .removed: "minus"
        case .changed: "arrow.triangle.2.circlepath"
        }
    }

    func count(_ section: BaselineDiffResult.Section) -> Int {
        switch self {
        case .added: section.added.count
        case .removed: section.removed.count
        case .changed: section.changed.count
        }
    }
}

/// One side of a comparison: which capture, when, and on what Mac.
struct BaselineEndpoint<Picker: View>: View {
    let role: String
    let title: String
    let date: Date?
    let machine: [String: String]?
    let color: Color
    let isLive: Bool
    @ViewBuilder let picker: Picker

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: isLive ? "dot.radiowaves.forward" : "archivebox")
                    .foregroundStyle(color)
                Text(role.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.8)
            }
            Text(title.isEmpty ? "Unnamed" : title)
                .font(.title3.weight(.semibold)).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            picker.labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.25)))
    }

    private var subtitle: String {
        if isLive { return "Fresh capture at compare time" }
        var parts: [String] = []
        if let date { parts.append(Formatting.dated(date.formatted(date: .abbreviated, time: .shortened), date)) }
        if let macOS = machine?["macOS"] { parts.append("macOS " + macOS) }
        return parts.isEmpty ? "No baseline selected" : parts.joined(separator: " · ")
    }
}

/// Drift report: totals, a per-section map to pick from, then the itemised differences.
struct BaselineDriftReport: View {
    let diff: BaselineDiffResult
    @State private var selectedSection: String?
    @State private var showRaw = false

    private static let rowLimit = 200

    private var sectionIDs: [String] {
        diff.sections.keys.sorted { lhs, rhs in
            let l = diff.sections[lhs]!, r = diff.sections[rhs]!
            if (l.count > 0) != (r.count > 0) { return l.count > 0 }
            if l.count != r.count { return l.count > r.count }
            return BaselineSectionStyle.title(lhs) < BaselineSectionStyle.title(rhs)
        }
    }

    private func total(_ kind: BaselineChangeKind) -> Int {
        diff.sections.values.reduce(0) { $0 + kind.count($1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            timeline
            totals
            sectionMap
            if diff.drift { details } else { cleanState }
            DisclosureGroup("Plain-text report", isExpanded: $showRaw) {
                Text(diff.markdown).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
        .onChange(of: diff) { selectedSection = nil }
    }

    // MARK: Summary

    private var timeline: some View {
        HStack(spacing: 8) {
            Text(diff.baseCapturedAt.formatted(date: .abbreviated, time: .shortened))
            Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1).frame(maxWidth: 80)
                .overlay { Text(span).font(.caption2).padding(.horizontal, 4).background(MonitorStyle.surface) }
            Image(systemName: "arrow.right").font(.caption2)
            Text(diff.againstCapturedAt.formatted(date: .abbreviated, time: .shortened))
            Spacer()
            if machineChanged {
                DetailBadge(text: "Different Mac or macOS", systemImage: "exclamationmark.triangle", color: .orange)
                    .help("Base: \(machineLine(diff.baseMachine))\nAgainst: \(machineLine(diff.againstMachine))")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var span: String {
        let seconds = abs(diff.againstCapturedAt.timeIntervalSince(diff.baseCapturedAt))
        if seconds < 60 { return "same minute" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }

    private var machineChanged: Bool {
        diff.baseMachine["model"] != diff.againstMachine["model"] || diff.baseMachine["macOS"] != diff.againstMachine["macOS"]
    }

    private func machineLine(_ machine: [String: String]) -> String {
        "\(machine["model"] ?? "?"), macOS \(machine["macOS"] ?? "?")"
    }

    private var totals: some View {
        let skipped = diff.sections.values.filter { $0.reason != nil }.count
        let all = BaselineChangeKind.allCases.reduce(0) { $0 + total($1) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(BaselineChangeKind.allCases, id: \.self) { kind in
                    TotalTile(value: total(kind), title: kind.title, systemImage: kind.systemImage, color: kind.color)
                }
                TotalTile(value: skipped, title: "Not compared", systemImage: "questionmark", color: .secondary)
            }
            DriftBar(segments: BaselineChangeKind.allCases.map { (total($0), $0.color) }, height: 8)
                .opacity(all == 0 ? 0.4 : 1)
        }
    }

    // MARK: Sections

    private var sectionMap: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
            ForEach(sectionIDs, id: \.self) { id in
                let section = diff.sections[id]!
                SectionTile(id: id, section: section, selected: selectedSection == id) {
                    selectedSection = selectedSection == id ? nil : id
                }
                .disabled(section.count == 0)
            }
        }
    }

    private var cleanState: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").font(.title).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Matches the baseline").font(.headline)
                Text("Every compared section is identical.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Details

    private var details: some View {
        let ids = sectionIDs.filter { (selectedSection == nil || $0 == selectedSection) && diff.sections[$0]!.count > 0 }
        return VStack(alignment: .leading, spacing: 12) {
            if let selectedSection {
                HStack {
                    Text("Showing \(BaselineSectionStyle.title(selectedSection))").font(.caption).foregroundStyle(.secondary)
                    Button("Show all sections") { self.selectedSection = nil }.buttonStyle(.link).font(.caption)
                }
            }
            ForEach(ids, id: \.self) { id in sectionDetail(id, diff.sections[id]!) }
        }
    }

    private func sectionDetail(_ id: String, _ section: BaselineDiffResult.Section) -> some View {
        let fields = BaselineDiff.rules[id]?.fields ?? []
        let rows: [AnyView] =
            section.added.map { AnyView(ItemRow(kind: .added, label: BaselineDiff.label($0, section: id), detail: detail($0, fields))) }
            + section.removed.map { AnyView(ItemRow(kind: .removed, label: BaselineDiff.label($0, section: id), detail: detail($0, fields))) }
            + section.changed.map { AnyView(ChangeRow(change: $0)) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ResourceIcon(systemImage: BaselineSectionStyle.systemImage(id), color: .indigo, size: 20)
                Text(BaselineSectionStyle.title(id)).font(.subheadline.weight(.semibold))
                ForEach(BaselineChangeKind.allCases, id: \.self) { kind in
                    let count = kind.count(section)
                    if count > 0 { DetailBadge(text: "\(count) \(kind.title.lowercased())", color: kind.color) }
                }
            }
            .padding(.bottom, 2)
            ForEach(Array(rows.prefix(Self.rowLimit).enumerated()), id: \.offset) { _, row in row }
            if rows.count > Self.rowLimit {
                Text("\(rows.count - Self.rowLimit) more in the exported report").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The compared fields an added or removed item carries, e.g. its version, as a short secondary line.
    private func detail(_ item: BaselineItem, _ fields: [String]) -> String {
        fields.compactMap { field in item[field].flatMap { $0.isEmpty ? nil : "\(field) \($0)" } }.joined(separator: " · ")
    }
}

// MARK: - Pieces

/// Proportional coloured segments; an all-zero bar draws as an empty track.
private struct DriftBar: View {
    let segments: [(Int, Color)]
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let total = segments.reduce(0) { $0 + $1.0 }
            HStack(spacing: total > 0 ? 2 : 0) {
                if total == 0 {
                    Capsule().fill(.secondary.opacity(0.15))
                } else {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        if segment.0 > 0 {
                            Capsule().fill(segment.1.gradient)
                                .frame(width: max(height, proxy.size.width * CGFloat(segment.0) / CGFloat(total) - 2))
                        }
                    }
                }
            }
        }
        .frame(height: height)
    }
}

private struct TotalTile: View {
    let value: Int
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(value > 0 ? .white : .secondary)
                .frame(width: 22, height: 22)
                .background(value > 0 ? AnyShapeStyle(color.gradient) : AnyShapeStyle(.secondary.opacity(0.15)), in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(value.formatted()).font(.title2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(value > 0 ? .primary : .secondary)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(color.opacity(value > 0 ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SectionTile: View {
    let id: String
    let section: BaselineDiffResult.Section
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: BaselineSectionStyle.systemImage(id)).foregroundStyle(tint).frame(width: 16)
                    Text(BaselineSectionStyle.title(id)).font(.caption.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    status
                }
                DriftBar(segments: BaselineChangeKind.allCases.map { ($0.count(section), $0.color) })
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(section.reason.map { "Not compared: " + $0 } ?? (section.count > 0 ? "Show only this section" : "No changes"))
    }

    private var tint: Color {
        if section.reason != nil { return .secondary }
        return section.count > 0 ? .orange : .green
    }

    @ViewBuilder private var status: some View {
        if section.reason != nil {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary).font(.caption)
        } else if section.count == 0 {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        } else {
            Text(section.count.formatted()).font(.caption.weight(.bold)).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.orange.opacity(0.18), in: Capsule())
        }
    }
}

private struct KindGlyph: View {
    let kind: BaselineChangeKind

    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(kind.color.gradient, in: Circle())
    }
}

private struct ItemRow: View {
    let kind: BaselineChangeKind
    let label: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            KindGlyph(kind: kind).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.callout).strikethrough(kind == .removed, color: .red.opacity(0.6))
                    .foregroundStyle(kind == .removed ? .secondary : .primary)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(kind.color.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct ChangeRow: View {
    let change: BaselineDiffResult.Change

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            KindGlyph(kind: .changed).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 4) {
                Text(change.displayIdentity ?? change.identity).font(.callout)
                ForEach(change.fields.keys.sorted(), id: \.self) { field in
                    let value = change.fields[field]!
                    HStack(spacing: 6) {
                        Text(field).font(.caption).foregroundStyle(.secondary).frame(minWidth: 60, alignment: .leading)
                        valueChip(value.old, color: .red, struck: true)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        valueChip(value.new, color: .green, struck: false)
                    }
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
    }

    private func valueChip(_ value: String?, color: Color, struck: Bool) -> some View {
        Text(value ?? "absent")
            .font(.caption.monospaced())
            .italic(value == nil)
            .strikethrough(struck && value != nil, color: color.opacity(0.6))
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}
