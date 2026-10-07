// swift-tools-version: 5.9
import PackageDescription

// mac と iPhone で共有する、Foundation / Security / CryptoKit だけに依存する部分（UI は持たない）。
let package = Package(
    name: "DeckCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "DeckCore", targets: ["DeckCore"])
    ],
    targets: [
        .target(
            name: "DeckCore",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "DeckCoreTests",
            dependencies: ["DeckCore"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        )
    ]
)
