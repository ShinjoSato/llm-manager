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
/// さらに、PTY 出力を監視し「上限到達」文言を検知したらセッションを強制終了する。
final class ClaudeTerminalView: LocalProcessTerminalView {

    /// 上限到達を検知したときに呼ばれる（メインスレッド）。
    var onLimitReached: (() -> Void)?

    /// 作業ステータスが変化したときに呼ばれる（メインスレッド）。
    var onStatusChanged: ((ClaudeStatus) -> Void)?

    /// 画面に出ている権限プロンプトが変わったときに呼ばれる（メインスレッド）。
    var onPermissionPromptChanged: ((PermissionPrompt?) -> Void)?

    /// 入力欄への送信を止める状態が変わったときに呼ばれる（メインスレッド）。
    var onInputBlockChanged: ((InputBlock?) -> Void)?

    private(set) var permissionPrompt: PermissionPrompt?
    private(set) var inputBlock: InputBlock?

    private var scanBuffer = ""
    private var limitHandled = false

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

    /// 応答待ち（入力待ち）を示す文言の候補（大文字小文字無視・部分一致）。
    /// 通常の回答本文との誤検知を避けるため、権限プロンプト固有の言い回しに絞る。
    /// ⚠️ 実際の Claude Code の権限確認/質問プロンプト文言に合わせて要・実機検証。
    private static let waitingPhrases: [String] = [
        "do you want to proceed",
        "yes, and don't ask again",
        "no, and tell claude",
        "❯ 1. yes"
    ]

    /// 上限到達を示す文言の候補（大文字小文字無視・部分一致）。
    /// ⚠️ 実際の Claude Code の上限メッセージ文言に合わせて要・実機検証。
    ///    暫定で代表的な言い回しを並べてある。実機で確認したら最小限に絞る。
    private static let limitPhrases: [String] = [
        "usage limit reached",
        "reached your usage limit",
        "you've reached your usage limit",
        "you have reached your usage limit",
        "5-hour limit reached",
        "weekly limit reached",
        "approaching your usage limit"   // 予兆。終了させず警告に使うなら別扱いにする
    ]

    /// 指定プロジェクトのディレクトリで `claude` を起動する。
    /// ログインシェル経由で PATH（~/.local/bin など）を継承しつつ、API キーは二重に遮断する。
    func launchClaude(in directory: String) {
        let env = Self.buildSafeEnvironment()
        startProcess(
            executable: "/bin/zsh",
            // -l ログインシェルで PATH を取得、-i 対話、-c コマンド。
            // 渡す環境からは既に API キーを抜いてあるが、念のためシェル側でも unset してから exec。
            args: ["-lic", "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; exec claude"],
            environment: env,
            execName: nil,
            currentDirectory: directory
        )
        startStatusMonitoring()
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
        var block = InputBlock.detect(screen: screen)
        let newStatus: ClaudeStatus
        if block != nil {
            newStatus = .waitingInput
        } else if quiet < Self.busyThreshold || Self.busyMarkers.contains(where: { tail.contains($0) }) {
            newStatus = .working
        } else if Self.waitingPhrases.contains(where: { tail.contains($0) }) {
            newStatus = .waitingInput
            block = .waiting
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

    /// 送信を止めるべき状態か。タイマーを待たず今の画面で判定し、入力待ちと判定済みなら安全側で止める。
    func currentInputBlock() -> InputBlock? {
        if let block = InputBlock.detect(screen: screenLines()) { return block }
        return currentStatus == .waitingInput ? .waiting : nil
    }

    // MARK: - 入力（本人のキー入力として PTY に書く）

    enum SendResult: Equatable {
        case sent
        case empty
        /// 権限プロンプト・選択メニュー・入力待ちの表示中。Enter がその選択になってしまうので送らない。
        case blocked(InputBlock)
    }

    /// チャット欄の本文を入力欄に貼り付けてから Enter で送る。作業中でも Claude Code 側でキューに積まれる。
    /// 貼り付けの前に必ず判定するので、止める時は入力欄に何も入れない。
    /// `onAborted` は貼り付けから Enter までの間に止めるべき状態になり、Enter を押さずにやめた時に呼ばれる（本文は入力欄に残る）。
    func sendMessage(_ text: String, onAborted: ((InputBlock) -> Void)? = nil) -> SendResult {
        if let block = currentInputBlock() { return .blocked(block) }
        guard let body = PTYInput.messageBody(text, bracketedPaste: getTerminal().bracketedPasteMode) else { return .empty }
        send(txt: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + PTYInput.submitDelay) { [weak self] in
            guard let self else { return }
            if let block = self.currentInputBlock() {
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

    private func scan(_ chunk: String) {
        scanBuffer += chunk
        let cleaned = Self.stripANSI(scanBuffer).lowercased()
        if Self.limitPhrases.contains(where: { cleaned.contains($0) }) {
            limitHandled = true
            DispatchQueue.main.async { [weak self] in self?.onLimitReached?() }
        }
        // バッファは末尾だけ保持（文言は分割受信されうるので少し広めに）
        if scanBuffer.count > 8192 {
            scanBuffer = String(scanBuffer.suffix(8192))
        }
    }

    /// CSI/ANSI エスケープシーケンスを大まかに除去する。
    static func stripANSI(_ s: String) -> String {
        let pattern = "\u{1B}\\[[0-9;?]*[ -/]*[@-~]"
        return s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}
