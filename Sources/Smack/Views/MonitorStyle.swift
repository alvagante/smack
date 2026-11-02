import SwiftUI

/// Semantic macOS colors follow system appearance, contrast and the user's accent color.
enum MonitorStyle {
    static let page = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let inset: CGFloat = 24
    static let spacing: CGFloat = 16
    static let radius: CGFloat = 10
    static let title = Font.system(size: 20, weight: .semibold)
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
