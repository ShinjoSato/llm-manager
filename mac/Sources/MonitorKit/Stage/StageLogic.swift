import Foundation

/// サブエージェント種別に対応する職業（monitor UI の `pixel/kit.ts` の JOBS と同じ呼び名）。
public struct StageJob: Sendable, Equatable {
    public var label: String
    public var role: String
    /// 頭・上半身の明色（0xRRGGBB）。
    public var light: UInt32
    /// 胴・脚の濃色。
    public var dark: UInt32
}

/// 随伴するサブエージェントの今の様子。
public enum StageAgentActivity: Sendable, Equatable {
    case active
    case quiet(seconds: Int)
}

/// ステージ部分に何を出すか。
public enum StageContent: Sendable, Equatable {
    case stage(sessionId: String)
    case placeholder(String)
}

/// ステージパネルの文言・開閉の判定（UI 非依存。monitor UI の言い回しにそろえる）。
public enum StageLogic {
    // MARK: - いまの動き

    /// `developer-plugin:dev-done` → `dev-done`。
    public static func skillLabel(_ skill: String) -> String {
        guard let i = skill.firstIndex(of: ":") else { return skill }
        return String(skill[skill.index(after: i)...])
    }

    private static let verbs: [String: String] = [
        "Bash": "端末を叩いている",
        "Read": "本を読んでいる",
        "Grep": "書物を探っている",
        "Glob": "書物を探っている",
        "Edit": "槌を振るっている",
        "Write": "槌を振るっている",
        "NotebookEdit": "槌を振るっている",
        "Skill": "巻物を広げている",
        "WebFetch": "遠くを覗いている",
        "WebSearch": "遠くを覗いている",
        "ToolSearch": "道具を探している",
        "AskUserQuestion": "問いかけている",
        "Artifact": "画布に描いている",
        "TodoWrite": "帳面をつけている",
        "SendUserFile": "書簡を届けている",
        "SendMessage": "文を送っている",
    ]

    /// ツールの動作の一言。Agent / Task は子が出るので持ち物にしない（kit.ts の itemForVerb と同じ）。
    public static func toolVerb(_ tool: String?) -> String? {
        guard let tool, !tool.isEmpty, tool != "Agent", tool != "Task" else { return nil }
        return verbs[tool] ?? "手を動かしている"
    }

    /// いま何をしているかの一行。スキルの銘 > 具体的な説明 > ツールの動作 の順（SessionCard の actionLine と同じ）。
    public static func actionLine(_ s: SessionSnapshot) -> String? {
        guard s.status == .working else { return nil }
        if let skill = s.currentSkill, !skill.isEmpty { return "巻物『\(skillLabel(skill))』を広げている" }
        if let action = s.currentAction, !action.isEmpty { return action }
        return toolVerb(s.currentTool)
    }

    // MARK: - サブエージェント

    private static let jobs: [String: StageJob] = [
        "developer-plugin:code-reviewer": StageJob(label: "監査役", role: "差分を静的にレビューする", light: 0xfbbf24, dark: 0xb45309),
        "developer-plugin:swiftui-implementer": StageJob(label: "iOS職人", role: "iOS（SwiftUI）を実装する", light: 0x60a5fa, dark: 0x1d4ed8),
        "developer-plugin:go-api-implementer": StageJob(label: "サーバ職人", role: "Go の API と DB 層を実装する", light: 0x22d3ee, dark: 0x0e7490),
        "developer-plugin:ios-sim-tester": StageJob(label: "試験官", role: "シミュレータで操作して確かめる", light: 0x4ade80, dark: 0x15803d),
        "developer-plugin:ios-context-scout": StageJob(label: "斥候", role: "既存構成を調べて地図を返す", light: 0xc084fc, dark: 0x7e22ce),
        "developer-plugin:pr-verifier": StageJob(label: "検証官", role: "PR を実際に動かして検証する", light: 0xf472b6, dark: 0xbe185d),
        "developer-plugin:agent-scout": StageJob(label: "斥候", role: "agents / skills 構成を診断する", light: 0xc084fc, dark: 0x7e22ce),
        "developer-plugin:prompt-analyst": StageJob(label: "記録係", role: "プロンプト履歴を分析する", light: 0xa3e635, dark: 0x4d7c0f),
        "appstore-plugin:appstore-review": StageJob(label: "審査官", role: "App Store 審査観点で点検する", light: 0xfb923c, dark: 0xc2410c),
        "appstore-plugin:appstore-meta-inspector": StageJob(label: "調査役", role: "App Store Connect の登録内容を読む", light: 0xfb923c, dark: 0xc2410c),
        "fable-mode-plugin:fable-verifier": StageJob(label: "検証官", role: "実装への反証を試みる", light: 0xf472b6, dark: 0xbe185d),
        "fable-mode-plugin:fable-judge": StageJob(label: "審判", role: "複数案を採点して順位づける", light: 0xfacc15, dark: 0xa16207),
        "fable-mode-plugin:fable-ui-reviewer": StageJob(label: "意匠番", role: "UI の見た目を審査する", light: 0xe879f9, dark: 0xa21caf),
        "Explore": StageJob(label: "斥候", role: "広く探索して場所を特定する", light: 0xc084fc, dark: 0x7e22ce),
        "Plan": StageJob(label: "軍師", role: "実装の計画を立てる", light: 0x818cf8, dark: 0x4338ca),
        "general-purpose": StageJob(label: "何でも屋", role: "汎用の調査・作業", light: 0x94a3b8, dark: 0x475569),
    ]

    public static let unknownJob = StageJob(label: "従者", role: "種別が判別できないサブエージェント", light: 0x94a3b8, dark: 0x475569)

    public static func job(for type: String?) -> StageJob {
        guard let type else { return unknownJob }
        return jobs[type] ?? unknownJob
    }

    /// 「監査役 ほか2名が随伴」。代表者は id 順で選び、更新順の入れ替わりで文言がちらつかないようにする。
    public static func escortLine(_ agents: [AgentInfo]) -> String? {
        guard let head = agents.min(by: { $0.id < $1.id }) else { return nil }
        let first = job(for: head.type).label
        return agents.count > 1 ? "\(first) ほか\(agents.count - 1)名が随伴" : "\(first)が随伴"
    }

    /// ログの更新がこれ以内なら作業中とみなす（monitor は 3 分更新が無いと一覧から外す）。
    public static let agentActiveWindow: TimeInterval = 15

    public static func activity(of agent: AgentInfo, now: Date) -> StageAgentActivity {
        let seconds = max(0, now.timeIntervalSince(Date(epochMillis: agent.lastActivityAt)))
        return seconds < agentActiveWindow ? .active : .quiet(seconds: Int(seconds))
    }

    /// 一覧の並び。更新順だと 2 秒ごとに入れ替わるので id 順で固定する。
    public static func sortedAgents(_ agents: [AgentInfo]) -> [AgentInfo] {
        agents.sorted { $0.id < $1.id }
    }

    // MARK: - 時間

    /// monitor UI の `ago` と同じ書き方（「12秒前」）。
    public static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "—" }
        let s = Int(max(0, now.timeIntervalSince(date)))
        if s < 60 { return "\(s)秒前" }
        if s < 3600 { return "\(s / 60)分前" }
        if s < 86_400 { return "\(s / 3600)時間前" }
        return "\(s / 86_400)日前"
    }

    /// monitor UI の `dur` と同じ書き方（「1時間5分」）。
    public static func duration(since date: Date, now: Date) -> String {
        let s = Int(max(0, now.timeIntervalSince(date)))
        let h = s / 3600
        let m = (s % 3600) / 60
        return h > 0 ? "\(h)時間\(m)分" : "\(m)分"
    }

    // MARK: - ライブフィード

    /// そのセッションの直近 `limit` 件を新しい順に返す。
    public static func feed(_ feed: [FeedItem], sessionId: String?, limit: Int = 60) -> [FeedItem] {
        guard let sessionId else { return [] }
        var result: [FeedItem] = []
        for item in feed.reversed() where item.sessionId == sessionId {
            result.append(item)
            if result.count >= limit { break }
        }
        return result
    }

    public static func kindLabel(_ kind: FeedKind) -> String {
        switch kind {
        case .tool: return "ツール"
        case .prompt: return "指示"
        case .message: return "応答"
        case .status: return "状態"
        case .session: return "セッション"
        case .agent: return "随伴"
        case .unknown: return "その他"
        }
    }

    // MARK: - プレースホルダー

    /// 監視・選択の状態から、ステージかプレースホルダーかを決める。
    public static func content(connected: Bool,
                               hasRoom: Bool,
                               sessionId: String?,
                               sessionKnown: Bool) -> StageContent {
        guard connected else { return .placeholder("セッションの監視を始めています…") }
        guard hasRoom else { return .placeholder("ルームを選ぶとステージを表示します") }
        guard let sessionId else { return .placeholder("セッションを確認しています…") }
        guard sessionKnown else { return .placeholder("このセッションをまだ見つけていません") }
        return .stage(sessionId: sessionId)
    }

    // MARK: - 開閉

    /// パネルを置いても会話が最小幅を保てるウィンドウ幅（ルーム一覧 312 + 境界 + 会話 420 + 境界 + パネル 360）。
    public static let autoCollapseWidth: CGFloat = 1100

    /// 狭いウィンドウでは畳む。ただし狭いまま利用者が開いた時（`openedWhileNarrow`）はそれに従う。
    public static func isExpanded(preference: Bool, windowWidth: CGFloat?, openedWhileNarrow: Bool) -> Bool {
        guard preference else { return false }
        guard let windowWidth, windowWidth < autoCollapseWidth else { return true }
        return openedWhileNarrow
    }
}
