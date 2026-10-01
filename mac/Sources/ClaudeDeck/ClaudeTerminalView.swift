import AppKit
import SwiftTerm
import MonitorKit

/// Claude Code の作業状態（ペイン見出しのバッジ表示に使う）。
enum ClaudeStatus: Equatable {
    case working        // 出力が流れている（生成中）
    case waitingInput   // 権限確認・選択メニュー・質問プロンプトを検出（要応答）
    case idle           // 出力停止 かつ プロンプト無し（待機/完了）
}

/// Claude Code を PTY でホストする端末ビュー。
///
/// 設計上の安全装置（料金事故をゼロにする）:
///  - 子プロセスの環境から `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` を必ず除去する。
///    API 課金経路が存在しないため、Max 枠の上限に達しても「待つ」だけで課金は発生しない。
///  - headless（`claude -p` / Agent SDK）の起動口は一切設けない。
///
/// さらに、上限到達（公式の残量 100% か、画面末尾の上限表示）を検知したらセッションを強制終了する。
final class ClaudeTerminalView: LocalProcessTerminalView {

    /// 上限到達を検知したときに呼ばれる（メインスレッド）。
    var onLimitReached: (() -> Void)?

    /// 作業ステータスが変化したときに呼ばれる（メインスレッド）。
    var onStatusChanged: ((ClaudeStatus) -> Void)?

    /// 画面に出ている権限プロンプトが変わったときに呼ばれる（メインスレッド）。
    var onPermissionPromptChanged: ((PermissionPrompt?) -> Void)?

    /// 入力欄への送信を止める状態が変わったときに呼ばれる（メインスレッド）。
    var onInputBlockChanged: ((InputBlock?) -> Void)?

    /// 画面に出ている選択メニューの中身が変わったときに呼ばれる（メインスレッド）。
    var onMenuPromptChanged: ((MenuPrompt?) -> Void)?

    private(set) var permissionPrompt: PermissionPrompt?
    private(set) var inputBlock: InputBlock?
    private(set) var menuPrompt: MenuPrompt?
    /// 選択肢へ ❯ を動かしている最中。重ねて動かすと互いのキーで行き先がずれる。
    private(set) var isNavigatingMenu = false

    private var limitHandled = false
    private var limitCheckPending = false

    // MARK: - ステータス検知（ハイブリッド: 活動量 + プロンプト文言）
    private var statusTimer: Timer?
    private var lastDataTime = Date()
    private(set) var currentStatus: ClaudeStatus = .idle

    /// 「最後の出力からこの秒数以内」なら出力が流れている＝作業中とみなす（活動量ベース）。
    private static let busyThreshold: TimeInterval = 1.0

    /// 実行中インジケータ。これが現在画面に出ている間は、出力が一時的に止まっても作業中とみなす。
    /// 長い bash 実行やネット待ちで出力が途切れても「完了」へ誤遷移しないための補助シグナル。
    /// ⚠️ Claude Code の TUI 文言に合わせて要・実機検証。
    private static let busyMarkers: [String] = [
        "esc to interrupt"
    ]

    /// 指定プロジェクトのディレクトリで `claude` を起動する。
    /// ログインシェル経由で PATH（~/.local/bin など）を継承しつつ、API キーは二重に遮断する。
    /// `resumeSessionId` があれば対話起動のまま `claude --resume=<id>` で会話を再開する。不正な id なら起動せず false。
    @discardableResult
    func launchClaude(in directory: String, resumeSessionId: String? = nil) -> Bool {
        var command = "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; exec claude"
        if let resumeSessionId {
            // シェルのコマンド行に埋め込むので UUID の形のものだけを `--resume=<id>` で渡す。
            guard let argument = SessionHandover.resumeArgument(resumeSessionId) else { return false }
            command += " \(argument)"
        }
        let env = Self.buildSafeEnvironment()
        startProcess(
            executable: "/bin/zsh",
            // -l ログインシェルで PATH を取得、-i 対話、-c コマンド。
            // 渡す環境からは既に API キーを抜いてあるが、念のためシェル側でも unset してから exec。
            args: ["-lic", command],
            environment: env,
            execName: nil,
            currentDirectory: directory
        )
        startStatusMonitoring()
        LimitWatch.shared.register(self)
        return true
    }

    /// 起動した claude の pid。`exec claude` で zsh を置き換えるので PTY の子 pid がそのまま claude になる。
    var claudePid: pid_t? {
        guard let pid = process?.shellPid, pid > 0 else { return nil }
        return pid
    }

    deinit { statusTimer?.invalidate() }

    // MARK: - ステータス監視

    private func startStatusMonitoring() {
        guard statusTimer == nil else { return }
        lastDataTime = Date()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.evaluateStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    /// ステータス監視を停止する（セッション終了・上限到達・ペインクローズ時）。
    func stopStatusMonitoring() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    /// 現在のステータスを判定し、変化時のみ通知する。
    /// 判定は端末の「現在画面の下数行」を直接読む（履歴が累積する scanBuffer は使わない）ため、
    /// プロンプト応答後に古い文言が残って誤判定する問題が起きない。
    /// dataReceived も Timer も SwiftTerm 既定キュー（main）上で動くので端末バッファ参照は安全。
    func evaluateStatus() {
        let screen = screenLines()
        let tail = Self.tailText(screen, lines: 8)
        let quiet = Date().timeIntervalSince(lastDataTime)
        // 権限プロンプト・選択メニュー表示中も点滅表示で出力が流れ続けるので、活動量より先に見る。
        let prompt = PermissionPrompt.parse(screen: screen)
        let block = InputBlock.detect(screen: screen)
        let newStatus: ClaudeStatus
        if block != nil {
            newStatus = .waitingInput
        } else if quiet < Self.busyThreshold || Self.busyMarkers.contains(where: { tail.contains($0) }) {
            newStatus = .working
        } else if InputBlock.looksWaiting(tail: tail) {
            // 文言だけの判定は返答本文と取り違えうるので、バッジにだけ使い送信は止めない。
            newStatus = .waitingInput
        } else {
            newStatus = .idle
        }
        if prompt != permissionPrompt {
            permissionPrompt = prompt
            onPermissionPromptChanged?(prompt)
        }
        if block != inputBlock {
            inputBlock = block
            onInputBlockChanged?(block)
        }
        let menu = block == .menu ? ChoiceMenu.parse(screen: screen) : nil
        if menu != menuPrompt {
            menuPrompt = menu
            onMenuPromptChanged?(menu)
        }
        guard newStatus != currentStatus else { return }
        currentStatus = newStatus
        onStatusChanged?(newStatus)   // Timer は main runloop なのでメインスレッド
    }

    /// アプリが今いじっている実画面の全行（上から順・右端の空白は除く）。
    /// ターミナル表示で上にスクロールしていても、表示位置（yDisp）ではなく末尾の `rows` 行を読む。
    /// SwiftTerm は `lines.count == yBase + rows` を保つが yBase を公開していないので、行数を探って求める。
    func screenLines() -> [String] {
        let term = getTerminal()
        let rows = term.rows
        guard rows > 0 else { return [] }
        let top = term.buffer.totalLinesTrimmed
        let count = TerminalScreen.lineCount(rows: rows) { term.getScrollInvariantLine(row: top + $0) != nil }
        let base = max(0, count - rows)
        return (base..<count).compactMap { term.getScrollInvariantLine(row: top + $0).map(Self.text(of:)) }
    }

    /// 送信を止めるべき状態か。タイマーを待たず今の画面で判定する。
    func currentInputBlock() -> InputBlock? {
        InputBlock.detect(screen: screenLines())
    }

    /// 送信を途中で取りやめ、端末の入力欄に本文を残したかもしれない。
    private(set) var mayHaveLeftover = false

    // MARK: - 入力（本人のキー入力として PTY に書く）

    enum SendResult: Equatable {
        case sent
        case empty
        /// 権限プロンプト・選択メニューの表示中。Enter がその選択になってしまうので送らない。
        case blocked(InputBlock)
        /// 取りやめた送信の本文が端末の入力欄に残っている。続けて貼ると前回の本文とくっつくので送らない。
        case leftover
    }

    /// チャット欄の本文を入力欄に貼り付けてから Enter で送る。作業中でも Claude Code 側でキューに積まれる。
    /// 貼り付けの前に必ず判定するので、止める時は入力欄に何も入れない。
    /// `onAborted` は貼り付けから Enter までの間に止めるべき状態になり、Enter を押さずにやめた時に呼ばれる（本文は入力欄に残る）。
    func sendMessage(_ text: String, onAborted: ((InputBlock) -> Void)? = nil) -> SendResult {
        let screen = screenLines()
        if let block = InputBlock.detect(screen: screen) { return .blocked(block) }
        if mayHaveLeftover {
            // 入力欄が読めない時は残りを確かめられないが、くっつく害は小さいので送る（印は残す）。
            if let boxText = InputBox.text(screen: screen) {
                mayHaveLeftover = false
                // 警告は 1 回だけ。未知の薄字表示を本文と誤認しても、もう一度送れば送れるようにする。
                guard boxText.isEmpty else { return .leftover }
            }
        }
        guard let body = PTYInput.messageBody(text, bracketedPaste: getTerminal().bracketedPasteMode) else { return .empty }
        send(txt: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + PTYInput.submitDelay) { [weak self] in
            guard let self else { return }
            if let block = self.currentInputBlock() {
                self.mayHaveLeftover = true
                onAborted?(block)
                return
            }
            self.send(txt: PTYInput.submitKey)
        }
        return .sent
    }

    enum AnswerResult: Equatable {
        case sent
        /// 権限プロンプトが出ていない。入力欄へ文字が入るのを避けて何もしない。
        case noPrompt
        /// 押した時に見ていたものと別のプロンプトに替わっている。
        case changed(PermissionPrompt)
    }

    /// 権限プロンプトに答える。`expected`（カードに出していたもの）と今の画面のプロンプトが一致する時だけキーを送る。
    func answerPermission(_ expected: PermissionPrompt, allow: Bool) -> AnswerResult {
        guard let current = PermissionPrompt.parse(screen: screenLines()) else {
            evaluateStatus()
            return .noPrompt
        }
        guard current == expected else {
            evaluateStatus()
            return .changed(current)
        }
        send(txt: allow ? PTYInput.allowKey : PTYInput.denyKey)
        return .sent
    }

    enum MenuAnswerOutcome: Equatable {
        case confirmed
        case cancelled
        case failed(MenuNavigator.Failure)
        /// 押せない選択肢（自由入力）か、別の選択肢へ動かしている最中。
        case unavailable
    }

    /// 今の画面の選択メニュー（権限プロンプトが出ていれば nil）。
    private func currentMenu() -> MenuPrompt? {
        let screen = screenLines()
        guard InputBlock.detect(screen: screen) == .menu else { return nil }
        return ChoiceMenu.parse(screen: screen)
    }

    /// 選択メニューに答える。`choice` は `expected`（カードに出していたもの）の選択肢の位置、nil なら Esc で取り消す。
    /// 今の画面のメニューが `expected` と同じ時だけキーを送り、❯ を矢印で 1 行ずつ動かして着いたのを確かめてから Enter を送る。
    func answerMenu(_ expected: MenuPrompt, choice: Int?, completion: @escaping (MenuAnswerOutcome) -> Void) {
        guard !isNavigatingMenu else { return completion(.unavailable) }
        guard let choice else {
            guard let current = currentMenu() else {
                evaluateStatus()
                return completion(.failed(.gone))
            }
            guard current.sameMenu(as: expected) else {
                evaluateStatus()
                return completion(.failed(.changed))
            }
            send(txt: PTYInput.cancelMenuKey)
            return completion(.cancelled)
        }
        guard let navigator = MenuNavigator(expected: expected, target: choice) else { return completion(.unavailable) }
        isNavigatingMenu = true
        stepMenu(navigator, completion: completion)
    }

    private func stepMenu(_ navigator: MenuNavigator, completion: @escaping (MenuAnswerOutcome) -> Void) {
        var navigator = navigator
        guard process?.running == true else {
            isNavigatingMenu = false
            return completion(.failed(.gone))
        }
        switch navigator.next(currentMenu()) {
        case .confirm:
            send(txt: PTYInput.confirmMenuKey)
            isNavigatingMenu = false
            completion(.confirmed)
            return
        case .abort(let failure):
            isNavigatingMenu = false
            evaluateStatus()
            completion(.failed(failure))
            return
        case .press(let direction):
            send(txt: PTYInput.arrowKey(direction, applicationCursor: getTerminal().applicationCursor))
        case .wait:
            break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + PTYInput.menuStepInterval) { [weak self] in
            self?.stepMenu(navigator, completion: completion)
        }
    }

    /// 中身を読み取れない選択メニューを Esc で閉じる。メニューが出ている時だけ送る。
    func cancelUnreadableMenu() -> Bool {
        guard !isNavigatingMenu, currentInputBlock() == .menu else {
            evaluateStatus()
            return false
        }
        send(txt: PTYInput.cancelMenuKey)
        return true
    }

    /// 画面の下から `lines` 行を、小文字化して連結した文字列で返す。
    private static func tailText(_ screen: [String], lines: Int) -> String {
        screen.suffix(lines).joined(separator: "\n").lowercased()
    }

    /// 1 行の文字列。TUI は空白を書かずにカーソル移動で桁を飛ばすので、未記入のセル（NUL）を空白に戻す（全角の後半セルは除く）。
    private static func text(of line: BufferLine) -> String {
        line.translateToString(trimRight: true, skipNullCellsFollowingWide: true).replacingOccurrences(of: "\u{0}", with: " ")
    }

    /// 親プロセスの環境を引き継ぎつつ、課金経路となる API キーを除去した環境を作る。
    private static func buildSafeEnvironment() -> [String] {
        var dict = ProcessInfo.processInfo.environment
        dict.removeValue(forKey: "ANTHROPIC_API_KEY")
        dict.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        // Claude Code の中から起動された時の子セッション印（transcript 保存オフ・SDK 扱い等）を持ち込まないため。
        for key in dict.keys where key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_SDK")
            || ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "AI_AGENT"].contains(key) {
            dict.removeValue(forKey: key)
        }
        dict["TERM"] = "xterm-256color"
        dict["COLORTERM"] = "truecolor"
        return dict.map { "\($0.key)=\($0.value)" }
    }

    // MARK: - 出力傍受

    /// PTY からの受信バイトを傍受。描画は super に委ね、こちらは上限文言の検査だけ行う。
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        lastDataTime = Date()   // 活動量ベースの作業中判定に使う
        guard !limitHandled else { return }
        // UTF-8 として lossy デコード（途中で切れても落ちない）
        let chunk = String(decoding: slice, as: UTF8.self)
        scan(chunk)
    }

    /// 生の出力は TUI がカーソル移動で語を並べるので照合できない。描画後の実画面の末尾を間引いて見る。
    private func scan(_ chunk: String) {
        guard !limitCheckPending else { return }
        limitCheckPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.limitCheckPending = false
            if LimitGuard.screenLimitLine(self.limitScreenLines()) != nil { self.reachLimit() }
        }
    }

    /// 上限到達として 1 回だけ終了を流す（画面の表示からも、公式の残量からも呼ばれる）。
    func reachLimit() {
        guard !limitHandled, process?.running == true else { return }
        limitHandled = true
        let pid = process.shellPid
        // 起動直後に呼ばれても受け手が pid を取り終えてから止めるよう、次の周回に回す。
        DispatchQueue.main.async { [weak self] in self?.onLimitReached?() }
        // 対話 zsh は SIGTERM を無視するので、claude に exec する前に止めると生き残る。残っていれば強制終了する。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if Self.isLiveChild(pid) { kill(pid, SIGKILL) }
        }
    }

    /// 自分の子で、まだ終わっていない（ゾンビでない）プロセスか。pid の再利用で他人を殺さないため親を確かめる。
    private static func isLiveChild(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_ppid == UInt32(getpid()) && info.pbi_status != UInt32(SZOMB)
    }

    /// 実画面の全行。表示位置（yDisp）ではなくバッファ末尾の `rows` 行を読む。空白を書かずに飛ばしたセル（NUL）は空白に戻す。
    private func limitScreenLines() -> [String] {
        let term = getTerminal()
        let rows = term.rows
        guard rows > 0 else { return [] }
        let top = term.buffer.totalLinesTrimmed
        let count = LimitGuard.bufferLineCount(rows: rows) { term.getScrollInvariantLine(row: top + $0) != nil }
        return (max(0, count - rows)..<count).compactMap { row in
            term.getScrollInvariantLine(row: top + row).map {
                $0.translateToString(trimRight: true, skipNullCellsFollowingWide: true).replacingOccurrences(of: "\u{0}", with: " ")
            }
        }
    }
}
