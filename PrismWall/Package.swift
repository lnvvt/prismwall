// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrismWall",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PrismWallCore",
            path: "Sources/PrismWallCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "PrismWall",
            dependencies: ["PrismWallCore"],
            path: "Sources/PrismWallApp",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PrismWallCoreTests",
            dependencies: ["PrismWallCore"],
            path: "Tests/PrismWallCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
