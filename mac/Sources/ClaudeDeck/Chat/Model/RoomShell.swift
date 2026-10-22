import AppKit
import Observation
import SwiftTerm
import MonitorKit

/// ルームのターミナルの端末ビュー（画面に載せる）。起動直後の送信の待ちと、打ちかけの入力の有無を見るため、受けた時刻と送ったキーを追う。
final class ShellTerminalView: LocalProcessTerminalView {
    var lastDataAt: Date?
    /// プロンプトに打ちかけの入力が残っているかもしれない（Enter・Ctrl-C で消える）。
    private(set) var pendingLineInput = false

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        lastDataAt = Date()
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        pendingLineInput = ShellLineInput.pending(after: Array(data), previous: pendingLineInput)
        super.send(source: source, data: data)
    }
}

/// ルームごとに 1 つの対話シェル（利用者のログインシェル・ルームの cwd）。端末ビューはメインと別ウィンドウのうち 1 か所にだけ載せる。
@MainActor
@Observable
final class RoomShell {
    enum Phase: Equatable {
        case notStarted
        case running
        /// waitpid の生の status（分からなければ nil）。
        case exited(Int32?)
        case failed(String)
    }

    /// 送る待ちの 1 件。`confirmed` は利用者が確かめた後のもの（送る直前の見直しをしない）。
    struct Pending {
        let command: ProjectCommand
        let confirmed: Bool
    }

    let cwd: String
    private(set) var phase: Phase = .notStarted
    /// 端末を出している場所（メインと別ウィンドウの画面の印）。
    private(set) var hosts = TerminalHostOwner<UUID>()
    /// コマンドの実行前に毎回 API キーを外す守りが効いているか（zsh の起動ファイルを挟めた時だけ）。
    private(set) var scrubsEachCommand = true

    /// 確かめずに積んだコマンドが、送る直前に安全でなくなった（呼び手が確認を出す）。
    @ObservationIgnored var onNeedsConfirmation: ((ProjectCommand, [ShellSendReason]) -> Void)?
    /// シェルが自分で終わって残ったジョブの停止を始めた（呼び手が持ち、アプリの終了でも待つ）。
    @ObservationIgnored var onStopStarted: ((ShellSessionStop) -> Void)?

    @ObservationIgnored private(set) var terminal: ShellTerminalView?
    @ObservationIgnored private var hostViews: [UUID: WeakShellHost] = [:]
    @ObservationIgnored private let observer = TerminalProcessObserver()
    @ObservationIgnored private var pid: pid_t = 0
    /// startProcess 直後に控えた master。SwiftTerm は EOF で childfd を -1 にするが、terminate まで fd は開いたまま。
    @ObservationIgnored private var masterFD: Int32 = -1
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var pendingSends: [Pending] = []
    @ObservationIgnored private var draining = false
    @ObservationIgnored private(set) var lastSentAt: Date?
    /// 動いている間に見たセッションのグループ（シェルが終わると端末の紐づけが外れ、残ったジョブを端末で探せないため）。
    @ObservationIgnored private var knownGroups: Set<pid_t> = []
    @ObservationIgnored private var recordTimer: Timer?
    /// 次に端末を載せた時に入力の先にする（タブ・「ここに表示」・コマンドを押した時だけ）。
    @ObservationIgnored private var pendingFocus = false

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

    /// 送る前に確かめる理由（本文の承認は呼び手が渡す）。
    func sendReasons(approved: Bool, now: Date = Date()) -> [ShellSendReason] {
        ShellSendCheck.reasons(approved: approved, running: isRunning, foreground: foreground,
                               pendingInput: terminal?.pendingLineInput ?? false,
                               queued: draining || !pendingSends.isEmpty, lastSentAt: lastSentAt, now: now)
    }

    /// 前面がシェルでない（ターミナルで何かが動いている）。閉じる・終了の確認に使う。
    var isBusy: Bool { isRunning && foreground != .prompt }

    var exitMessage: String? {
        guard case .exited(let status) = phase else { return nil }
        return ShellExitStatus.message(rawStatus: status)
    }

    /// 起動する（動いていれば何もしない）。起動できなければ false。
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        guard RoomShells.canOpen(cwd) else {
            phase = .failed("フォルダが見つかりません: \(cwd)")
            return false
        }
        // 料金事故ゼロ: claude と同じく API キーと子セッションの印を除いた環境で起動し、zsh ではコマンドごとにも外す。
        let launch = ShellLaunch.make(base: ProcessInfo.processInfo.environment, wrapperDirectory: ZshWrapper.prepare())
        guard let view = Self.launch(launch, in: cwd) else {
            phase = .failed("シェル（\(launch.executable)）を起動できませんでした")
            return false
        }
        view.processDelegate = observer
        terminal?.removeFromSuperview()
        terminal = view
        masterFD = view.process.childfd
        pid = view.process.shellPid
        startedAt = Date()
        knownGroups = [pid]
        lastSentAt = nil
        scrubsEachCommand = launch.scrubsEachCommand
        phase = .running
        startRecording()
        placeTerminal()
        return true
    }

    /// 端末を作ってシェルを起動し、master に CLOEXEC を付ける（後から起動する子に持たせない）。起動できなければ nil。
    private static func launch(_ launch: ShellLaunch, in cwd: String) -> ShellTerminalView? {
        let view = ShellTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.startProcess(executable: launch.executable, args: launch.arguments, environment: launch.environmentList,
                          execName: nil, currentDirectory: cwd)
        let fd = view.process.childfd
        guard view.process.running, fd >= 0, view.process.shellPid > 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return view
    }

    /// コマンドを積む（動いていなければ起動し、入力を受けられるようになってから送る）。起動できなければ false。
    func run(_ command: ProjectCommand, confirmed: Bool) -> Bool {
        guard start() else { return false }
        pendingSends.append(Pending(command: command, confirmed: confirmed))
        requestFocus()
        drain()
        return true
    }

    /// 送る順に 1 つずつ、貼り付け → 少し待って Enter。確かめずに積んだものは送る直前に前面と打ちかけを見直す。
    private func drain() {
        guard !draining, isRunning, let terminal, let next = pendingSends.first else { return }
        let bracketed = terminal.getTerminal().bracketedPasteMode
        let now = Date()
        guard ShellInput.isReady(bracketedPaste: bracketed, startedAt: startedAt, lastOutputAt: terminal.lastDataAt, now: now) else {
            return retryDrain()
        }
        if !next.confirmed, !ShellSendCheck.stillSafe(foreground: foreground, pendingInput: terminal.pendingLineInput) {
            // 起動直後は設定の読み込みが前面にいることがあるので、しばらくは待つ。
            if now.timeIntervalSince(startedAt) < ShellInput.readyTimeout * 2, !terminal.pendingLineInput { return retryDrain() }
            pendingSends = []
            let reasons = sendReasons(approved: true, now: now)
            onNeedsConfirmation?(next.command, reasons.isEmpty ? [.busy] : reasons)
            return
        }
        pendingSends.removeFirst()
        guard let body = ShellInput.body(next.command.command, bracketedPaste: bracketed) else { return drain() }
        draining = true
        lastSentAt = now
        terminal.send(txt: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + ShellInput.submitDelay) { [weak self, weak terminal] in
            guard let self else { return }
            self.draining = false
            if let terminal, self.terminal === terminal, self.isRunning {
                terminal.send(txt: PTYInput.submitKey)
                self.lastSentAt = Date()
            }
            // 再起動した後でも、積まれた分を流し直す。
            self.drain()
        }
    }

    private func retryDrain() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.drain() }
    }

    // MARK: - 止める

    /// シェルのセッション（ジョブを含む）に SIGHUP を送って PTY を閉じる。残りの手順（SIGTERM → SIGKILL・刈り取り）は返したものが進める。
    func stop() -> ShellSessionStop? {
        pendingSends = []
        hosts = TerminalHostOwner()
        hostViews = [:]
        stopRecording()
        terminal?.removeFromSuperview()
        observer.onTerminated = nil
        defer { terminal = nil }
        guard isRunning, let terminal else { return nil }
        recordGroups()
        phase = .exited(nil)
        let stop = ShellSessionStop(leader: pid, master: masterFD, knownGroups: knownGroups, reapLeader: true)
        // 刈り取り前の自分の子なので pid の使い回しは起きない（同じ main の周回の中）。
        terminal.terminate()
        masterFD = -1
        return stop
    }

    /// シェルが自分で終わった。残ったジョブは記録したグループから探して止める。
    private func handleExit(_ status: Int32?) {
        guard isRunning else { return }
        phase = .exited(status)
        pendingSends = []
        stopRecording()
        let stop = ShellSessionStop(leader: pid, master: masterFD, knownGroups: knownGroups)
        onStopStarted?(stop)
    }

    private func startRecording() {
        recordTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.recordGroups()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordTimer = timer
    }

    private func stopRecording() {
        recordTimer?.invalidate()
        recordTimer = nil
    }

    private func recordGroups() {
        guard isRunning, let groups = ShellSessionStop.currentGroups(leader: pid, master: masterFD) else { return }
        knownGroups.formUnion(groups)
    }

    // MARK: - 端末を出す場所

    /// 見え始めた・前に出た・「ここに表示」を押した場所へ端末を移す（入力の先にはしない）。
    func claim(_ id: UUID, view: ShellHostView? = nil) {
        if let view { hostViews[id] = WeakShellHost(view: view, serial: view.serial) }
        guard hostViews[id]?.view != nil else { return }
        hosts.claim(id)
        placeTerminal()
    }

    /// `serial` を渡した時は、同じ場所の印で後から載った入れ物を外さないよう、その入れ物が載っている時だけ手放す。
    func release(_ id: UUID, serial: UUID? = nil) {
        if let serial, let current = hostViews[id], current.view != nil, current.serial != serial { return }
        hostViews[id] = nil
        guard hosts.hosts.contains(id) else { return }
        hosts.release(id)
        placeTerminal()
    }

    /// 次に端末を載せた時（載っていれば今）に入力の先にする。
    func requestFocus() {
        pendingFocus = true
        placeTerminal()
    }

    private func placeTerminal() {
        // 消えた入れ物は外す（外れの知らせより先に破棄されることがある）。
        for id in hosts.hosts where hostViews[id]?.view == nil { hosts.release(id) }
        guard let terminal else { return }
        guard let owner = hosts.owner, let host = hostViews[owner]?.view else {
            terminal.removeFromSuperview()
            return
        }
        host.install(terminal)
        if pendingFocus, isRunning, let window = host.window {
            pendingFocus = false
            window.makeFirstResponder(terminal)
        }
    }
}


struct WeakShellHost {
    weak var view: ShellHostView?
    /// 入れ物ごとの印（同じ場所の印で作り直された入れ物と見分ける）。
    let serial: UUID
}

/// 端末を載せる入れ物。ウィンドウに載った・前に出た時に名乗り出て、外れた時に手放す。
final class ShellHostView: NSView {
    let id: UUID
    let serial = UUID()
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
        let serial = serial
        DispatchQueue.main.async { [weak self, weak shell] in
            guard let shell else { return }
            if let self, self.window != nil, self.shell === shell {
                shell.claim(id, view: self)
            } else {
                shell.release(id, serial: serial)
            }
        }
    }

    func detach() {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        let previous = shell
        shell = nil
        let id = id
        let serial = serial
        DispatchQueue.main.async { [weak previous] in previous?.release(id, serial: serial) }
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
