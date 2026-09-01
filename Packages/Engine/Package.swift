// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Engine",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Engine", targets: ["Engine"])],
    dependencies: [
        .package(path: "../Indicators"),
        .package(path: "../ClaudeUsage"),
        .package(path: "../PlatformStatus"),
    ],
    targets: [
        .target(
            name: "Engine",
            dependencies: [
                .product(name: "Indicators", package: "Indicators"),
                .product(name: "ClaudeUsage", package: "ClaudeUsage"),
                .product(name: "PlatformStatus", package: "PlatformStatus"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EngineTests",
            dependencies: ["Engine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
