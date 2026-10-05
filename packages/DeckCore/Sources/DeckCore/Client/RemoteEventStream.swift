import Foundation

/// `/v1/events` から届く 1 件。
public enum RemoteStreamEvent: Sendable, Equatable {
    case state(RemoteState)
    case transcript(TranscriptEvent)
    /// `: ping` などのコメント（生きている印）。
    case ping
}

/// Server-Sent Events の行を 1 件ずつのイベントにまとめる。空行で区切り、複数の `data:` は改行でつなぐ。
public struct SSEParser: Sendable {
    public struct Message: Sendable, Equatable {
        public var event: String
        public var data: String
    }

    public enum Output: Sendable, Equatable {
        case message(Message)
        case comment
    }

    private var event = ""
    private var data: [String] = []
    private var dataBytes = 0
    /// 1 件分の `data:` の合計の上限。区切りの空行を送らない相手に際限なく溜めさせない。
    public var maxEventBytes = 16 << 20

    public init() {}

    public struct Overflow: Error {}

    /// 1 行（改行を除く）を食べる。区切りまで来たら出す。
    public mutating func feed(_ rawLine: String) throws -> Output? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            defer { event = ""; data = []; dataBytes = 0 }
            guard !data.isEmpty else { return nil }
            return .message(Message(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n")))
        }
        if line.hasPrefix(":") { return .comment }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data":
            dataBytes += value.utf8.count + 1
            if dataBytes > maxEventBytes {
                event = ""; data = []; dataBytes = 0
                throw Overflow()
            }
            data.append(String(value))
        default: break
        }
        return nil
    }

    /// 1 件を API の型に起こす。知らないイベントは捨てる。
    public static func decode(_ message: Message) throws -> RemoteStreamEvent? {
        let decoder = JSONDecoder()
        switch message.event {
        case RemoteEventName.state.rawValue:
            return .state(try decoder.decode(RemoteState.self, from: Data(message.data.utf8)))
        case RemoteEventName.transcript.rawValue:
            return .transcript(try decoder.decode(TranscriptEvent.self, from: Data(message.data.utf8)))
        default:
            return nil
        }
    }
}

/// バイト列を行に割る（空行を落とさない。SSE は空行が区切りなので `AsyncLineSequence` は使えない）。
public struct LineSplitter: Sendable {
    private var buffer: [UInt8] = []
    /// 1 行の上限。超えたら壊れた相手とみなす。
    public var maxLineBytes = 8 << 20

    public init() {}

    public struct Overflow: Error {}

    public mutating func feed(_ byte: UInt8) throws -> String? {
        if byte == 0x0a {
            defer { buffer.removeAll(keepingCapacity: true) }
            return String(decoding: buffer, as: UTF8.self)
        }
        buffer.append(byte)
        if buffer.count > maxLineBytes { throw Overflow() }
        return nil
    }
}
