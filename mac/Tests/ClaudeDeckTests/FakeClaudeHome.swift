import Foundation
@testable import MonitorKit

/// 試験用の偽の `~/.claude`（一時ディレクトリ）。本物の `~/.claude` には触らない。
struct FakeClaudeHome {
    let root: URL
    var home: ClaudeHome { ClaudeHome(root: root) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"), withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeSession(pid: Int32, sessionId: String, cwd: String, extra: [String: Any] = [:]) throws {
        var o: [String: Any] = ["pid": Int(pid), "sessionId": sessionId, "cwd": cwd, "startedAt": 1_000]
        o.merge(extra) { _, new in new }
        try JSONSerialization.data(withJSONObject: o).write(to: root.appendingPathComponent("sessions/\(pid).json"))
    }

    func removeSession(pid: Int32) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("sessions/\(pid).json"))
    }

    func transcriptURL(sessionId: String, cwd: String) -> URL {
        root.appendingPathComponent("projects/\(ClaudeHome.slug(forCwd: cwd))/\(sessionId).jsonl")
    }

    func appendTranscript(sessionId: String, cwd: String, lines: [String]) throws {
        try appendRaw(Data(lines.map { $0 + "\n" }.joined().utf8), to: transcriptURL(sessionId: sessionId, cwd: cwd))
    }

    func appendRaw(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    static let timestamp = "2026-09-30T13:12:32.000Z"

    static func json(_ o: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]), as: UTF8.self)
    }

    static func user(_ uuid: String, _ content: Any, timestamp: String = timestamp, extra: [String: Any] = [:]) -> String {
        var o: [String: Any] = ["type": "user", "uuid": uuid, "timestamp": timestamp, "message": ["role": "user", "content": content]]
        o.merge(extra) { _, new in new }
        return json(o)
    }

    static func assistant(_ uuid: String, _ content: [Any], timestamp: String = timestamp, extra: [String: Any] = [:]) -> String {
        var o: [String: Any] = ["type": "assistant", "uuid": uuid, "timestamp": timestamp,
                                "message": ["role": "assistant", "content": content]]
        o.merge(extra) { _, new in new }
        return json(o)
    }

    /// 1x1 の PNG（実データの形を保つため本物のヘッダーを使う）。
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
    static let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46])

    static func image(_ mediaType: String, _ data: Data) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()]]
    }

    static var pngBlock: [String: Any] { image("image/png", png) }
}

/// ISO8601 の文字列を epoch ミリ秒に。
func millis(_ iso: String) -> Double {
    let date = try! Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso)
    return (date.timeIntervalSince1970 * 1000).rounded()
}

/// epoch ミリ秒を ISO8601 の文字列に。
func iso(_ ms: Double) -> String {
    Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date(timeIntervalSince1970: ms / 1000))
}

/// 時計を進められる試験用の今。
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double

    init(_ value: Double) {
        self.value = value
    }

    var now: Double { lock.withLock { value } }

    func advance(_ ms: Double) { lock.withLock { value += ms } }
    func set(_ ms: Double) { lock.withLock { value = ms } }
}
