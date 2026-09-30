import Foundation

/// `/events` から届くイベントをデコードしたもの。
public enum MonitorEvent: Sendable, Equatable {
    case sessions([SessionSnapshot])
    case feed(FeedItem)
    case feedBatch([FeedItem])
    /// statusLine 未設定なら nil（monitor が `null` を送る）。
    case usage(UsageSnapshot?)
    /// ループバック接続にだけ届く。
    case permissions([PendingPermission])
    case transcript(TranscriptEvent)
    /// 知らないイベント名。monitor が先に増えてもアプリは落とさない。
    case unknown(name: String)

    /// SSE の 1 イベントを型に落とす。未知のイベント名は `.unknown`、形が合わなければ throw。
    public static func decode(_ sse: SSEEvent, decoder: JSONDecoder = JSONDecoder()) throws -> MonitorEvent {
        let data = Data(sse.data.utf8)
        switch sse.event {
        case "sessions": return .sessions(try decoder.decode([SessionSnapshot].self, from: data))
        case "feed": return .feed(try decoder.decode(FeedItem.self, from: data))
        case "feed-batch": return .feedBatch(try decoder.decode([FeedItem].self, from: data))
        case "usage": return .usage(try decoder.decode(UsageSnapshot?.self, from: data))
        case "permissions": return .permissions(try decoder.decode([PendingPermission].self, from: data))
        case "transcript": return .transcript(try decoder.decode(TranscriptEvent.self, from: data))
        default: return .unknown(name: sse.event)
        }
    }
}
