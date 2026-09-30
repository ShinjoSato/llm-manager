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
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        )
    ]
)
