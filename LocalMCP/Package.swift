// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacBridgeLocal",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "macbridge-mcp", targets: ["MacBridgeLocalMCP"]),
        .executable(name: "macbridge-observer", targets: ["MacBridgeObserver"]),
    ],
    targets: [
        .target(name: "MacBridgeLocalCore"),
        .executableTarget(name: "MacBridgeObserver", dependencies: ["MacBridgeLocalCore"]),
        .executableTarget(
            name: "MacBridgeLocalMCP",
            dependencies: ["MacBridgeLocalCore"]
        ),
        .testTarget(
            name: "MacBridgeLocalCoreTests",
            dependencies: ["MacBridgeLocalCore"]
        ),
        .testTarget(
            name: "MacBridgeObserverTests",
            dependencies: ["MacBridgeObserver"]
        ),
    ]
)
