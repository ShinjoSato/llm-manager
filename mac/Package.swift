// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "claude-deck",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "claude-deck", targets: ["ClaudeDeck"]),
        .executable(name: "claude-deck-channel", targets: ["claude-deck-channel"])
    ],
    dependencies: [
        // VT100/Xterm 端末エミュレータ。PTY ホスト（LocalProcessTerminalView）を提供。上流の変更で挙動が変わらないようリビジョンで固定する。
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", revision: "a3b8c9b680cb38d87d2a067b8ecd6427910538a6")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeDeck",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "MonitorKit"
            ]
        ),
        // セッション監視・会話・フックの受け口（アプリ内）。UI を持たないのでテストできるよう library に切り出す。
        .target(
            name: "MonitorKit",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        // アプリ内の監視を GUI 無しで確かめるデバッグ用エントリ（`swift run monitor-probe`）。
        .executableTarget(
            name: "monitor-probe",
            dependencies: ["MonitorKit"],
            path: "Sources/MonitorProbe",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        // Claude Code が子プロセスで起動するチャネル（stdio の MCP サーバー）。権限確認をアプリの受け口へ中継する。
        .executableTarget(
            name: "claude-deck-channel",
            dependencies: ["MonitorKit"],
            path: "Sources/ClaudeDeckChannel",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ClaudeDeckTests",
            // SwiftTerm は端末ペインと同じ起動経路（forkpty）でシグナル設定の漏れを確かめるため。
            // チャネルは実行ファイルを stdin/stdout で繋いで確かめるので、先にビルドさせる。
            dependencies: ["MonitorKit", "claude-deck-channel", .product(name: "SwiftTerm", package: "SwiftTerm")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        )
    ]
)
