// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "PlatformStatus",
    platforms: [.macOS(.v26)],
    products: [.library(name: "PlatformStatus", targets: ["PlatformStatus"])],
    dependencies: [.package(path: "../Indicators")],
    targets: [
        .target(
            name: "PlatformStatus",
            dependencies: [.product(name: "Indicators", package: "Indicators")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PlatformStatusTests",
            dependencies: ["PlatformStatus"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
