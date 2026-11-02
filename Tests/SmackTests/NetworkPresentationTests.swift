import AppKit
import SwiftUI
import Testing
@testable import Smack

@MainActor
@Test func networkCounterKeepsTheSameHeightAcrossUnitChanges() throws {
    let preview = ProcessInfo.processInfo.environment["SMACK_NETWORK_PREVIEW_DIR"]
    for scheme in [ColorScheme.light, .dark] {
        for width in [500.0, 720.0, 960.0, 1300.0] {
            var heights: [CGFloat] = []
            for rate in [0.0, 56_000, 984, 999, 999_000_000, 1_200_000_000] {
                var system = obsSystem(at: 1_000)
                system.interfaces = [InterfaceSample(name: "en0", bytesReceived: 0, bytesSent: 0,
                                                     receiveRate: rate, sendRate: 0, addresses: ["192.168.1.11"])]
                let host = NSHostingView(rootView: NetworkStatsRow(system: system, recent: [])
                    .padding(16).frame(width: width).background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme))
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 240)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                heights.append(host.fittingSize.height)
                #expect(host.fittingSize.width <= width)
                if let preview {
                    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let png = try #require(rep.representation(using: .png, properties: [:]))
                    let directory = URL(fileURLWithPath: preview)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try png.write(to: directory.appendingPathComponent("network-\(scheme)-\(Int(width))-\(Int(rate)).png"))
                }
                window.contentView = nil
            }
            #expect((heights.max()! - heights.min()!) < 1, "Counter changes must not move the chart: \(heights)")
        }
    }
}
