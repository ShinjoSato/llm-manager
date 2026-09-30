// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "claude-deck",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "claude-deck", targets: ["ClaudeDeck"])
    ],
    dependencies: [
        // VT100/Xterm 端末エミュレータ。PTY ホスト（LocalProcessTerminalView）を提供。
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeDeck",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "MonitorKit"
            ]
        ),
        // monitor（:8766）のクライアント。UI を持たないのでテストできるよう library に切り出す。
        .target(
            name: "MonitorKit",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        // monitor への接続を GUI 無しで確かめるデバッグ用エントリ（`swift run monitor-probe`）。
        .executableTarget(
            name: "monitor-probe",
            dependencies: ["MonitorKit"],
            path: "Sources/MonitorProbe",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ClaudeDeckTests",
            dependencies: ["MonitorKit"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        )
    ]
)
