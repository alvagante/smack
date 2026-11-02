import SwiftUI

/// Shared title row of every page: icon and title with a one-line description, the key figures, then the page
/// actions aligned right. On a narrow panel the figures move under the title.
struct DetailPageHeader<Title: View, Actions: View, Overview: View>: View {
    /// Matches the padding of the content below, so header and body share one leading edge.
    var padding: CGFloat = MonitorStyle.inset
    @ViewBuilder var title: Title
    @ViewBuilder var actions: Actions
    @ViewBuilder var overview: Overview

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                title.fixedSize()
                overview
                Spacer(minLength: 0)
                actionsView
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: MonitorStyle.spacing) {
                    title
                    Spacer(minLength: 0)
                    actionsView
                }
                overview
            }
        }
        .padding(padding)
    }

    private var actionsView: some View {
        HStack(spacing: 8) { actions }.fixedSize()
    }
}

struct DetailNavigationStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.12) :
                configuration.isPressed ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
