// swift-tools-version: 6.0
import PackageDescription
import Foundation

let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Library/Developer/CommandLineTools"
let testingPlugin = "\(developerDirectory)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
let testSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: testingPlugin)
    ? [.unsafeFlags(["-Xfrontend", "-load-plugin-library", "-Xfrontend", testingPlugin])]
    : []

let package = Package(
    name: "Smack",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Smack",
            exclude: ["Resources"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(name: "SmackTests", dependencies: ["Smack"], swiftSettings: testSettings)
    ]
)
