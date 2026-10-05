import Foundation

/// 通知を開いた時に、どのルームへ行くか。
public struct AttentionNoticeRoute: Sendable, Equatable {
    public var roomId: String
    public var sessionId: String?
    public var macName: String?

    public init(roomId: String, sessionId: String?, macName: String?) {
        self.roomId = roomId
        self.sessionId = sessionId
        self.macName = macName
    }

    /// 通知に載ったフィールド（`AttentionNoticeSchema.desiredKeys`）から作る。ルームが無ければ nil。
    public init?(fields: [String: Any]) {
        guard let roomId = fields[AttentionNoticeSchema.Field.roomId] as? String, !roomId.isEmpty else { return nil }
        self.roomId = roomId
        sessionId = (fields[AttentionNoticeSchema.Field.sessionId] as? String).flatMap { $0.isEmpty ? nil : $0 }
        macName = fields[AttentionNoticeSchema.Field.macName] as? String
    }

    /// 生の通知（`userInfo`）から作る。CloudKit は `ck.qry.af` に `desiredKeys` の値を入れて届ける。
    public init?(userInfo: [AnyHashable: Any]) {
        guard let ck = userInfo["ck"] as? [String: Any], let query = ck["qry"] as? [String: Any],
              let fields = query["af"] as? [String: Any] else { return nil }
        self.init(fields: fields)
    }

    /// 開くルーム。mac を起動し直すとホスト中のルームの id が替わるので、見つからなければセッションで探す。
    public func resolve(in rooms: [RemoteRoom]) -> RemoteRoom? {
        if let room = rooms.first(where: { $0.id == roomId }) { return room }
        guard let sessionId else { return nil }
        return rooms.first { $0.sessionId == sessionId }
    }
}

/// アプリを開いている時に届いた知らせを出すか。
public enum AttentionNoticePresentation {
    public static func shouldPresent(enabled: Bool, route: AttentionNoticeRoute?, openRoomId: String?) -> Bool {
        guard enabled else { return false }
        // その会話を見ている最中なら、画面のカードで分かる。
        if let route, let openRoomId, route.roomId == openRoomId { return false }
        return true
    }
}
