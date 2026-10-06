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
    public init(_ prompt: PermissionPrompt, generation: Int) {
        self.init(promptId: Self.promptId(prompt, generation: generation), title: prompt.title, lines: prompt.lines)
    }

    /// 同じ文面でも出し直されたものは別の確認なので、表示の世代を混ぜる。
    public static func promptId(_ prompt: PermissionPrompt, generation: Int) -> String {
        RemoteDigest.of(["\u{4}\(generation)"] + contentParts(prompt))
    }

    static func contentParts(_ prompt: PermissionPrompt) -> [String] { [prompt.title] + prompt.lines }
}

extension RemoteMenu {
    public init(_ menu: MenuPrompt, generation: Int) {
        let options = menu.options.enumerated().map { index, option in
            RemoteMenuOption(index: index, number: option.number, label: option.label, detail: option.detail,
                             checked: option.checked, isSubmit: option.isSubmit, selectable: !option.isFreeText)
        }
        let tabs = menu.tabs.map { t in
            RemoteMenuTabs(tabs: t.tabs.map { RemoteMenuTab(title: $0.title, answered: $0.answered) }, hasSubmit: t.hasSubmit,
                           current: t.current, canMoveNext: t.canMoveNext, canMovePrevious: t.canMovePrevious)
        }
        self.init(menuId: Self.menuId(menu, generation: generation), context: menu.context, question: menu.question, options: options,
                  cursor: menu.cursor, footer: menu.footer, tabs: tabs, isMultiSelect: menu.isMultiSelect,
                  isReview: menu.isReview, cancelExits: menu.cancelExits)
    }

    /// ❯ の位置を除いた中身と表示の世代から作る（❯ が動いただけでは変わらない）。
    public static func menuId(_ menu: MenuPrompt, generation: Int) -> String {
        RemoteDigest.of(["\u{4}\(generation)"] + contentParts(menu))
    }

    static func contentParts(_ menu: MenuPrompt) -> [String] {
        var parts = menu.context + ["\u{1}" + menu.question, "\u{1}" + menu.footer]
        for option in menu.options {
            parts.append("\u{2}\(option.number.map(String.init) ?? "-")|\(option.label)|\(option.checked.map { $0 ? "1" : "0" } ?? "-")|\(option.isSubmit)")
            parts.append(contentsOf: option.detail)
        }
        if let tabs = menu.tabs {
            parts.append("\u{3}\(tabs.hasSubmit)|\(tabs.hasArrows)|\(tabs.current.map(String.init) ?? "-")")
            parts.append(contentsOf: tabs.tabs.map { "\($0.title)|\($0.answered)" })
        }
        return parts
    }
}

extension RemoteUnreadableMenu {
    public init(_ menu: UnreadableMenu, generation: Int) {
        self.init(menuId: Self.menuId(menu, generation: generation), lines: menu.lines, cancelExits: menu.cancelExits)
    }

    public static func menuId(_ menu: UnreadableMenu, generation: Int) -> String {
        RemoteDigest.of(["\u{4}\(generation)"] + contentParts(menu))
    }

    static func contentParts(_ menu: UnreadableMenu) -> [String] { menu.lines + ["\u{1}\(menu.cancelExits)"] }
}

/// ホスト中のセッションの端末に出ている、答えられる表示（会話末尾のカードと同じ優先順: 権限プロンプト → 選択肢）。
public enum RemoteTerminalCard: Sendable, Equatable {
    case permission(PermissionPrompt)
    case menu(MenuPrompt)
    case unreadable(UnreadableMenu)
    /// 選択待ちだが中身も写しも取れていない（読み取りの途中）。
    case pendingMenu

    public static func current(permissionPrompt: PermissionPrompt?, inputBlock: InputBlock?, menuPrompt: MenuPrompt?,
                               unreadableMenu: UnreadableMenu?) -> RemoteTerminalCard? {
        if let permissionPrompt { return .permission(permissionPrompt) }
        guard inputBlock == .menu else { return nil }
        if let menuPrompt { return .menu(menuPrompt) }
        if let unreadableMenu { return .unreadable(unreadableMenu) }
        return .pendingMenu
    }

    /// 世代を進めるかの比較に使う中身（❯ の位置は含めない）。
    var contentKey: String {
        switch self {
        case .permission(let p): return "p" + RemoteDigest.of(RemoteTerminalPermission.contentParts(p))
        case .menu(let m): return "m" + RemoteDigest.of(RemoteMenu.contentParts(m))
        case .unreadable(let u): return "u" + RemoteDigest.of(RemoteUnreadableMenu.contentParts(u))
        case .pendingMenu: return "?"
        }
    }
}

/// 端末の表示の世代と、答えた ID。表示が消えるか替わるたびに世代を進め、同じ文面で出し直された確認を別の ID にする。
public struct RemotePromptTracker: Sendable, Equatable {
    public private(set) var generation = 0
    private var shownKey: String?
    /// 答えた ID（世代入りなので後の確認とは重ならない。押し直しに `answered` を返すため、消えた後もしばらく覚える）。
    private var answered: [String] = []
    static let rememberedAnswers = 64

    public init() {}

    public mutating func observe(_ card: RemoteTerminalCard?) {
        let key = card?.contentKey
        guard key != shownKey else { return }
        if shownKey != nil { generation &+= 1 }
        shownKey = key
    }

    public mutating func markAnswered(_ id: String) {
        guard !answered.contains(id) else { return }
        answered.append(id)
        if answered.count > Self.rememberedAnswers { answered.removeFirst(answered.count - Self.rememberedAnswers) }
    }

    public func isAnswered(_ id: String) -> Bool { answered.contains(id) }
}

/// ルームのカード（API の型）。Channels の確認があれば端末のカードは出さない（mac の会話末尾と同じ）。
public struct RemoteRoomCards: Sendable, Equatable {
    public var terminalPermission: RemoteTerminalPermission?
    public var menu: RemoteMenu?
    public var unreadableMenu: RemoteUnreadableMenu?

    public init(channelsPending: Bool, card: RemoteTerminalCard?, generation: Int) {
        guard !channelsPending, let card else { return }
        switch card {
        case .permission(let p): terminalPermission = RemoteTerminalPermission(p, generation: generation)
        case .menu(let m): menu = RemoteMenu(m, generation: generation)
        case .unreadable(let u): unreadableMenu = RemoteUnreadableMenu(u, generation: generation)
        case .pendingMenu: break
        }
    }
}

/// 照合の失敗を `Result` で返すため（DeckCore 側は API の型に留め、Error にはしない）。
extension RemoteActionResult: @retroactive Error {}

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

/// 照合に使う今の端末の様子。
public struct RemoteTerminalContext: Sendable {
    public var card: RemoteTerminalCard?
    public var tracker: RemotePromptTracker
    /// Channels の確認が出ている（その間は端末のカードを出さず、端末からも答えない）。
    public var channelsPending: Bool

    public init(card: RemoteTerminalCard?, tracker: RemotePromptTracker, channelsPending: Bool) {
        self.card = card
        self.tracker = tracker
        self.channelsPending = channelsPending
    }
}

public enum RemoteChecks {
    /// 送れる本文の上限（UTF-8）。
    public static let maxMessageBytes = 32 * 1024

    static let answered = RemoteActionResult.success("answered", "この確認には既に答えています（送り直していません）。")
    static let channels = RemoteActionResult.failure("changed", "この確認は Channels で答えます。一覧を取り直してください。")
    static let menuGone = RemoteActionResult.failure("gone", "端末に選択肢が見当たりません。既に答え終わっている可能性があります。")

    /// 今の端末のプロンプトが iPhone の見ていたもの（同じ世代）か。同じならそれを照合の基準にして返す。
    public static func terminalPermission(promptId: String, in context: RemoteTerminalContext) -> Result<PermissionPrompt, RemoteActionResult> {
        if context.tracker.isAnswered(promptId) { return .failure(answered) }
        if context.channelsPending { return .failure(channels) }
        guard case .permission(let current) = context.card else {
            return .failure(.failure("gone", "端末に権限確認が見当たりません。既に答え終わっている可能性があります。"))
        }
        guard RemoteTerminalPermission.promptId(current, generation: context.tracker.generation) == promptId else {
            return .failure(.failure("changed", "権限の確認の内容が替わったため送りませんでした。内容を確かめてから答えてください。"))
        }
        return .success(current)
    }

    public enum MenuAction: Equatable {
        case choose(Int)
        case cancel
    }

    /// 今のメニューが iPhone の見ていたもの（同じ世代）で、押せる選択肢か。
    public static func menuAnswer(_ request: RemoteMenuAnswerRequest, in context: RemoteTerminalContext) -> Result<(MenuPrompt, MenuAction), RemoteActionResult> {
        let action: MenuAction
        switch (request.choice, request.cancel ?? false) {
        case (let choice?, false): action = .choose(choice)
        case (nil, true): action = .cancel
        default: return .failure(.failure("invalid", "choice か cancel のどちらか一方を指定してください。"))
        }
        if context.tracker.isAnswered(request.menuId) { return .failure(answered) }
        if context.channelsPending { return .failure(channels) }
        guard case .menu(let current) = context.card else { return .failure(menuGone) }
        guard RemoteMenu.menuId(current, generation: context.tracker.generation) == request.menuId else {
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

    public static func menuTab(_ request: RemoteMenuTabRequest, in context: RemoteTerminalContext) -> Result<MenuPrompt, RemoteActionResult> {
        if context.tracker.isAnswered(request.menuId) { return .failure(answered) }
        if context.channelsPending { return .failure(channels) }
        guard case .menu(let current) = context.card else { return .failure(menuGone) }
        guard RemoteMenu.menuId(current, generation: context.tracker.generation) == request.menuId else {
            return .failure(.failure("changed", "選択肢の内容が替わったため送りませんでした。内容を確かめてから操作してください。"))
        }
        return .success(current)
    }

    public static func menuDismiss(_ request: RemoteMenuDismissRequest, in context: RemoteTerminalContext) -> Result<UnreadableMenu, RemoteActionResult> {
        if context.tracker.isAnswered(request.menuId) { return .failure(answered) }
        if context.channelsPending { return .failure(channels) }
        guard case .unreadable(let current) = context.card else {
            return .failure(.failure("gone", "端末に読み取れない選択肢が見当たりません。既に答え終わったか、カードで答えられる形になった可能性があります。"))
        }
        guard RemoteUnreadableMenu.menuId(current, generation: context.tracker.generation) == request.menuId else {
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

    /// ホスト中のセッションへ送れない時の結果コード（終了・選択待ち）。
    public static func sendBlockedCode(ended: Bool, inputBlock: InputBlock?) -> String {
        if ended { return "ended" }
        switch inputBlock {
        case .permission: return "blocked_permission"
        case .menu: return "blocked_menu"
        case nil: return "unavailable"
        }
    }
}

/// iPhone からの操作の待ち。戻らない操作で接続を握り続けないよう上限を設ける（操作自体はその後も続きうる）。
@MainActor
public enum RemoteOperationWait {
    public static let timeout: Duration = .seconds(30)
    public static let timedOut = RemoteActionResult.failure("timeout", "mac での操作が時間内に終わりませんでした。"
        + "操作は続いている可能性があるため、一覧を取り直して端末の様子を確かめてください。")

    /// `start` に渡す完了の受け口は最初の 1 回だけ通す（上限を過ぎた後の完了は捨てる）。
    public static func wait(timeout: Duration = RemoteOperationWait.timeout,
                            _ start: (@escaping @MainActor (RemoteActionResult) -> Void) -> Void) async -> RemoteActionResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<RemoteActionResult, Never>) in
            let gate = ResumeGate()
            let timer = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, gate.claim() else { return }
                continuation.resume(returning: timedOut)
            }
            start { result in
                timer.cancel()
                guard gate.claim() else { return }
                continuation.resume(returning: result)
            }
        }
    }
}

@MainActor
private final class ResumeGate {
    private var used = false

    func claim() -> Bool {
        defer { used = true }
        return !used
    }
}
