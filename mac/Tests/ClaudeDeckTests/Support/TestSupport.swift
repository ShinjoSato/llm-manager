import AppKit
import XCTest
@testable import MonitorKit

/// 2×2 の PNG。
func testPNGData() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

/// ファイルの末尾に書き足す（無ければ作る）。ログの追記を模す。
func appendToFile(_ data: Data, at url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}

/// 条件が揃うまで待つ。揃わなければ失敗にする。
func waitUntil(timeout: TimeInterval = 5, isolation: isolated (any Actor)? = #isolation,
               _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while await !condition() {
        if Date() > deadline { return XCTFail("時間内に揃いませんでした") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

enum ServerTestError: Error, Equatable {
    case portInUse(Int)
    case failed(String)
}

/// 待ち受けを始め、割り当てられたポートを返す（`port: 0` なら OS が選ぶ）。
func startListening(_ server: HTTPServer, port: Int = 0) async throws -> Int {
    let states = Box<[HTTPServerState]>([])
    server.start(port: port) { state in states.mutate { $0.append(state) } }
    for _ in 0..<300 {
        if let last = states.value.last {
            switch last {
            case .listening(let bound): return bound
            case .portInUse(let p): throw ServerTestError.portInUse(p)
            case .failed(let reason): throw ServerTestError.failed(reason)
            default: break
            }
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ServerTestError.failed("timeout")
}
