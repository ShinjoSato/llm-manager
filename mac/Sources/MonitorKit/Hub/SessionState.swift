import Foundation

/// 層が返すフィードの 1 行。番号・時刻・プロジェクト名は配信する SessionHub が付ける。
struct FeedLine: Equatable {
    var kind: FeedKind
    var text: String
    var tool: String? = nil
    /// アプリの中で起きたこと（ログやフックに由来しない）。
    var local = false
}

/// セッションごとの可変状態。SessionHub の actor の上でだけ触り、欄は書く層ごとに分けて他の層は読むだけ（例外は節の中に書く）。
final class SessionState {
    /// ログの終わり方。busy はモデルの番（ツール実行中・長考中）で、無音でも動いている。
    enum TurnState { case busy, settled }

    // MARK: 在庫層（InventoryScanner）が書く

    var raw: RawSession
    var socketPath: String?
    var endedAt: Double?
    /// 最初の在庫走査で見つけた（起動前から動いていた）セッションか。時刻の無いログ行の新旧の見分けに使う。
    var knownAtStart = false
    /// cwd は変わらないのでセッション生成時に一度だけ調べる（結果は SessionHub の loadMeta が入れる）。
    var xcodeProject: String?

    // MARK: 実況層（TranscriptPoller）が書く

    var reader: TranscriptReader?
    var transcriptPath: String?
    /// メタ情報（ai-title 等）の遡り読みを、この位置のログについて始めたか。
    var metaRequestedFor: String?
    var branch: String?
    var title: String?
    var lastPrompt: String?
    /// フック層も working のフックで進める。
    var lastActivityAt: Double?
    /// フック層も PreToolUse で書く。
    var currentTool: String?
    var currentSkill: String?
    /// フック層も PreToolUse で消す。
    var currentAction: String?
    var tokens: TokenUsage?
    var turnState: TurnState?
    var agents: [AgentInfo] = []
    var agentsCheckedAt: Double = 0
    /// サブエージェントのログが最後に動いた時刻。親が Agent 実行中は親ログが無音になるため。
    var lastAgentActivityAt: Double?

    // MARK: フック層（HookIntake）が書く。実況層はフックより新しいツール行で `clearHookWait` を呼ぶだけ

    var hookStatus: SessionStatus?
    var hookDetail: String?
    var hookAt: Double = 0
    /// 権限待ちで届いた素の値。ログの読み取りが追い付いてから説明を添えるため、組み立ては配信時に行う。
    var hookTool: String?
    var hookMessage: String?
    /// 要対応になった時刻。要対応どうしの移り変わりでは引き継ぐ。
    var attentionSince: Double?

    init(raw: RawSession) {
        self.raw = raw
    }

    /// 親ログとサブエージェントのうち新しい方。無ければ 0。稼働中の表示用で、待ちの「答え済み」判定には使わない。
    var lastActivity: Double { max(lastActivityAt ?? 0, lastAgentActivityAt ?? 0) }

    /// フックの「待ち」を解く（フックの時刻は残し、古い行で待ちを消さない判定に使い続ける）。
    func clearHookWait() {
        hookStatus = nil
        hookDetail = nil
        hookTool = nil
        hookMessage = nil
        attentionSince = nil
    }
}

/// 一覧・フィードに出す文字列の下請け。
enum HubText {
    static func basename(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return trimmed.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? String(trimmed)
    }

    /// 空白をつめて 1 行にし、長ければ切る。
    static func truncate(_ text: String, _ max: Int) -> String {
        clip(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "), max)
    }

    /// UTF-16 単位で `max` を超えたら切って「…」を付ける。
    static func clip(_ text: String, _ max: Int) -> String {
        guard text.utf16.count > max else { return text }
        return String(decoding: Array(text.utf16.prefix(max)), as: UTF16.self) + "…"
    }
}
