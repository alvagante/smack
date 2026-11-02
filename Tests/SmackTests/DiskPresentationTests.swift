import AppKit
import SwiftUI
import Testing
@testable import Smack

@MainActor
@Test func diskCounterKeepsTheSameHeightAcrossUnitChanges() {
    for scheme in [ColorScheme.light, .dark] {
        for width in [500.0, 720.0, 960.0, 1300.0] {
            var heights: [CGFloat] = []
            for rate in [0.0, 56_000, 984, 999, 999_000_000, 1_200_000_000] {
                var system = obsSystem(at: 1_000)
                system.disks = [DiskSample(name: "disk0", bytesRead: 1, bytesWritten: 1,
                                          readRate: rate, writeRate: 0)]
                let host = NSHostingView(rootView: DiskStatsRow(system: system, recent: [])
                    .padding(16).frame(width: width).environment(\.colorScheme, scheme))
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 240)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                heights.append(host.fittingSize.height)
                #expect(host.fittingSize.width <= width)
                window.contentView = nil
            }
            #expect((heights.max()! - heights.min()!) < 1, "Counter changes must not move the chart: \(heights)")
        }
    }
}
