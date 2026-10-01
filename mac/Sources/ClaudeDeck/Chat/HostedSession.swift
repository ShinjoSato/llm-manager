import AppKit
import Observation
import SwiftTerm
import MonitorKit

/// アプリが PTY でホストしている claude 1 つ（= 1 ルーム）。ルームやタブを切り替えても端末とプロセスはここで生き続ける。
@MainActor
@Observable
final class HostedSession: Identifiable {
    enum End: Equatable {
        case exited(Int32?)
        case limitReached
    }

    let id = UUID()
    let project: ManagedProject
    let startedAt = Date()
    @ObservationIgnored let terminal: ClaudeTerminalView
    @ObservationIgnored private let observer = TerminalProcessObserver()

    private(set) var pid: Int32?
    private(set) var localStatus: ClaudeStatus = .idle
    private(set) var permissionPrompt: PermissionPrompt?
    private(set) var end: End?
    /// 最後にローカル判定が変わった時刻（monitor 未接続時の並び順に使う）。
    private(set) var lastChangeAt = Date()

    @ObservationIgnored var onLimitReached: ((HostedSession) -> Void)?

    init(project: ManagedProject) {
        self.project = project
        // 起動時点の桁数で TUI が組まれるので、0 幅ではなく現実的な大きさで作る。
        self.terminal = ClaudeTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        terminal.processDelegate = observer
        terminal.onStatusChanged = { [weak self] status in
            self?.localStatus = status
            self?.lastChangeAt = Date()
        }
        terminal.onPermissionPromptChanged = { [weak self] in self?.permissionPrompt = $0 }
        terminal.onLimitReached = { [weak self] in self?.handleLimitReached() }
        observer.onTerminated = { [weak self] code in self?.handleExit(code) }
    }

    var isRunning: Bool { end == nil && pid != nil }

    func start() {
        guard pid == nil, end == nil else { return }
        terminal.launchClaude(in: project.path)
        if let pid = terminal.claudePid {
            self.pid = pid
            MonitorBridge.store.registerHostedProcess(pid: pid)
        }
    }

    /// claude を終わらせる（ルームを閉じる時）。
    func terminate() {
        terminal.stopStatusMonitoring()
        if end == nil { terminal.terminate() }
        release()
    }

    func send(_ text: String, onAborted: (() -> Void)? = nil) -> ClaudeTerminalView.SendResult? {
        guard isRunning else { return nil }
        return terminal.sendMessage(text, onAborted: onAborted)
    }

    func answerPermission(allow: Bool) -> Bool {
        guard isRunning else { return false }
        return terminal.answerPermission(allow: allow)
    }

    private func handleLimitReached() {
        guard end == nil else { return }
        end = .limitReached
        terminal.stopStatusMonitoring()
        terminal.terminate()
        release()
        onLimitReached?(self)
    }

    private func handleExit(_ code: Int32?) {
        terminal.stopStatusMonitoring()
        if end == nil { end = .exited(code) }
        permissionPrompt = nil
        release()
    }

    private func release() {
        guard let pid else { return }
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
