// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v26)],
    products: [.library(name: "ClaudeUsage", targets: ["ClaudeUsage"])],
    dependencies: [.package(path: "../Indicators")],
    targets: [
        .target(
            name: "ClaudeUsage",
            dependencies: [.product(name: "Indicators", package: "Indicators")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ClaudeUsageTests",
            dependencies: ["ClaudeUsage"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
