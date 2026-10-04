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
    /// 端末に出ている選択メニューの中身（読み取れなければ nil。inputBlock が .menu でも nil はありうる）。
    private(set) var menuPrompt: MenuPrompt?
    /// 選択メニューは出ているが中身を読めない時の写し。
    private(set) var unreadableMenu: UnreadableMenu?
    /// チャット欄からの送信の途中（画像の取り込み待ち〜Enter）。
    private(set) var isSending = false
    private(set) var end: End?
    /// 最後に解決できた sessionId。終了して監視の対応表から消えた後も会話を出すために持ち続ける。
    @ObservationIgnored var lastSessionId: String?
    /// 最後にローカル判定が変わった時刻（監視の開始前の並び順に使う）。
    private(set) var lastChangeAt = Date()

    @ObservationIgnored var onLimitReached: ((HostedSession) -> Void)?
    /// iPhone に出すカードの世代と答えた ID（同じ文面で出し直された確認を古い表示から答えさせないため）。
    @ObservationIgnored private(set) var promptTracker = RemotePromptTracker()
    /// 外部から引き継いだ時の再開対象。
    let resumeSessionId: String?

    init(project: ManagedProject, resumeSessionId: String? = nil) {
        self.project = project
        self.resumeSessionId = resumeSessionId
        // pid と対応付くまでの間も同じ会話を出し、外部ルームとして二重に並ばないようにする。
        self.lastSessionId = resumeSessionId
        // 起動時点の桁数で TUI が組まれるので、0 幅ではなく現実的な大きさで作る。
        self.terminal = ClaudeTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        // 画面に載せないので桁は自由に取れる。狭いと問いや選択肢の説明が折り返して読みにくいので広げる（起動前に決める）。
        let columns = terminal.getTerminal().cols
        if columns > 0, columns < Self.terminalColumns {
            let width = (terminal.frame.width * CGFloat(Self.terminalColumns) / CGFloat(columns)).rounded(.up)
            terminal.setFrameSize(NSSize(width: width, height: terminal.frame.height))
        }
        terminal.processDelegate = observer
        terminal.onStatusChanged = { [weak self] status in
            self?.localStatus = status
            self?.lastChangeAt = Date()
        }
        terminal.onPermissionPromptChanged = { [weak self] in
            self?.permissionPrompt = $0
            self?.trackCard()
        }
        terminal.onInputBlockChanged = { [weak self] in
            self?.inputBlock = $0
            self?.trackCard()
        }
        terminal.onMenuPromptChanged = { [weak self] in
            self?.menuPrompt = $0
            self?.trackCard()
        }
        terminal.onUnreadableMenuChanged = { [weak self] in
            self?.unreadableMenu = $0
            self?.trackCard()
        }
        terminal.onSendingChanged = { [weak self] in self?.isSending = $0 }
        terminal.onLimitReached = { [weak self] in self?.handleLimitReached() }
        observer.onTerminated = { [weak self] code in self?.handleExit(code) }
    }

    /// 端末の桁数の目安。
    static let terminalColumns = 160

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

    /// 今の sessionId（監視の対応表から引けなければ最後に解決できたもの）。
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

    func send(_ text: String, attachments: [Attachment] = [],
              completion: @escaping (SendCompletion) -> Void) -> ClaudeTerminalView.SendResult? {
        guard isRunning else { return nil }
        return terminal.sendMessage(text, attachments: attachments, completion: completion)
    }

    func answerPermission(_ expected: PermissionPrompt, allow: Bool) -> ClaudeTerminalView.AnswerResult {
        guard isRunning else { return .noPrompt }
        return terminal.answerPermission(expected, allow: allow)
    }

    func answerMenu(_ expected: MenuPrompt, choice: Int?, completion: @escaping (ClaudeTerminalView.MenuAnswerOutcome) -> Void) {
        guard isRunning else { return completion(.ended) }
        terminal.answerMenu(expected, choice: choice, completion: completion)
    }

    func moveMenuTab(_ expected: MenuPrompt, direction: MenuTabMover.Direction, completion: @escaping (ClaudeTerminalView.MenuAnswerOutcome) -> Void) {
        guard isRunning else { return completion(.ended) }
        terminal.moveMenuTab(expected, direction: direction, completion: completion)
    }

    func cancelUnreadableMenu(_ expected: UnreadableMenu) -> ClaudeTerminalView.UnreadableCancelResult {
        guard isRunning else { return .gone }
        return terminal.cancelUnreadableMenu(expected)
    }

    /// 端末に出ている答えられる表示（会話末尾のカードと同じ優先順）。
    var terminalCard: RemoteTerminalCard? {
        RemoteTerminalCard.current(permissionPrompt: permissionPrompt, inputBlock: inputBlock, menuPrompt: menuPrompt,
                                   unreadableMenu: unreadableMenu)
    }

    func markAnswered(_ id: String) {
        promptTracker.markAnswered(id)
    }

    private func trackCard() {
        promptTracker.observe(terminalCard)
    }

    private func clearScreenState() {
        permissionPrompt = nil
        inputBlock = nil
        menuPrompt = nil
        unreadableMenu = nil
        trackCard()
    }

    private func handleLimitReached() {
        guard end == nil else { return }
        end = .limitReached
        clearScreenState()
        terminal.stopStatusMonitoring()
        terminal.terminate()
        release()
        onLimitReached?(self)
    }

    private func handleExit(_ code: Int32?) {
        terminal.stopStatusMonitoring()
        if end == nil { end = .exited(code) }
        clearScreenState()
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
