import Foundation

/// SSE の 1 イベント（`event:` / `data:` / `id:` をまとめたもの）。
public struct SSEEvent: Sendable, Hashable {
    public var event: String
    public var data: String
    public var id: String?

    public init(event: String = "message", data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// text/event-stream の逐次パーサ（WHATWG の仕様どおり）。
/// 受信チャンクの境界は行やマルチバイト文字の途中に来うるので、バイト列のまま行を組み立てる。
public struct SSEParser: Sendable {
    private var lineBuffer: [UInt8] = []
    private var lastWasCR = false
    private var sawFirstLine = false
    private var eventType = ""
    private var dataLines: [String] = []
    private var hasData = false
    private var eventId: String?

    /// 直近の `retry:`（ミリ秒）。再接続の待ち時間の下限に使える。
    public private(set) var retryMillis: Int?

    public init() {}

    /// 受信したバイト列を流し込み、完成したイベントを返す。
    public mutating func feed<S: Sequence>(_ bytes: S) -> [SSEEvent] where S.Element == UInt8 {
        var events: [SSEEvent] = []
        for byte in bytes {
            if byte == 0x0A, lastWasCR {
                // CRLF の LF 側。CR の時点で行は確定済み。
                lastWasCR = false
                continue
            }
            lastWasCR = false
            if byte == 0x0A || byte == 0x0D {
                lastWasCR = byte == 0x0D
                if let ev = processLine() { events.append(ev) }
                lineBuffer.removeAll(keepingCapacity: true)
            } else {
                lineBuffer.append(byte)
            }
        }
        return events
    }

    /// 接続が切れた時に、途中まで組み立てた分を捨てる（仕様上、未完のイベントは配らない）。
    public mutating func reset() {
        self = SSEParser()
    }

    private mutating func processLine() -> SSEEvent? {
        var line = String(decoding: lineBuffer, as: UTF8.self)
        if !sawFirstLine {
            sawFirstLine = true
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
        }
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "event":
            eventType = String(value)
        case "data":
            dataLines.append(String(value))
            hasData = true
        case "id":
            if !value.contains("\0") { eventId = String(value) }
        case "retry":
            if !value.isEmpty, value.allSatisfy(\.isASCIIDigit), let ms = Int(value) { retryMillis = ms }
        default:
            break
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventType = ""
            dataLines.removeAll()
            hasData = false
        }
        guard hasData else { return nil }
        return SSEEvent(event: eventType.isEmpty ? "message" : eventType,
                        data: dataLines.joined(separator: "\n"),
                        id: eventId)
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
