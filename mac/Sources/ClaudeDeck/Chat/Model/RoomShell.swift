import AppKit
import Observation
import SwiftTerm
import MonitorKit

/// ルームのターミナルの端末ビュー（画面に載せる）。起動直後の送信の待ちに使うため、最後に受けた時刻を覚える。
final class ShellTerminalView: LocalProcessTerminalView {
    var lastDataAt: Date?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        lastDataAt = Date()
    }
}

/// ルームごとに 1 つの対話シェル（利用者のログインシェル・ルームの cwd）。端末ビューはメインと別ウィンドウのうち 1 か所にだけ載せる。
@MainActor
@Observable
final class RoomShell {
    enum Phase: Equatable {
        case notStarted
        case running
        case exited(Int32?)
        case failed(String)
    }

    let cwd: String
    private(set) var phase: Phase = .notStarted
    /// 端末を出している場所（メインと別ウィンドウの画面の印）。
    private(set) var hosts = TerminalHostOwner<UUID>()

    @ObservationIgnored private(set) var terminal: ShellTerminalView?
    @ObservationIgnored private var hostViews: [UUID: WeakShellHost] = [:]
    @ObservationIgnored private let observer = TerminalProcessObserver()
    @ObservationIgnored private var pid: pid_t = 0
    /// startProcess 直後に控えた master。SwiftTerm は EOF で childfd を -1 にするが、terminate まで fd は開いたまま。
    @ObservationIgnored private var masterFD: Int32 = -1
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var pendingSends: [String] = []
    @ObservationIgnored private var draining = false

    init(cwd: String) {
        self.cwd = cwd
        observer.onTerminated = { [weak self] code in self?.handleExit(code) }
    }

    var isRunning: Bool { phase == .running }

    /// 前面のプロセス（動いていなければ判定できない）。
    var foreground: ShellForeground {
        guard isRunning else { return .unknown }
        return ShellForeground.current(master: masterFD, shellPid: pid)
    }

    /// 起動する（動いていれば何もしない）。起動できなければ false。
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        guard RoomShells.canOpen(cwd) else {
            phase = .failed("フォルダが見つかりません: \(cwd)")
            return false
        }
        let view = ShellTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.processDelegate = observer
        // 料金事故ゼロ: claude と同じく API キーと子セッションの印を除いた環境で起動する。
        let launch = ShellLaunch.make(base: ProcessInfo.processInfo.environment, wrapperDirectory: ZshWrapper.prepare())
        view.startProcess(executable: launch.executable, args: launch.arguments, environment: launch.environmentList,
                          execName: nil, currentDirectory: cwd)
        let fd = view.process.childfd
        let shellPid = view.process.shellPid
        guard view.process.running, fd >= 0, shellPid > 0 else {
            phase = .failed("シェル（\(launch.executable)）を起動できませんでした")
            return false
        }
        // 後から起動する子（claude 等）に master を持たせない（持たれると閉じても切断が届かない）。
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        terminal?.removeFromSuperview()
        terminal = view
        masterFD = fd
        pid = shellPid
        startedAt = Date()
        phase = .running
        placeTerminal(focus: true)
        return true
    }

    /// コマンドを送る（動いていなければ起動し、入力を受けられるようになってから）。起動できなければ false。
    func run(_ text: String) -> Bool {
        guard start() else { return false }
        pendingSends.append(text)
        drain()
        return true
    }

    /// 送る順に 1 つずつ、貼り付け → 少し待って Enter。
    private func drain() {
        guard !draining, isRunning, let terminal, !pendingSends.isEmpty else { return }
        let bracketed = terminal.getTerminal().bracketedPasteMode
        guard ShellInput.isReady(bracketedPaste: bracketed, startedAt: startedAt, lastOutputAt: terminal.lastDataAt, now: Date()) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.drain() }
            return
        }
        let text = pendingSends.removeFirst()
        guard let body = ShellInput.body(text, bracketedPaste: bracketed) else { return drain() }
        draining = true
        terminal.send(txt: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + ShellInput.submitDelay) { [weak self, weak terminal] in
            guard let self else { return }
            self.draining = false
            guard let terminal, self.terminal === terminal, self.isRunning else { return }
            terminal.send(txt: PTYInput.submitKey)
            self.drain()
        }
    }

    // MARK: - 止める

    /// シェルのセッション（ジョブを含む）に SIGHUP を送って PTY を閉じる。残りの手順（SIGTERM → SIGKILL）は返したものが進める。
    func stop() -> ShellSessionStop? {
        pendingSends = []
        hosts = TerminalHostOwner()
        hostViews = [:]
        terminal?.removeFromSuperview()
        observer.onTerminated = nil
        defer { terminal = nil }
        guard isRunning, let terminal else { return nil }
        phase = .exited(nil)
        let stop = ShellSessionStop(leader: pid, master: masterFD)
        // 刈り取り前の自分の子なので pid の使い回しは起きない（同じ main の周回の中）。
        terminal.terminate()
        masterFD = -1
        return stop
    }

    /// シェルが自分で終わった。残ったジョブは止める（PTY はまだ開いているので端末で確かめられる）。
    private func handleExit(_ code: Int32?) {
        guard isRunning else { return }
        phase = .exited(code)
        pendingSends = []
        let stop = ShellSessionStop(leader: pid, master: masterFD)
        Task.detached { await stop.finish() }
    }

    // MARK: - 端末を出す場所

    /// 見え始めた・前に出た・「ここに表示」を押した場所へ端末を移す。
    func claim(_ id: UUID, view: ShellHostView? = nil) {
        if let view { hostViews[id] = WeakShellHost(view: view) }
        guard hostViews[id]?.view != nil else { return }
        // 既に出している場所が前に出ただけなら、利用者が選んだ欄からフォーカスを奪わない。
        let moved = hosts.owner != id || terminal?.superview !== hostViews[id]?.view
        hosts.claim(id)
        placeTerminal(focus: moved)
    }

    func release(_ id: UUID) {
        hostViews[id] = nil
        guard hosts.hosts.contains(id) else { return }
        hosts.release(id)
        placeTerminal(focus: false)
    }

    private func placeTerminal(focus: Bool) {
        // 消えた入れ物は外す（外れの知らせより先に破棄されることがある）。
        for id in hosts.hosts where hostViews[id]?.view == nil { hosts.release(id) }
        guard let terminal else { return }
        guard let owner = hosts.owner, let host = hostViews[owner]?.view else {
            terminal.removeFromSuperview()
            return
        }
        host.install(terminal)
        if focus, isRunning { host.window?.makeFirstResponder(terminal) }
    }
}

struct WeakShellHost {
    weak var view: ShellHostView?
}

/// 端末を載せる入れ物。ウィンドウに載った・前に出た時に名乗り出て、外れた時に手放す。
final class ShellHostView: NSView {
    let id: UUID
    weak var shell: RoomShell?
    private var keyObserver: NSObjectProtocol?

    init(id: UUID) {
        self.id = id
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        sync()
        guard let window else { return }
        // 今見ているウィンドウに端末を出す。
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    /// 画面の更新の途中で観測される状態を変えないよう、次の周回で名乗り出る（ウィンドウから外れていれば手放す）。
    func sync() {
        let id = id
        DispatchQueue.main.async { [weak self, weak shell] in
            guard let shell else { return }
            if let self, self.window != nil, self.shell === shell {
                shell.claim(id, view: self)
            } else {
                shell.release(id)
            }
        }
    }

    func detach() {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        let previous = shell
        shell = nil
        let id = id
        DispatchQueue.main.async { [weak previous] in previous?.release(id) }
    }

    func install(_ terminal: ShellTerminalView) {
        if terminal.superview !== self {
            terminal.removeFromSuperview()
            addSubview(terminal)
        }
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        applyColors(to: terminal)
    }

    override func layout() {
        super.layout()
        for view in subviews { view.frame = bounds }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for case let terminal as ShellTerminalView in subviews { applyColors(to: terminal) }
    }

    /// テーマの色を今の外観で解決して渡す（端末は色を固定値で持つため）。
    private func applyColors(to terminal: ShellTerminalView) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            terminal.nativeBackgroundColor = ChatTheme.nsBackground.usingColorSpace(.deviceRGB) ?? .black
            terminal.nativeForegroundColor = ChatTheme.nsText.usingColorSpace(.deviceRGB) ?? .white
        }
    }
}
