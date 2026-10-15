// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "DevSweep",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SweepCore", targets: ["SweepCore"]),
        .executable(name: "sweep", targets: ["sweep"]),
        .executable(name: "DevSweep", targets: ["DevSweep"]),
    ],
    targets: [
        .target(name: "SweepCore", swiftSettings: settings),
        .executableTarget(name: "sweep", dependencies: ["SweepCore"], swiftSettings: settings),
        .executableTarget(name: "DevSweep", dependencies: ["SweepCore"], swiftSettings: settings),
        .testTarget(name: "SweepCoreTests", dependencies: ["SweepCore"], swiftSettings: settings),
    ]
)
