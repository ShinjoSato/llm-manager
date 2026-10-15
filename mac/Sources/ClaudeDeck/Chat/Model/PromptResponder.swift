import Foundation
import Observation
import MonitorKit

/// 権限確認（Channels・端末のプロンプト）と選択肢メニューへの回答。画面のカードと iPhone からの操作が同じ経路（照合・二度押し防止）を通る。
@MainActor
@Observable
final class PromptResponder {
    private let store: MonitorStore
    private let alerts: ChatAlerts

    /// 送信中の印と、カードに数秒だけ出す一言。印は押したカードにだけ付き、カードは自分の body でここを読む。
    let board = PromptCardBoard(log: { event, fields in MenuOpsLog.shared.record(event, fields) })

    /// 何かの操作を送っている鍵（Channels の key か "pty:<ルーム>" / "menu:<ルーム>"）。iPhone の一覧の「送信中」に使う。
    var busyKeys: Set<String> { board.activeKeys }

    init(store: MonitorStore, alerts: ChatAlerts) {
        self.store = store
        self.alerts = alerts
    }

    // MARK: - 権限確認

    func monitorPermissions(for room: Room) -> [PendingPermission] {
        guard let sessionId = room.sessionId else { return [] }
        return store.permissions(forSessionId: sessionId)
    }

    func decide(_ permission: PendingPermission, _ decision: PermissionDecision) {
        board.log("press", [("key", permission.key), ("decision", decision == .allow ? "allow" : "deny")])
        guard case .success(let token) = board.begin(key: permission.key, identity: permission.key) else { return }
        Task {
            defer { board.release(key: permission.key, token: token, reason: "decided") }
            do {
                try await store.decide(permission, decision)
            } catch {
                alerts.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Channels の確認に答えて結果を返す（iPhone から。mac に警告は出さない）。
    func decide(key: String, _ decision: PermissionDecision) async -> RemoteActionResult {
        guard case .success(let token) = board.begin(key: key, identity: key) else { return Self.busyResult }
        defer { board.release(key: key, token: token, reason: "decided") }
        return await store.remoteDecide(key: key, decision: decision)
    }

    static func ptyPermissionKey(_ session: HostedSession) -> String { "pty:\(session.id.uuidString)" }

    /// 端末の権限プロンプトのカードの印（同じ文面が続けて出ても別のカードにする）。
    static func permissionCard(_ session: HostedSession, _ prompt: PermissionPrompt) -> String {
        PromptCardIdentity.permission(prompt, generation: session.promptTracker.generation)
    }

    /// `prompt`（カードに出していたもの）が今のプロンプトと違えば送らない（別の確認を承認しない）。`report` が false なら警告を出さない。
    @discardableResult
    func answerOnTerminal(_ session: HostedSession, prompt: PermissionPrompt, allow: Bool, report: Bool = true) -> RemoteActionResult {
        let key = Self.ptyPermissionKey(session)
        let card = Self.permissionCard(session, prompt)
        board.log("press", [("key", key), ("card", card), ("decision", allow ? "allow" : "deny")])
        guard board.admit(key: key, identity: card) else { return Self.busyResult }
        let answeredId = RemoteTerminalPermission.promptId(prompt, generation: session.promptTracker.generation)
        switch session.answerPermission(prompt, allow: allow) {
        case .sent:
            // 同じ表示への押し直し（mac・iPhone どちらからでも）を送らないため。
            session.markAnswered(answeredId)
            board.log("key", [("key", key), ("card", card), ("send", allow ? "1" : "esc")])
        case .noPrompt:
            return failed("gone", "端末に権限確認が見当たりません。既に答え終わっている可能性があります。", key: key, report: report)
        case .changed:
            return failed("changed", "権限の確認の内容が替わったため送りませんでした。カードの内容を確かめてから答えてください。", key: key, report: report)
        }
        holdBusy(key, identity: card)
        return .success(allow ? "allowed" : "denied")
    }

    /// キーを送ってから画面が替わるまで少し掛かるので、その間は押したカードを押せないままにする。`identity` が nil なら、どのカードも送信中には見せずに重ねての操作だけを断る。
    private func holdBusy(_ key: String, identity: String? = nil) {
        board.hold(key: key, identity: identity)
    }

    static let busyResult = RemoteActionResult.failure("busy", "前の操作を送っているところです。少し待ってからもう一度押してください。")

    /// 失敗を返す。カードに一言を出し、`report` なら mac にも警告を出す。
    private func failed(_ code: String, _ message: String, key: String, report: Bool) -> RemoteActionResult {
        board.log("result", [("key", key), ("code", code)])
        board.showNotice(message, key: key)
        if report { alerts.message = message }
        return .failure(code, message)
    }

    // MARK: - 選択肢

    static func ptyMenuKey(_ session: HostedSession) -> String { "menu:\(session.id.uuidString)" }

    /// `menu`（カードに出していたもの）の `choice` 番目を選ぶ（nil は Esc）。今のメニューと違えば送らず、結果は `completion` に 1 回返す。
    func answerMenu(_ session: HostedSession, menu: MenuPrompt, choice: Int?, report: Bool = true,
                    completion: ((RemoteActionResult) -> Void)? = nil) {
        let key = Self.ptyMenuKey(session)
        let card = PromptCardIdentity.menu(menu)
        board.log("press", [("key", key), ("card", card), ("choice", choice.map(String.init) ?? "esc")])
        guard let operation = beginMenuOperation(key: key, card: card, report: report, completion: completion) else { return }
        let answeredId = RemoteMenu.menuId(menu, generation: session.promptTracker.generation)
        session.answerMenu(menu, choice: choice) { [weak self, weak session] outcome in
            guard let self else { operation.deliver(Self.appClosed); return }
            if Self.result(of: outcome).ok { session?.markAnswered(answeredId) }
            if outcome == .confirmed, let choice, menu.options[choice].checked != nil {
                // 複数選択では Enter はチェックの切り替えで、メニューは閉じない。
                let text = "「\(menu.options[choice].label)」のチェックを切り替えました。"
                self.complete(operation, key: key, outcome: outcome, result: .success("toggled", text), notice: text, report: report)
                return
            }
            self.complete(operation, key: key, outcome: outcome, result: Self.result(of: outcome), notice: nil, report: report)
        }
    }

    /// AskUserQuestion の問いのタブを 1 つ移る（→ / ←）。`menu` はカードに出していたもの。
    func moveMenuTab(_ session: HostedSession, menu: MenuPrompt, direction: MenuTabMover.Direction, report: Bool = true,
                     completion: ((RemoteActionResult) -> Void)? = nil) {
        let key = Self.ptyMenuKey(session)
        let card = PromptCardIdentity.menu(menu)
        board.log("press", [("key", key), ("card", card), ("tab", direction == .next ? "next" : "previous")])
        guard let operation = beginMenuOperation(key: key, card: card, report: report, completion: completion) else { return }
        let answeredId = RemoteMenu.menuId(menu, generation: session.promptTracker.generation)
        session.moveMenuTab(menu, direction: direction) { [weak self, weak session] outcome in
            guard let self else { operation.deliver(Self.appClosed); return }
            if Self.result(of: outcome).ok { session?.markAnswered(answeredId) }
            self.complete(operation, key: key, outcome: outcome, result: Self.result(of: outcome), notice: nil, report: report)
        }
    }

    private static let appClosed = RemoteActionResult.failure("ended", "アプリが閉じられました。")

    /// 時間内に端末から結果が返らなかった時（送信中を外し、カードに案内を出す）。
    static let timedOut = RemoteActionResult.failure("unconfirmed", PromptCardBoard.timeoutNotice)

    /// 選択肢の操作 1 回分。結果は完了と時間切れのどちらか先の 1 回だけ受け手に渡す。
    @MainActor
    private struct MenuOperation {
        let token: UUID
        let delivery: OnceDelivery<RemoteActionResult>

        func deliver(_ result: RemoteActionResult) { delivery.deliver(result) }
    }

    /// 選択肢の操作を始める（重なる操作なら一言を出して始めない）。送信中の印を押したカードに付け、上限の時間切れを仕掛ける。
    private func beginMenuOperation(key: String, card: String, report: Bool,
                                    completion: ((RemoteActionResult) -> Void)?) -> MenuOperation? {
        let token: UUID
        switch board.begin(key: key, identity: card) {
        case .success(let begun):
            token = begun
        case .failure(let refusal):
            completion?(.failure("busy", PromptCardBoard.message(refusal)))
            return nil
        }
        let delivery = OnceDelivery<RemoteActionResult> { [weak self] result in
            if result.code == Self.timedOut.code {
                self?.board.release(key: key, token: token, reason: "timeout")
                self?.board.showNotice(PromptCardBoard.timeoutNotice, key: key, duration: PromptCardBoard.timeoutNoticeDuration)
            } else {
                // やめた移動の矢印も遅れて反映されうるので、押したカードはすぐには押せるようにしない。
                self?.board.finish(key: key, token: token)
            }
            self?.board.log("result", [("key", key), ("card", card), ("token", String(token.uuidString.prefix(8))),
                                       ("code", result.code)])
            completion?(result)
        }
        delivery.deliver(after: PromptOperationBook.limit) { Self.timedOut }
        return MenuOperation(token: token, delivery: delivery)
    }

    /// 端末から結果が返った。時間切れの後に返った結果は受け手に渡さず、記録と失敗の一言だけ残す。
    private func complete(_ operation: MenuOperation, key: String, outcome: ClaudeTerminalView.MenuAnswerOutcome,
                          result: RemoteActionResult, notice: String?, report: Bool) {
        board.log("outcome", [("key", key), ("outcome", Self.outcomeName(outcome)), ("late", operation.delivery.isDelivered ? "yes" : "no")])
        guard !operation.delivery.isDelivered else {
            if !result.ok, let message = result.message { board.showNotice(message, key: key) }
            return
        }
        if let notice {
            board.showNotice(notice, key: key, duration: 3)
        } else if !result.ok, let message = result.message {
            board.showNotice(message, key: key)
            if report, !Self.quietFailures.contains(where: { $0 == outcome }) { alerts.message = message }
        }
        operation.deliver(result)
    }

    /// カードの一言だけで足りる失敗（押し直せば済む）。
    private static let quietFailures: [ClaudeTerminalView.MenuAnswerOutcome] = [.navigating, .settling]

    static func outcomeName(_ outcome: ClaudeTerminalView.MenuAnswerOutcome) -> String {
        switch outcome {
        case .confirmed: return "confirmed"
        case .cancelled: return "cancelled"
        case .moved: return "moved"
        case .failed(let failure): return "failed(\(failure))"
        case .ended: return "ended"
        case .unavailable: return "unavailable"
        case .navigating: return "navigating"
        case .settling: return "settling"
        }
    }

    static func result(of outcome: ClaudeTerminalView.MenuAnswerOutcome) -> RemoteActionResult {
        switch outcome {
        case .confirmed: return .success("confirmed")
        case .cancelled: return .success("cancelled")
        case .moved: return .success("moved")
        case .failed(.gone):
            return .failure("gone", "端末に選択肢が見当たりません。既に答え終わっている可能性があります。")
        case .failed(.vanished):
            return .failure("vanished", "キーを送った後に端末の選択肢が読み取れなくなったため、Enter を押さずにやめました。端末の表示を確かめてから答えてください。")
        case .failed(.changed):
            return .failure("changed", "選択肢の内容が替わったため送りませんでした（矢印で ❯ を動かしていた場合は Enter を押していません）。カードの内容を確かめてから答えてください。")
        case .failed(.stuck):
            return .failure("stuck", "選択肢の位置を合わせられなかった（またはタブが移らなかった）ため、Enter を押さずにやめました。カードの内容を確かめてからもう一度答えてください。")
        case .ended:
            return .failure("ended", "claude が終了した（終了・上限到達など）ため、選択肢を確定できませんでした。Enter は押していません。")
        case .unavailable:
            return .failure("unavailable", "この操作はここからはできません（文字入力の行に ❯ がある時はタブを移れません）。")
        case .navigating:
            return .failure("navigating", "前の操作で選択肢を動かしているところです。終わってからもう一度押してください。")
        case .settling:
            return .failure("settling", "直前に送った矢印キーが端末に反映されるのを待っています。少し待ってからもう一度押してください。")
        }
    }

    /// 中身を読み取れない選択メニューを閉じる。`menu` はカードに出していた写し。
    @discardableResult
    func cancelUnreadableMenu(_ session: HostedSession, menu: UnreadableMenu, report: Bool = true) -> RemoteActionResult {
        let key = Self.ptyMenuKey(session)
        let card = PromptCardIdentity.unreadable(menu)
        board.log("press", [("key", key), ("card", card), ("choice", "esc")])
        guard board.admit(key: key, identity: card) else { return Self.busyResult }
        let answeredId = RemoteUnreadableMenu.menuId(menu, generation: session.promptTracker.generation)
        switch session.cancelUnreadableMenu(menu) {
        case .sent: session.markAnswered(answeredId)
        case .gone:
            return failed("gone", "端末に読み取れない選択肢が見当たりません。既に答え終わったか、カードで答えられる形になった可能性があります。", key: key, report: report)
        case .changed:
            return failed("changed", "端末の選択肢が替わったため送りませんでした。カードの内容を確かめてから操作してください。", key: key, report: report)
        }
        holdBusy(key, identity: card)
        return .success("cancelled")
    }
}
