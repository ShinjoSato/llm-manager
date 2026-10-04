import DeckCore
import Foundation

/// 会話の末尾に出す要対応のカード（mac の会話末尾と同じ優先順）。
enum RoomCard: Equatable {
    /// Channels の権限確認（最優先。外部セッションはこれだけ答えられる）。
    case channels([PendingPermission])
    case terminalPermission(RemoteTerminalPermission)
    case menu(RemoteMenu)
    case unreadableMenu(RemoteUnreadableMenu)
    /// 外部セッションが権限待ちなのに確認が届いていない（Channels を載せていない）。
    case channelsMissing(toolName: String?)

    static func cards(for room: RemoteRoom) -> [RoomCard] {
        if !room.permissions.isEmpty { return [.channels(room.permissions)] }
        if let prompt = room.terminalPermission { return [.terminalPermission(prompt)] }
        if let menu = room.menu { return [.menu(menu)] }
        if let menu = room.unreadableMenu { return [.unreadableMenu(menu)] }
        if room.kind == .external, room.status == .permission { return [.channelsMissing(toolName: room.session?.currentTool)] }
        return []
    }
}

/// 外部から開かれた・貼り付けた・読み取ったペアリングのリンク。必ず確認してから使う。
struct PairingOffer: Identifiable, Equatable {
    enum Source: Equatable {
        case camera
        case pasted
        /// 他のアプリ・ブラウザから `claude-deck://pair` で開かれた。
        case openedURL
    }

    let id = UUID()
    let payload: RemotePairingPayload
    let source: Source

    /// 読めないリンクは理由を返す。
    static func parse(_ text: String, source: Source) -> Result<PairingOffer, PairingLinkError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == RemotePairingPayload.scheme else { return .failure(.notPairingLink) }
        guard let payload = RemotePairingPayload(url: url) else { return .failure(.malformed) }
        return .success(PairingOffer(payload: payload, source: source))
    }

    static func == (lhs: PairingOffer, rhs: PairingOffer) -> Bool { lhs.id == rhs.id }
}

enum PairingLinkError: Error, Equatable {
    case notPairingLink
    case malformed

    var message: String {
        switch self {
        case .notPairingLink: return "claude-deck のペアリング用の QR ではありません。"
        case .malformed: return "QR の中身が足りないか、形が違います。Mac で新しい QR を出してください。"
        }
    }
}
