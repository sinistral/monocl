// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Indicators",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Indicators", targets: ["Indicators"])],
    targets: [
        .target(name: "Indicators", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "IndicatorsTests",
            dependencies: ["Indicators"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
