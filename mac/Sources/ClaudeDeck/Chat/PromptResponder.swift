import Foundation
import Observation
import MonitorKit

/// 権限確認（Channels・端末のプロンプト）と選択肢メニューへの回答。画面のカードと iPhone からの操作が同じ経路（照合・二度押し防止）を通る。
@MainActor
@Observable
final class PromptResponder {
    private let store: MonitorStore
    private let alerts: ChatAlerts

    /// 送信中の権限確認（Channels の key か "pty:<ルーム>" / "menu:<ルーム>"）。二度押しさせない。
    private(set) var busyKeys: Set<String> = []
    /// 選択肢カードに数秒だけ出す結果（"menu:<ルーム>" → 文言）。複数選択でチェックを切り替えた時など。
    private(set) var menuNotices: [String: String] = [:]

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
        guard !busyKeys.contains(permission.key) else { return }
        busyKeys.insert(permission.key)
        Task {
            defer { busyKeys.remove(permission.key) }
            do {
                try await store.decide(permission, decision)
            } catch {
                alerts.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Channels の確認に答えて結果を返す（iPhone から。mac に警告は出さない）。
    func decide(key: String, _ decision: PermissionDecision) async -> RemoteActionResult {
        guard !busyKeys.contains(key) else { return Self.busyResult }
        busyKeys.insert(key)
        defer { busyKeys.remove(key) }
        return await store.remoteDecide(key: key, decision: decision)
    }

    static func ptyPermissionKey(_ session: HostedSession) -> String { "pty:\(session.id.uuidString)" }

    /// `prompt` はカードに出していたもの。端末の今のプロンプトと違えば何も送らない（別の確認を承認しないため）。
    /// `report` が false なら mac に警告を出さず、結果だけを返す（iPhone からの操作）。
    @discardableResult
    func answerOnTerminal(_ session: HostedSession, prompt: PermissionPrompt, allow: Bool, report: Bool = true) -> RemoteActionResult {
        let key = Self.ptyPermissionKey(session)
        guard !busyKeys.contains(key) else { return Self.busyResult }
        let answeredId = RemoteTerminalPermission.promptId(prompt, generation: session.promptTracker.generation)
        switch session.answerPermission(prompt, allow: allow) {
        case .sent:
            // 同じ表示への押し直し（mac・iPhone どちらからでも）を送らないため。
            session.markAnswered(answeredId)
        case .noPrompt:
            return failed("gone", "端末に権限確認が見当たりません。既に答え終わっている可能性があります。", report: report)
        case .changed:
            return failed("changed", "権限の確認の内容が替わったため送りませんでした。カードの内容を確かめてから答えてください。", report: report)
        }
        holdBusy(key)
        return .success(allow ? "allowed" : "denied")
    }

    /// キーを送ってから画面が替わるまで少し掛かるので、その間は押せないままにする。
    private func holdBusy(_ key: String) {
        busyKeys.insert(key)
        releaseBusyLater(key)
    }

    private func releaseBusyLater(_ key: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.busyKeys.remove(key) }
    }

    static let busyResult = RemoteActionResult.failure("busy", "前の操作を送っているところです。少し待ってからもう一度押してください。")

    /// 失敗を返す。`report` なら mac にも警告を出す。
    private func failed(_ code: String, _ message: String, report: Bool) -> RemoteActionResult {
        if report { alerts.message = message }
        return .failure(code, message)
    }

    // MARK: - 選択肢

    static func ptyMenuKey(_ session: HostedSession) -> String { "menu:\(session.id.uuidString)" }

    /// `menu` はカードに出していたもの。`choice` はその選択肢の位置、nil なら取り消し（Esc）。
    /// 端末の今のメニューと違えば何も送らない（別の問いに答えないため）。結果は `completion` に 1 回返す。
    func answerMenu(_ session: HostedSession, menu: MenuPrompt, choice: Int?, report: Bool = true,
                    completion: ((RemoteActionResult) -> Void)? = nil) {
        let key = Self.ptyMenuKey(session)
        guard !busyKeys.contains(key) else { completion?(Self.busyResult); return }
        busyKeys.insert(key)
        let answeredId = RemoteMenu.menuId(menu, generation: session.promptTracker.generation)
        session.answerMenu(menu, choice: choice) { [weak self, weak session] outcome in
            guard let self else { completion?(.failure("ended", "アプリが閉じられました。")); return }
            if Self.result(of: outcome).ok { session?.markAnswered(answeredId) }
            if outcome == .confirmed, let choice, menu.options[choice].checked != nil {
                // 複数選択では Enter はチェックの切り替えで、メニューは閉じない。
                let text = "「\(menu.options[choice].label)」のチェックを切り替えました。"
                self.showMenuNotice(key, text)
                self.finishMenuOperation(key, outcome: outcome, report: report)
                completion?(.success("toggled", text))
                return
            }
            completion?(self.finishMenuOperation(key, outcome: outcome, report: report))
        }
    }

    /// AskUserQuestion の問いのタブを 1 つ移る（→ / ←）。`menu` はカードに出していたもの。
    func moveMenuTab(_ session: HostedSession, menu: MenuPrompt, direction: MenuTabMover.Direction, report: Bool = true,
                     completion: ((RemoteActionResult) -> Void)? = nil) {
        let key = Self.ptyMenuKey(session)
        guard !busyKeys.contains(key) else { completion?(Self.busyResult); return }
        busyKeys.insert(key)
        let answeredId = RemoteMenu.menuId(menu, generation: session.promptTracker.generation)
        session.moveMenuTab(menu, direction: direction) { [weak self, weak session] outcome in
            guard let self else { completion?(.failure("ended", "アプリが閉じられました。")); return }
            if Self.result(of: outcome).ok { session?.markAnswered(answeredId) }
            completion?(self.finishMenuOperation(key, outcome: outcome, report: report))
        }
    }

    private func showMenuNotice(_ key: String, _ text: String) {
        menuNotices[key] = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.menuNotices[key] == text { self?.menuNotices[key] = nil }
        }
    }

    @discardableResult
    private func finishMenuOperation(_ key: String, outcome: ClaudeTerminalView.MenuAnswerOutcome, report: Bool) -> RemoteActionResult {
        let result = Self.result(of: outcome)
        if report, !result.ok, let message = result.message { alerts.message = message }
        // やめた移動の矢印も遅れて反映されうるので、失敗でもすぐには押せるようにしない。
        releaseBusyLater(key)
        return result
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
        case .settling:
            return .failure("settling", "直前に送った矢印キーが端末に反映されるのを待っています。少し待ってからもう一度押してください。")
        }
    }

    /// 中身を読み取れない選択メニューを閉じる。`menu` はカードに出していた写し。
    @discardableResult
    func cancelUnreadableMenu(_ session: HostedSession, menu: UnreadableMenu, report: Bool = true) -> RemoteActionResult {
        let key = Self.ptyMenuKey(session)
        guard !busyKeys.contains(key) else { return Self.busyResult }
        let answeredId = RemoteUnreadableMenu.menuId(menu, generation: session.promptTracker.generation)
        switch session.cancelUnreadableMenu(menu) {
        case .sent: session.markAnswered(answeredId)
        case .gone:
            return failed("gone", "端末に読み取れない選択肢が見当たりません。既に答え終わったか、カードで答えられる形になった可能性があります。", report: report)
        case .changed:
            return failed("changed", "端末の選択肢が替わったため送りませんでした。カードの内容を確かめてから操作してください。", report: report)
        }
        holdBusy(key)
        return .success("cancelled")
    }
}
