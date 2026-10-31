#if !SMACK_APP_STORE
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func AXWindowID(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

/// macOS 27 hosts status items together, rather than giving each item a CG window.
enum HostedMenuBarDiscovery {
    @MainActor static var application: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.executableURL?.lastPathComponent == "MenuBarAgent" }
    }

    static func items(hostPID: pid_t, budget: TimeInterval = 0.75, displayBounds: CGRect, currentPID: pid_t,
                      windowInfo: (CGWindowID) -> NativeMenuBarWindow?) -> [NativeMenuBarItemSource]? {
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            Self.value(element, attribute, deadline: deadline)
        }
        func content(of element: AXUIElement, hostPID: pid_t) -> AXUIElement {
            Self.content(of: element, hostPID: hostPID, deadline: deadline)
        }
        let app = AXUIElementCreateApplication(hostPID)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var elements: [CGWindowID: AXUIElement] = [:]
        for window in windows {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, !Task.isCancelled else { return nil }
            AXUIElementSetMessagingTimeout(window, Float(min(0.1, remaining)))
            var id: CGWindowID = 0
            if AXWindowID(window, &id) == .success { elements[id] = window }
        }
        let extras = value(app, kAXExtrasMenuBarAttribute)
        let activeElements: [AXUIElement]
        if let extras, CFGetTypeID(extras) == AXUIElementGetTypeID() {
            activeElements = (value(extras as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? [])
                .map { content(of: $0, hostPID: hostPID) }
        } else {
            activeElements = []
        }
        let descriptions = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[CFString: Any]] ?? []
        var sources: [CGWindowID: [NativeMenuBarItemSource]] = [:]
        var matches: [CGWindowID: Int] = [:]
        var orderedIDs: [CGWindowID] = []
        for info in descriptions {
            guard ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled else { return nil }
            guard let id = info[kCGWindowNumber] as? CGWindowID, let element = elements[id],
                  let window = windowInfo(id), window.frame.minY == displayBounds.minY,
                  window.frame.minX == displayBounds.minX, window.frame.width == displayBounds.width else { continue }
            let children = value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            var activeMatches = 0
            let candidates = children.compactMap { child -> NativeMenuBarItemSource? in
                guard ProcessInfo.processInfo.systemUptime < deadline, let frame = frame(of: child, deadline: deadline), frame.height > 0 else { return nil }
                AXUIElementSetMessagingTimeout(child, Float(max(0.001, min(0.1, deadline - ProcessInfo.processInfo.systemUptime))))
                var actions: CFArray?
                guard AXUIElementCopyActionNames(child, &actions) == .success,
                      (actions as? [String])?.contains(kAXPressAction) == true else { return nil }
                let content = content(of: child, hostPID: hostPID)
                if activeElements.contains(where: { CFEqual($0, content) }) { activeMatches += 1 }
                var ownerPID = hostPID
                AXUIElementGetPid(content, &ownerPID)
                let identifier = value(content, kAXIdentifierAttribute) as? String
                let title: String?
                if ownerPID == hostPID {
                    title = systemName(identifier) ?? nonempty(value(content, kAXDescriptionAttribute) as? String)
                } else {
                    title = NSRunningApplication(processIdentifier: ownerPID)?.localizedName
                }
                // Pressing a hosting group only focuses it. The embedded control owns activation.
                let activationElement = (value(content, kAXRoleAttribute) as? String) == kAXApplicationRole ? nil : content
                return NativeMenuBarItemSource(window: window, element: child, activationElement: activationElement, frame: frame,
                                              ownerPID: ownerPID, title: title, identifier: identifier)
            }
            if !candidates.isEmpty {
                orderedIDs.append(id)
                matches[id] = activeMatches
                sources[id] = visibleItems(candidates, currentPID: currentPID)
            }
        }
        guard ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled else { return nil }
        guard let selected = preferredWindow(orderedIDs: orderedIDs, matchingExtras: matches) else { return [] }
        return sources[selected] ?? []
    }

    /// Inactive Space copies can precede the active bar in the CG list. The logical menu
    /// extras share AX elements with the active copy, even when all copies are offscreen.
    static func preferredWindow(orderedIDs: [CGWindowID], matchingExtras: [CGWindowID: Int]) -> CGWindowID? {
        var selected: CGWindowID?
        for id in orderedIDs {
            if selected == nil || matchingExtras[id, default: 0] > matchingExtras[selected!, default: 0] {
                selected = id
            }
        }
        return selected
    }

    static func visibleItems(_ candidates: [NativeMenuBarItemSource], currentPID: pid_t) -> [NativeMenuBarItemSource] {
        let overflow = candidates.filter { $0.identifier == "menu-bar-overflow-indicator" }
        var seen = Set<NativeMenuBarItemID>()
        return candidates.filter { item in
            item.ownerPID != currentPID && item.identifier != "com.apple.menuextra.clock" &&
            item.frame.width > 0 && item.frame.height > 0 && item.window.frame.contains(item.frame) &&
            (item.identifier == "menu-bar-overflow-indicator" || !overflow.contains { $0.frame.intersects(item.frame) }) &&
            seen.insert(item.id).inserted
        }.sorted { $0.frame.minX < $1.frame.minX }
    }

    static func frame(of element: AXUIElement, deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 0.2) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute, deadline: deadline), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, kAXSizeAttribute, deadline: deadline), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func value(_ element: AXUIElement, _ attribute: String, deadline: TimeInterval) -> CFTypeRef? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0, !Task.isCancelled else { return nil }
        AXUIElementSetMessagingTimeout(element, Float(min(0.1, remaining)))
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private static func content(of element: AXUIElement, hostPID: pid_t, deadline: TimeInterval, depth: Int = 0) -> AXUIElement {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid == hostPID, depth < 3,
              let children = value(element, kAXChildrenAttribute, deadline: deadline) as? [AXUIElement], let first = children.first else { return element }
        return content(of: first, hostPID: hostPID, deadline: deadline, depth: depth + 1)
    }

    private static func nonempty(_ string: String?) -> String? {
        string.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func systemName(_ identifier: String?) -> String? {
        switch identifier {
        case "com.apple.menuextra.controlcenter": "Control Center"
        case "com.apple.menuextra.battery": "Battery"
        case "com.apple.menuextra.wifi": "Wi-Fi"
        case "com.apple.menuextra.user": "Fast User Switching"
        case "menu-bar-overflow-indicator": "Show Hidden Menu Bar Items"
        default: nil
        }
    }
}
#endif
