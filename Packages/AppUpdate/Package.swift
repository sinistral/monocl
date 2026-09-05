// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "AppUpdate",
    platforms: [.macOS(.v26)],
    products: [.library(name: "AppUpdate", targets: ["AppUpdate"])],
    targets: [
        .target(
            name: "AppUpdate",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AppUpdateTests",
            dependencies: ["AppUpdate"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
