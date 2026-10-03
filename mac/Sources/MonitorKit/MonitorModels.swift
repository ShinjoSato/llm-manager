import Foundation

// 監視のドメイン型（移植元: monitor/src/types.ts）。
// 時刻は epoch ミリ秒のまま持ち、Date が要る所では *Date の計算プロパティを使う。

/// 未知の値が来てもデコード全体を落とさないための文字列 enum の共通処理。
public protocol MonitorLenientEnum: RawRepresentable, Codable, Sendable, Hashable where RawValue == String {
    static var unknownCase: Self { get }
}

extension MonitorLenientEnum {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.unknownCase
    }
}

/// セッションの状態（types.ts の SessionStatus）。
public enum SessionStatus: String, MonitorLenientEnum {
    case working, waiting, permission, idle, error, stopped
    case unknown
    public static var unknownCase: SessionStatus { .unknown }
}

/// 状態の出どころ（types.ts の StatusSource）。
public enum StatusSource: String, MonitorLenientEnum {
    case hook, transcript, inventory
    case unknown
    public static var unknownCase: StatusSource { .unknown }
}

public struct TokenUsage: Codable, Sendable, Hashable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
}

/// 親に随伴しているサブエージェント 1 体。
public struct AgentInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var type: String?
    public var lastActivityAt: Double
}

/// 1 セッション分のスナップショット（types.ts の SessionSnapshot）。
public struct SessionSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var sessionId: String
    public var pid: Int32
    public var alive: Bool
    public var name: String
    public var project: String
    public var cwd: String
    public var branch: String?
    public var title: String?
    public var lastPrompt: String?
    public var status: SessionStatus
    public var statusSource: StatusSource
    public var statusDetail: String?
    /// 要対応（権限待ち・入力待ち・エラー）になった時刻（epoch ミリ秒）。それ以外の状態では nil。
    public var attentionSince: Double? = nil
    public var entrypoint: String?
    public var version: String?
    public var startedAt: Double
    public var lastActivityAt: Double?
    public var currentTool: String?
    public var currentSkill: String?
    public var currentAction: String?
    public var tokens: TokenUsage?
    public var agents: [AgentInfo]
    public var canReceive: Bool
    public var xcodeProject: String?

    public var id: String { sessionId }
    public var startedDate: Date { Date(epochMillis: startedAt) }
    public var lastActivityDate: Date? { lastActivityAt.map(Date.init(epochMillis:)) }
}

/// 上限ウィンドウ 1 つ分の使用量。
public struct UsageWindow: Codable, Sendable, Hashable {
    public var usedPercentage: Double
    public var resetsAt: Double?

    /// 残り%（monitor の UI と同じく 100 − 使用率を 0...100 に収める）。
    public var remainingPercentage: Double { min(100, max(0, 100 - usedPercentage)) }
    public var resetsDate: Date? { resetsAt.map(Date.init(epochMillis:)) }
}

/// statusLine が最後に書き残した使用量（types.ts の UsageSnapshot）。
public struct UsageSnapshot: Codable, Sendable, Hashable {
    public var fetchedAt: Double
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?

    public var fetchedDate: Date { Date(epochMillis: fetchedAt) }
}

public enum FeedKind: String, MonitorLenientEnum {
    case tool, prompt, message, status, session, agent
    case unknown
    public static var unknownCase: FeedKind { .unknown }
}

/// ライブフィードの 1 行（types.ts の FeedItem）。
public struct FeedItem: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var sessionId: String
    public var project: String
    public var at: Double
    public var kind: FeedKind
    public var text: String
    public var tool: String?
    public var local: Bool?

    public var date: Date { Date(epochMillis: at) }
}

/// 保留中の権限確認 1 件（types.ts の PendingPermission）。
public struct PendingPermission: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var requestId: String
    public var sessionId: String?
    public var project: String?
    public var toolName: String
    public var description: String
    public var inputPreview: String
    public var askedAt: Double

    public var id: String { key }
    public var askedDate: Date { Date(epochMillis: askedAt) }
}

public enum TranscriptItemKind: String, MonitorLenientEnum {
    case user, assistant, tool
    case unknown
    public static var unknownCase: TranscriptItemKind { .unknown }
}

public struct TranscriptTool: Codable, Sendable, Hashable {
    public var name: String
    public var description: String?
    public var target: String?
}

/// 発話に添えられた画像 1 枚の目録（types.ts の TranscriptImage）。本体は `MonitorStore.transcriptImage` で取る。
public struct TranscriptImage: Codable, Sendable, Hashable {
    /// 発話の中で何枚目の画像か（取り出しに使う位置）。
    public var index: Int
    public var mediaType: String

    public init(index: Int, mediaType: String) {
        self.index = index
        self.mediaType = mediaType
    }
}

/// 会話履歴の 1 要素（types.ts の TranscriptItem）。
public struct TranscriptItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: TranscriptItemKind
    public var at: Double?
    public var text: String?
    public var tool: TranscriptTool?
    public var parentId: String?
    public var images: [TranscriptImage] = []
}

extension TranscriptItem {
    private enum CodingKeys: String, CodingKey { case id, kind, at, text, tool, parentId, images }

    /// `images` は無ければ空にする。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(TranscriptItemKind.self, forKey: .kind)
        at = try c.decodeIfPresent(Double.self, forKey: .at)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        tool = try c.decodeIfPresent(TranscriptTool.self, forKey: .tool)
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        images = try c.decodeIfPresent([TranscriptImage].self, forKey: .images) ?? []
    }
}

/// 会話履歴の取得結果。`reset` は `after` の id が見つからず全件を返した時 true。
public struct TranscriptResponse: Codable, Sendable, Hashable {
    public var sessionId: String
    public var items: [TranscriptItem]
    public var reset: Bool
}

/// 会話の追記分。
public struct TranscriptEvent: Codable, Sendable, Hashable {
    public var sessionId: String
    public var items: [TranscriptItem]
}

/// 権限確認への返答。Channels は allow / deny しか返せない。
public enum PermissionDecision: String, Codable, Sendable {
    case allow, deny
}

/// 作業場所を開くアプリ。
public enum OpenApp: String, Codable, Sendable {
    case vscode, xcode
}

/// ワークスペースを閉じるアプリ。
public enum CloseApp: String, Codable, Sendable {
    case xcode
}

/// close の結果（未保存の変更があると Xcode が確認を出すので、閉じたとは断定しない）。
public enum CloseState: String, MonitorLenientEnum {
    case closed
    case notOpen = "not_open"
    case notRunning = "not_running"
    case unknown
    public static var unknownCase: CloseState { .unknown }
}

extension Date {
    public init(epochMillis: Double) {
        self.init(timeIntervalSince1970: epochMillis / 1000)
    }
}
