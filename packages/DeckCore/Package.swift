// swift-tools-version: 5.9
import PackageDescription

// mac アプリ（claude-deck）と iPhone アプリで共有する、プラットフォームに依存しない部分。
// Foundation / Security / CryptoKit だけに依存させ、UI は持たない。
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
