import AppKit
import SwiftTerm
import MonitorKit

/// Claude Code の作業状態（ルームのバッジ・並び順に使う）。
enum ClaudeStatus: Equatable {
    case working        // 出力が流れている（生成中）
    case waitingInput   // 権限確認・選択メニュー・質問プロンプトを検出（要応答）
    case idle           // 出力停止 かつ プロンプト無し（待機/完了）
}

/// Claude Code を PTY でホストする端末ビュー。料金事故をゼロにするため、子の環境から API キーを必ず除き、headless の起動口は設けない。
/// 上限到達（公式の残量 100% か、画面末尾の上限表示）を検知したらセッションを強制終了する。
final class ClaudeTerminalView: LocalProcessTerminalView {

    /// 上限到達を検知したときに呼ばれる（メインスレッド）。
    var onLimitReached: (() -> Void)?

    /// 画面から読んだ状態。
    struct ScreenState: Equatable {
        var status: ClaudeStatus = .idle
        var permissionPrompt: PermissionPrompt?
        /// 入力欄への送信を止める状態（権限プロンプト・選択メニュー）。
        var inputBlock: InputBlock?
        /// 選択メニューの中身（読み取れなければ nil。inputBlock が .menu でも nil はありうる）。
        var menuPrompt: MenuPrompt?
        /// 選択メニューは出ているが中身を読めない時の写し。
        var unreadableMenu: UnreadableMenu?
    }

    /// `screenState` が変わったときに呼ばれる（メインスレッド）。
    var onScreenStateChanged: ((ScreenState) -> Void)?

    var screenState = ScreenState()
    /// 選択肢へ ❯ を動かしている最中。重ねて動かすと互いのキーで行き先がずれる。
    var isNavigatingMenu = false
    /// 未反映の矢印を残して移動をやめた印。外れるまで次の移動を始めない。
    var pendingArrowHold: PendingArrowHold?
    /// 最後に画面の写しを残したメニュー（同じものを何度も書かない）。
    var lastLoggedMenu: Int?

    var limitHandled = false
    var limitCheckPending = false

    // MARK: - ステータス検知（ハイブリッド: 活動量 + プロンプト文言）
    var statusTimer: Timer?
    var lastDataTime = Date()

    /// 起動した claude の pid。`exec claude` で zsh を置き換えるので PTY の子 pid がそのまま claude になる。
    var claudePid: pid_t? {
        guard let pid = process?.shellPid, pid > 0 else { return nil }
        return pid
    }

    deinit { statusTimer?.invalidate() }

    /// セッションファイルの返事待ちの状態と読んだ時刻（画面の判定のたびにファイルを読まないため）。
    var sessionWaitingCache: (at: Date, value: SessionWaiting?)?

    /// 送信を途中で取りやめ、端末の入力欄に本文や画像を残したかもしれない時の、次の送信の扱い。
    var leftoverCheck: LeftoverCheck = .none

    /// 送信の途中（画像の取り込み待ち〜Enter）。終わるまで次の送信を受けない。
    var isSending = false {
        didSet { if isSending != oldValue { onSendingChanged?(isSending) } }
    }
    var onSendingChanged: ((Bool) -> Void)?

    // MARK: - 出力傍受

    /// PTY からの受信バイトを傍受。描画は super に委ね、こちらは上限文言の検査だけ行う。
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        lastDataTime = Date()   // 活動量ベースの作業中判定に使う
        guard !limitHandled else { return }
        scan()
    }
}
