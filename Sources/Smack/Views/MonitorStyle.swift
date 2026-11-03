import SwiftUI

/// Semantic macOS colors follow system appearance, contrast and the user's accent color.
enum MonitorStyle {
    static let page = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .windowBackgroundColor).mix(with: .black, by: 0.06)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let inset: CGFloat = 24
    static let spacing: CGFloat = 16
    static let radius: CGFloat = 10
    static let title = Font.system(size: 20, weight: .semibold)
}

/// Metrics shared by the panel sidebar and every page's section sidebar, so their rows and headers line up.
enum SidebarStyle {
    static let padding: CGFloat = 12
    /// Horizontal padding inside a row; section headers use it too, so their text starts at the icons' edge.
    static let rowInset: CGFloat = 10
    static let rowHeight: CGFloat = 34
    static let rowSpacing: CGFloat = 2
    static let groupSpacing: CGFloat = 16
    static let iconSpacing: CGFloat = 10
    static let iconSize: CGFloat = 20
    static let cornerRadius: CGFloat = 7
}

/// Small caption above a group of sidebar rows.
struct SidebarHeader: View {
    let title: String
    var isFirst = false

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, SidebarStyle.rowInset)
            .padding(.top, isFirst ? 0 : SidebarStyle.groupSpacing)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

struct MonitorSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(MonitorStyle.surface, in: RoundedRectangle(cornerRadius: MonitorStyle.radius))
            .overlay {
                RoundedRectangle(cornerRadius: MonitorStyle.radius)
                    .strokeBorder(MonitorStyle.separator.opacity(0.5), lineWidth: 0.5)
            }
    }
}

extension View {
    func monitorSurface() -> some View { modifier(MonitorSurface()) }
}
