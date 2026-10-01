import AppKit
import Observation
import SwiftTerm
import MonitorKit

/// アプリが PTY でホストしている claude 1 つ（= 1 ルーム）。端末ビューは画面に載せず、PTY の受信と画面読み取りだけに使う。
@MainActor
@Observable
final class HostedSession: Identifiable {
    enum End: Equatable {
        case exited(Int32?)
        case limitReached
        /// claude を起動できなかった（PTY の子プロセスが取れない）。
        case launchFailed
    }

    let id = UUID()
    let project: ManagedProject
    let startedAt = Date()
    @ObservationIgnored let terminal: ClaudeTerminalView
    @ObservationIgnored private let observer = TerminalProcessObserver()

    private(set) var pid: Int32?
    private(set) var localStatus: ClaudeStatus = .idle
    private(set) var permissionPrompt: PermissionPrompt?
    /// 入力欄への送信を止める状態（権限プロンプト・選択メニュー）。
    private(set) var inputBlock: InputBlock?
    private(set) var end: End?
    /// 最後に解決できた sessionId。終了して monitor の対応表から消えた後も会話を出すために持ち続ける。
    @ObservationIgnored var lastSessionId: String?
    /// 最後にローカル判定が変わった時刻（monitor 未接続時の並び順に使う）。
    private(set) var lastChangeAt = Date()

    @ObservationIgnored var onLimitReached: ((HostedSession) -> Void)?
    /// 外部から引き継いだ時の再開対象。
    let resumeSessionId: String?

    init(project: ManagedProject, resumeSessionId: String? = nil) {
        self.project = project
        self.resumeSessionId = resumeSessionId
        // pid と対応付くまでの間も同じ会話を出し、外部ルームとして二重に並ばないようにする。
        self.lastSessionId = resumeSessionId
        // 起動時点の桁数で TUI が組まれるので、0 幅ではなく現実的な大きさで作る。
        self.terminal = ClaudeTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        terminal.processDelegate = observer
        terminal.onStatusChanged = { [weak self] status in
            self?.localStatus = status
            self?.lastChangeAt = Date()
        }
        terminal.onPermissionPromptChanged = { [weak self] in self?.permissionPrompt = $0 }
        terminal.onInputBlockChanged = { [weak self] in self?.inputBlock = $0 }
        terminal.onLimitReached = { [weak self] in self?.handleLimitReached() }
        observer.onTerminated = { [weak self] code in self?.handleExit(code) }
    }

    var isRunning: Bool { end == nil && pid != nil }

    func start() {
        guard pid == nil, end == nil else { return }
        guard terminal.launchClaude(in: project.path, resumeSessionId: resumeSessionId), let pid = terminal.claudePid else {
            terminal.stopStatusMonitoring()
            end = .launchFailed
            return
        }
        self.pid = pid
        MonitorBridge.store.registerHostedProcess(pid: pid)
    }

    /// 今の sessionId（monitor の対応表から引けなければ最後に解決できたもの）。
    func resolveSessionId(_ store: MonitorStore) -> String? {
        if let pid, let id = store.sessionId(forHostedPid: pid) {
            lastSessionId = id
            return id
        }
        return lastSessionId
    }

    /// claude を終わらせる（ルームを閉じる時）。
    func terminate() {
        terminal.stopStatusMonitoring()
        if end == nil { terminal.terminate() }
        release()
    }

    func send(_ text: String, onAborted: ((InputBlock) -> Void)? = nil) -> ClaudeTerminalView.SendResult? {
        guard isRunning else { return nil }
        return terminal.sendMessage(text, onAborted: onAborted)
    }

    func answerPermission(_ expected: PermissionPrompt, allow: Bool) -> ClaudeTerminalView.AnswerResult {
        guard isRunning else { return .noPrompt }
        return terminal.answerPermission(expected, allow: allow)
    }

    private func handleLimitReached() {
        guard end == nil else { return }
        end = .limitReached
        permissionPrompt = nil
        inputBlock = nil
        terminal.stopStatusMonitoring()
        terminal.terminate()
        release()
        onLimitReached?(self)
    }

    private func handleExit(_ code: Int32?) {
        terminal.stopStatusMonitoring()
        if end == nil { end = .exited(code) }
        permissionPrompt = nil
        inputBlock = nil
        release()
    }

    private func release() {
        guard let pid else { return }
        _ = resolveSessionId(MonitorBridge.store)
        MonitorBridge.store.unregisterHostedProcess(pid: pid)
    }
}

/// SwiftTerm のプロセス通知を受ける。デリゲートは AnyObject なので小さな受け口を挟む。
final class TerminalProcessObserver: LocalProcessTerminalViewDelegate {
    var onTerminated: ((Int32?) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in self?.onTerminated?(exitCode) }
    }
}
