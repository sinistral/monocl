// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v26)],
    products: [.library(name: "ClaudeUsage", targets: ["ClaudeUsage"])],
    targets: [
        .target(
            name: "ClaudeUsage",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ClaudeUsageTests",
            dependencies: ["ClaudeUsage"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
