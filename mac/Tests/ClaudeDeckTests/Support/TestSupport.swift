import AppKit
import XCTest
@testable import MonitorKit

/// 2×2 の PNG。
func testPNGData() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

/// 試験用の画像（ImageIO で書く本物の PNG / JPEG）。
enum TestImages {
    /// `noise` は圧縮の効かない中身（大きなファイルを作るため）。
    static func png(width: Int = 4, height: Int = 3, noise: Bool = false) -> Data {
        encode(width: width, height: height, type: "public.png", noise: noise)
    }
    static func jpeg(width: Int = 4, height: Int = 3) -> Data { encode(width: width, height: height, type: "public.jpeg", noise: false) }

    private static func encode(width: Int, height: Int, type: String, noise: Bool) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        if noise, let buffer = context.data {
            let count = context.bytesPerRow * height
            let bytes = buffer.bindMemory(to: UInt8.self, capacity: count)
            var seed: UInt64 = 7
            for i in 0..<count {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                bytes[i] = UInt8(truncatingIfNeeded: seed >> 33)
            }
        } else {
            context.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }
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
