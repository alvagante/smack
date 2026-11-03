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

/// Sidebar row. Prominent rows (the panel sidebar) fill the selection with the accent color; section sidebars tint it.
struct DetailNavigationStyle: ButtonStyle {
    var selected: Bool
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(prominent ? .body : .callout.weight(selected ? .semibold : .regular))
            .foregroundStyle(prominent && selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, SidebarStyle.rowInset)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: SidebarStyle.rowHeight, alignment: .leading)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: SidebarStyle.cornerRadius, style: .continuous))
            .contentShape(Rectangle())
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func background(pressed: Bool) -> Color {
        if selected { return prominent ? .accentColor : .accentColor.opacity(0.12) }
        return pressed ? .primary.opacity(0.06) : .clear
    }
}
