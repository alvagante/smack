import AppKit
import SwiftUI
import Testing
@testable import Smack

@MainActor
struct AgentHeaderTests {
    /// The title, the figures and the mode picker share one row from 1100 pt of page width; below that the figures
    /// move under the title by design. A wrapped header is about twice as tall as a single row.
    @Test(arguments: AgentPageMode.allCases)
    func headerStaysOnOneRow(mode: AgentPageMode) {
        let monitor = AgentMonitor()
        for width in [1100.0, 1400.0] {
            var current = mode
            let host = NSHostingView(rootView: AgentPageHeader(model: monitor, mode: Binding(get: { current }, set: { current = $0 }))
                .frame(width: width))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height < 90, "\(mode.rawValue) header wrapped at \(Int(width)) pt")
            if ProcessInfo.processInfo.environment["SMACK_UI_PREVIEWS"] != nil,
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("smack-agent-header-\(mode)-\(Int(width)).png"))
            }
        }
    }
}
