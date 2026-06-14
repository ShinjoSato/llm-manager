import AppKit
import SwiftTerm

/// Claude Code の作業状態（ペイン見出しのバッジ表示に使う）。
enum ClaudeStatus: Equatable {
    case working        // 出力が流れている（生成中）
    case waitingInput   // 出力停止 かつ 権限確認/質問プロンプトを検出（要応答）
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

    private var scanBuffer = ""
    private var limitHandled = false

    // MARK: - ステータス検知（ハイブリッド: 活動量 + プロンプト文言）
    private var statusTimer: Timer?
    private var lastDataTime = Date()
    private var currentStatus: ClaudeStatus = .idle
    /// 直近の画面末尾に応答待ちプロンプトが見えているか（データ受信側で更新し、タイマー側は参照のみ）。
    private var waitingPromptVisible = false

    /// 「最後の出力からこの秒数以内」なら出力が流れている＝作業中とみなす。
    /// 生成中はスピナーが常時再描画され出力が途切れないため、活動量で安定検知できる。
    private static let busyThreshold: TimeInterval = 0.6

    /// 応答待ち（入力待ち）を示す文言の候補（大文字小文字無視・部分一致）。
    /// ⚠️ 実際の Claude Code の権限確認/質問プロンプト文言に合わせて要・実機検証。
    private static let waitingPhrases: [String] = [
        "do you want",
        "❯ 1.",
        "1. yes",
        "press enter to continue",
        "(y/n)"
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

    /// 活動量とプロンプト文言から現在のステータスを判定し、変化時のみ通知する。
    private func evaluateStatus() {
        // scanBuffer（String）はデータ受信スレッドが書き換えるため、ここでは触らない。
        // 参照するのはプリミティブ値（lastDataTime / waitingPromptVisible）のみ。
        let quiet = Date().timeIntervalSince(lastDataTime)
        let newStatus: ClaudeStatus
        if quiet < Self.busyThreshold {
            newStatus = .working
        } else {
            newStatus = waitingPromptVisible ? .waitingInput : .idle
        }
        guard newStatus != currentStatus else { return }
        currentStatus = newStatus
        onStatusChanged?(newStatus)   // Timer は main runloop なのでメインスレッド
    }

    /// 親プロセスの環境を引き継ぎつつ、課金経路となる API キーを除去した環境を作る。
    private static func buildSafeEnvironment() -> [String] {
        var dict = ProcessInfo.processInfo.environment
        dict.removeValue(forKey: "ANTHROPIC_API_KEY")
        dict.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
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
        for phrase in Self.limitPhrases where cleaned.contains(phrase) {
            limitHandled = true
            DispatchQueue.main.async { [weak self] in self?.onLimitReached?() }
            break
        }
        // 応答待ちプロンプトの有無を、直近の画面（末尾）から判定して記録する。
        let tail = String(cleaned.suffix(1500))
        waitingPromptVisible = Self.waitingPhrases.contains(where: { tail.contains($0) })
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
