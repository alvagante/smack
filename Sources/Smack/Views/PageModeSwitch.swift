import SwiftUI

/// One destination of a page's mode switch.
struct PageModeOption<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    let systemImage: String
    var count: Int? = nil
    var help = ""
}

/// A larger segmented switch with an icon and a live count per mode, for the top-right of an inventory page.
struct PageModeSwitch<ID: Hashable>: View {
    let options: [PageModeOption<ID>]
    @Binding var selection: ID

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button { selection = option.id } label: {
                    HStack(spacing: 6) {
                        Image(systemName: option.systemImage).font(.system(size: 13, weight: .semibold))
                        Text(option.title).font(.callout.weight(.semibold)).lineLimit(1)
                        if let count = option.count {
                            Text(count.formatted()).font(.caption.weight(.bold)).monospacedDigit()
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background((selection == option.id ? Color.accentColor : Color.secondary).opacity(0.18), in: Capsule())
                        }
                    }
                    .foregroundStyle(selection == option.id ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(selection == option.id ? Color.accentColor.opacity(0.16) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(option.help.isEmpty ? option.title : option.help)
                .accessibilityAddTraits(selection == option.id ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .fixedSize()
    }
}
