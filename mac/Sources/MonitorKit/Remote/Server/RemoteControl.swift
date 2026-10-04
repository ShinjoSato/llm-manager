import CryptoKit
import Foundation

/// iPhone の口が mac アプリへ頼む操作。実装はアプリ（ChatModel）で、画面のボタンと同じ経路（照合・二度押し防止・選択待ちでの停止）を通す。
@MainActor
public protocol RemoteControl: AnyObject {
    /// ルーム一覧と各ルームのカード。
    func remoteState() -> RemoteState
    /// Channels の権限確認に答える（画面の権限カードと同じ `MonitorStore.decide`）。
    func remoteDecide(key: String, decision: PermissionDecision) async -> RemoteActionResult
    /// 端末画面の権限プロンプトに答える（`promptId` が今のプロンプトと一致する時だけ）。
    func remoteAnswerTerminalPermission(roomId: String, promptId: String, decision: PermissionDecision) async -> RemoteActionResult
    /// 選択肢カードに答える（`MenuNavigator` で 1 行ずつ動かして確かめてから Enter）。
    func remoteAnswerMenu(roomId: String, request: RemoteMenuAnswerRequest) async -> RemoteActionResult
    func remoteMoveMenuTab(roomId: String, request: RemoteMenuTabRequest) async -> RemoteActionResult
    func remoteDismissMenu(roomId: String, request: RemoteMenuDismissRequest) async -> RemoteActionResult
    /// ホスト中のセッションなら入力欄へ（選択待ちなら送らない）、外部セッションなら伝言。
    func remoteSendMessage(roomId: String, text: String) async -> RemoteActionResult
}

/// ルームの識別子（`h:<UUID>` / `e:<sessionId>`）。
public enum RemoteRoomID: Hashable, Sendable {
    case hosted(UUID)
    case external(String)

    public var string: String {
        switch self {
        case .hosted(let id): return "h:\(id.uuidString)"
        case .external(let sessionId): return "e:\(sessionId)"
        }
    }

    public init?(_ raw: String) {
        if raw.hasPrefix("h:"), let id = UUID(uuidString: String(raw.dropFirst(2))) {
            self = .hosted(id)
        } else if raw.hasPrefix("e:"), TranscriptFormat.isValidSessionId(String(raw.dropFirst(2))) {
            self = .external(String(raw.dropFirst(2)))
        } else {
            return nil
        }
    }
}

extension RemoteRoomPhase {
    public init(_ phase: RoomPhase) {
        switch phase {
        case .attention: self = .attention
        case .active: self = .active
        case .idle: self = .idle
        }
    }
}

// MARK: - 端末画面のカード → API の型

extension RemoteTerminalPermission {
    public init(_ prompt: PermissionPrompt) {
        self.init(promptId: Self.promptId(prompt), title: prompt.title, lines: prompt.lines)
    }

    public static func promptId(_ prompt: PermissionPrompt) -> String {
        RemoteDigest.of([prompt.title] + prompt.lines)
    }
}

extension RemoteMenu {
    public init(_ menu: MenuPrompt) {
        let options = menu.options.enumerated().map { index, option in
            RemoteMenuOption(index: index, number: option.number, label: option.label, detail: option.detail,
                             checked: option.checked, isSubmit: option.isSubmit, selectable: !option.isFreeText)
        }
        let tabs = menu.tabs.map { t in
            RemoteMenuTabs(tabs: t.tabs.map { RemoteMenuTab(title: $0.title, answered: $0.answered) }, hasSubmit: t.hasSubmit,
                           current: t.current, canMoveNext: t.canMoveNext, canMovePrevious: t.canMovePrevious)
        }
        self.init(menuId: Self.menuId(menu), context: menu.context, question: menu.question, options: options,
                  cursor: menu.cursor, footer: menu.footer, tabs: tabs, isMultiSelect: menu.isMultiSelect,
                  isReview: menu.isReview, cancelExits: menu.cancelExits)
    }

    /// ❯ の位置を除いた中身から作る（❯ が動いただけでは変わらない）。
    public static func menuId(_ menu: MenuPrompt) -> String {
        var parts = menu.context + ["\u{1}" + menu.question, "\u{1}" + menu.footer]
        for option in menu.options {
            parts.append("\u{2}\(option.number.map(String.init) ?? "-")|\(option.label)|\(option.checked.map { $0 ? "1" : "0" } ?? "-")|\(option.isSubmit)")
            parts.append(contentsOf: option.detail)
        }
        if let tabs = menu.tabs {
            parts.append("\u{3}\(tabs.hasSubmit)|\(tabs.hasArrows)|\(tabs.current.map(String.init) ?? "-")")
            parts.append(contentsOf: tabs.tabs.map { "\($0.title)|\($0.answered)" })
        }
        return RemoteDigest.of(parts)
    }
}

extension RemoteUnreadableMenu {
    public init(_ menu: UnreadableMenu) {
        self.init(menuId: RemoteDigest.of(menu.lines + ["\u{1}\(menu.cancelExits)"]), lines: menu.lines, cancelExits: menu.cancelExits)
    }
}

/// 照合の失敗を `Result` で返すため。
extension RemoteActionResult: Error {}

enum RemoteDigest {
    /// 区切りを挟んだ SHA-256 の先頭 16 バイト（識別にだけ使う）。
    static func of(_ parts: [String]) -> String {
        var hasher = SHA256()
        for part in parts {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        return Data(hasher.finalize().prefix(16)).hexString
    }
}

// MARK: - 操作の前の照合（画面のカードを押した時と同じ条件にそろえる）

public enum RemoteChecks {
    /// 送れる本文の上限（UTF-8）。
    public static let maxMessageBytes = 32 * 1024

    /// 今の端末のプロンプトが iPhone の見ていたものと同じか。同じならそれを照合の基準にして返す。
    public static func terminalPermission(promptId: String, current: PermissionPrompt?) -> Result<PermissionPrompt, RemoteActionResult> {
        guard let current else { return .failure(.failure("gone", "端末に権限確認が見当たりません。既に答え終わっている可能性があります。")) }
        guard RemoteTerminalPermission.promptId(current) == promptId else {
            return .failure(.failure("changed", "権限の確認の内容が替わったため送りませんでした。内容を確かめてから答えてください。"))
        }
        return .success(current)
    }

    public enum MenuAction: Equatable {
        case choose(Int)
        case cancel
    }

    /// 今のメニューが iPhone の見ていたものと同じで、押せる選択肢か。
    public static func menuAnswer(_ request: RemoteMenuAnswerRequest, current: MenuPrompt?) -> Result<(MenuPrompt, MenuAction), RemoteActionResult> {
        let action: MenuAction
        switch (request.choice, request.cancel ?? false) {
        case (let choice?, false): action = .choose(choice)
        case (nil, true): action = .cancel
        default: return .failure(.failure("invalid", "choice か cancel のどちらか一方を指定してください。"))
        }
        guard let current else { return .failure(.failure("gone", "端末に選択肢が見当たりません。既に答え終わっている可能性があります。")) }
        guard RemoteMenu.menuId(current) == request.menuId else {
            return .failure(.failure("changed", "選択肢の内容が替わったため送りませんでした。内容を確かめてから答えてください。"))
        }
        switch action {
        case .choose(let index):
            guard current.options.indices.contains(index) else { return .failure(.failure("invalid", "選択肢の位置が範囲外です。")) }
            guard !current.options[index].isFreeText else {
                return .failure(.failure("unavailable", "文字を入力する選択肢はここからは選べません。取り消してからメッセージで伝えてください。"))
            }
        case .cancel:
            guard !current.cancelExits || request.confirmExit == true else {
                return .failure(.failure("confirm_required", "取り消すと claude が終了します。終了してよければ confirmExit を付けてください。"))
            }
        }
        return .success((current, action))
    }

    public static func menuTab(_ request: RemoteMenuTabRequest, current: MenuPrompt?) -> Result<MenuPrompt, RemoteActionResult> {
        guard let current else { return .failure(.failure("gone", "端末に選択肢が見当たりません。既に答え終わっている可能性があります。")) }
        guard RemoteMenu.menuId(current) == request.menuId else {
            return .failure(.failure("changed", "選択肢の内容が替わったため送りませんでした。内容を確かめてから操作してください。"))
        }
        return .success(current)
    }

    public static func menuDismiss(_ request: RemoteMenuDismissRequest, current: UnreadableMenu?) -> Result<UnreadableMenu, RemoteActionResult> {
        guard let current else {
            return .failure(.failure("gone", "端末に読み取れない選択肢が見当たりません。既に答え終わったか、カードで答えられる形になった可能性があります。"))
        }
        guard RemoteUnreadableMenu(current).menuId == request.menuId else {
            return .failure(.failure("changed", "端末の選択肢が替わったため送りませんでした。内容を確かめてから操作してください。"))
        }
        guard !current.cancelExits || request.confirmExit == true else {
            return .failure(.failure("confirm_required", "閉じると claude が終了します。終了してよければ confirmExit を付けてください。"))
        }
        return .success(current)
    }

    /// 送る本文。空・長すぎれば失敗。
    public static func message(_ text: String) -> Result<String, RemoteActionResult> {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.failure("invalid", "本文が空です。")) }
        guard text.utf8.count <= maxMessageBytes else { return .failure(.failure("invalid", "本文が長すぎます（\(maxMessageBytes / 1024)KB まで）。")) }
        return .success(text)
    }
}
