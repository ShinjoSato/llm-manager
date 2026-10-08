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
        if let problem = payload.addressProblem { return .failure(.notLocal(problem)) }
        return .success(PairingOffer(payload: payload, source: source))
    }

    /// 送る前に断る理由（LAN の外・版違い・期限切れ）。無ければ nil。
    func problem(now: Date = Date()) -> String? {
        payload.addressProblem ?? payload.problem(now: now.timeIntervalSince1970 * 1000)
    }

    /// カメラで読んだもの以外は出どころを確かめられないので、確認画面で注意を出す。
    var originWarning: String? {
        switch source {
        case .camera: return nil
        case .pasted: return "貼り付けたリンクです。自分の Mac の claude-deck で今出した QR のものか、名前と指紋を確かめてください。"
        case .openedURL: return "他のアプリから開かれたリンクです。自分の Mac の claude-deck で今出した QR のものか、名前と指紋を確かめてください。"
        }
    }

    static func == (lhs: PairingOffer, rhs: PairingOffer) -> Bool { lhs.id == rhs.id }
}

enum PairingLinkError: Error, Equatable {
    case notPairingLink
    case malformed
    /// 接続先が手元の LAN の外を指している（理由つき）。
    case notLocal(String)

    var message: String {
        switch self {
        case .notPairingLink: return "claude-deck のペアリング用の QR ではありません。"
        case .malformed: return "QR の中身が足りないか、形が違います。Mac で新しい QR を出してください。"
        case .notLocal(let reason): return reason
        }
    }
}
