#if !SMACK_APP_STORE
import AppKit
import SwiftUI

struct NativeMenuBarView: View {
    @ObservedObject var menuBarStore: NativeMenuBarStore
    @ObservedObject var settingsStore: SettingsStore

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.showMenuBarItems },
            set: { enabled in
                settingsStore.update { $0.showMenuBarItems = enabled }
                menuBarStore.setFeatureEnabled(enabled)
                if enabled { menuBarStore.requestPermissions() }
            }
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if settingsStore.settings.showMenuBarItems {
                enabledContent
                Toggle("Show menu-bar icons", isOn: isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help("Hide native menu-bar icons")
            } else {
                Toggle("Show menu-bar icons", isOn: isEnabled)
                    .toggleStyle(.switch)
                Text("Uses Screen Recording and Accessibility to show and activate icons.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .onAppear { menuBarStore.setFeatureEnabled(settingsStore.settings.showMenuBarItems) }
        .onChange(of: settingsStore.settings.showMenuBarItems) { _, enabled in
            menuBarStore.setFeatureEnabled(enabled)
        }
    }

    /// Windows without a usable capture (blank or never rendered) are dropped: neither text nor a generic icon
    /// stands in for them, and they otherwise show up as duplicates or raw bundle identifiers.
    private var visibleItems: [NativeMenuBarItem] { menuBarStore.items.filter { $0.image != nil } }

    @ViewBuilder private var enabledContent: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if !menuBarStore.screenCaptureAllowed {
                HStack(spacing: 8) {
                    Text("Screen Recording is required to show native icons. Reopen Smack after granting it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Settings") { menuBarStore.openScreenCaptureSettings() }
                    Button("Reopen") { menuBarStore.relaunch() }
                }
            } else if menuBarStore.accessibilityRequiredForIcons && !menuBarStore.accessibilityAllowed {
                HStack(spacing: 8) {
                    Text("Accessibility is required to show and activate native icons.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Settings") { menuBarStore.openAccessibilitySettings() }
                    Button("Retry") { menuBarStore.refresh() }
                }
            } else if visibleItems.isEmpty {
                if menuBarStore.loadAttempted {
                    Text("No native menu-bar icons found. Move up your mouse to show the menu-bar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                WrappingLayout(horizontalSpacing: 2, verticalSpacing: 2) {
                    ForEach(visibleItems) { item in
                        NativeMenuBarItemButton(
                            item: item,
                            onClick: { menuBarStore.click(item, button: .left) },
                            onRightClick: { menuBarStore.click(item, button: .right) }
                        )
                        .frame(width: max(24, item.pointSize.width + 6), height: 28)
                    }
                }
            }
            if !menuBarStore.accessibilityAllowed && !menuBarStore.accessibilityRequiredForIcons {
                HStack(spacing: 8) {
                    Text("Accessibility is required for native click actions.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Open Settings") { menuBarStore.openAccessibilitySettings() }
                    Button("Retry") { menuBarStore.refresh() }
                }
            }
        }
    }
}

private struct WrappingLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    private struct Row {
        var views: [LayoutSubview] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = makeRows(subviews: Array(subviews), width: proposal.width ?? .infinity)
        let contentWidth = rows.map(\.width).max() ?? 0
        let contentHeight = rows.enumerated().reduce(CGFloat.zero) { result, row in
            result + row.element.height + (row.offset > 0 ? verticalSpacing : 0)
        }
        return CGSize(width: proposal.width ?? contentWidth, height: contentHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = makeRows(subviews: Array(subviews), width: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.maxX - row.width
            for (view, size) in zip(row.views, row.sizes) {
                view.place(
                    at: CGPoint(x: x + size.width / 2, y: y + size.height / 2),
                    anchor: .center,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func makeRows(subviews: [LayoutSubview], width: CGFloat) -> [Row] {
        var rows = [Row()]
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            var row = rows.removeLast()
            let addedWidth = size.width + (row.views.isEmpty ? 0 : horizontalSpacing)
            if !row.views.isEmpty, row.width + addedWidth > width {
                rows.append(row)
                row = Row()
            }
            row.views.append(view)
            row.sizes.append(size)
            row.width += size.width + (row.views.count > 1 ? horizontalSpacing : 0)
            row.height = max(row.height, size.height)
            rows.append(row)
        }
        return rows.filter { !$0.views.isEmpty }
    }
}

private final class NativeStatusItemButton: NSButton {
    var onRightClick: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

private struct NativeMenuBarItemButton: NSViewRepresentable {
    let item: NativeMenuBarItem
    let onClick: () -> Void
    let onRightClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onClick: onClick, onRightClick: onRightClick)
    }

    func makeNSView(context: Context) -> NativeStatusItemButton {
        let button = NativeStatusItemButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.click)
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imageScaling = .scaleProportionallyUpOrDown
        button.onRightClick = { [weak coordinator = context.coordinator] in coordinator?.rightClick() }
        return button
    }

    func updateNSView(_ button: NativeStatusItemButton, context: Context) {
        context.coordinator.onClick = onClick
        context.coordinator.onRightClick = onRightClick
        if let image = item.image {
            button.image = NSImage(cgImage: image, size: item.pointSize)
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            button.image = nil
            button.title = ""
            button.imagePosition = .noImage
        }
        button.toolTip = item.displayName
        button.setAccessibilityLabel(item.displayName)
    }

    final class Coordinator: NSObject {
        var onClick: () -> Void
        var onRightClick: () -> Void

        init(onClick: @escaping () -> Void, onRightClick: @escaping () -> Void) {
            self.onClick = onClick
            self.onRightClick = onRightClick
        }

        @objc func click() { onClick() }
        func rightClick() { onRightClick() }
    }
}
#endif
