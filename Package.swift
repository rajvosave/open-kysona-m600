// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenMouse",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OpenMouseKit", targets: ["OpenMouseKit"]),
        .executable(name: "OpenMouse", targets: ["OpenMouseApp"]),
    ],
    targets: [
        // Protocol, parsers and IOKit HID transport. No UI.
        .target(name: "OpenMouseKit"),
        // SwiftUI shell for exploring the device and, later, configuring it.
        .executableTarget(name: "OpenMouseApp", dependencies: ["OpenMouseKit"]),
        .testTarget(name: "OpenMouseKitTests", dependencies: ["OpenMouseKit"]),
    ]
)
