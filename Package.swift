// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "DevMop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SweepCore", targets: ["SweepCore"]),
        .executable(name: "mop", targets: ["mop"]),
        .executable(name: "DevMop", targets: ["DevMop"]),
    ],
    targets: [
        .target(name: "SweepCore", swiftSettings: settings),
        .executableTarget(name: "mop", dependencies: ["SweepCore"], swiftSettings: settings),
        .executableTarget(name: "DevMop", dependencies: ["SweepCore"], swiftSettings: settings),
        .testTarget(name: "SweepCoreTests", dependencies: ["SweepCore"], swiftSettings: settings),
    ]
)
