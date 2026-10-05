import Foundation

// 監視のドメイン型。
// 時刻は epoch ミリ秒のまま持ち、Date が要る所では *Date の計算プロパティを使う。

/// 未知の値が来てもデコード全体を落とさないための文字列 enum の共通処理。
public protocol LenientStringEnum: RawRepresentable, Codable, Sendable, Hashable where RawValue == String {
    static var unknownCase: Self { get }
}

extension LenientStringEnum {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.unknownCase
    }
}

/// セッションの状態。
public enum SessionStatus: String, LenientStringEnum {
    case working, waiting, permission, idle, error, stopped
    case unknown
    public static var unknownCase: SessionStatus { .unknown }
}

/// 状態の出どころ。
public enum StatusSource: String, LenientStringEnum {
    case hook, transcript, inventory
    case unknown
    public static var unknownCase: StatusSource { .unknown }
}

public struct TokenUsage: Codable, Sendable, Hashable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int

    public init(input: Int, output: Int, cacheRead: Int) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
    }
}

/// 親に随伴しているサブエージェント 1 体。
public struct AgentInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var type: String?
    public var lastActivityAt: Double

    public init(id: String, type: String?, lastActivityAt: Double) {
        self.id = id
        self.type = type
        self.lastActivityAt = lastActivityAt
    }
}

/// 1 セッション分のスナップショット。
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
    /// 権限待ちの時、フックの tool_name に入っていたツール名（未検証の値）。
    public var permissionTool: String? = nil
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

    public init(sessionId: String, pid: Int32, alive: Bool, name: String, project: String, cwd: String, branch: String?,
                title: String?, lastPrompt: String?, status: SessionStatus, statusSource: StatusSource, statusDetail: String?,
                attentionSince: Double? = nil, permissionTool: String? = nil, entrypoint: String?, version: String?, startedAt: Double, lastActivityAt: Double?,
                currentTool: String?, currentSkill: String?, currentAction: String?, tokens: TokenUsage?, agents: [AgentInfo],
                canReceive: Bool, xcodeProject: String?) {
        self.sessionId = sessionId
        self.pid = pid
        self.alive = alive
        self.name = name
        self.project = project
        self.cwd = cwd
        self.branch = branch
        self.title = title
        self.lastPrompt = lastPrompt
        self.status = status
        self.statusSource = statusSource
        self.statusDetail = statusDetail
        self.attentionSince = attentionSince
        self.permissionTool = permissionTool
        self.entrypoint = entrypoint
        self.version = version
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.currentTool = currentTool
        self.currentSkill = currentSkill
        self.currentAction = currentAction
        self.tokens = tokens
        self.agents = agents
        self.canReceive = canReceive
        self.xcodeProject = xcodeProject
    }

    public var id: String { sessionId }
    public var startedDate: Date { Date(epochMillis: startedAt) }
    public var lastActivityDate: Date? { lastActivityAt.map(Date.init(epochMillis:)) }
}

/// 上限ウィンドウ 1 つ分の使用量。
public struct UsageWindow: Codable, Sendable, Hashable {
    public var usedPercentage: Double
    public var resetsAt: Double?

    public init(usedPercentage: Double, resetsAt: Double?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    /// 残り%（100 − 使用率を 0...100 に収める）。
    public var remainingPercentage: Double { min(100, max(0, 100 - usedPercentage)) }
    public var resetsDate: Date? { resetsAt.map(Date.init(epochMillis:)) }
}

/// statusLine が最後に書き残した使用量。
public struct UsageSnapshot: Codable, Sendable, Hashable {
    public var fetchedAt: Double
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?

    public init(fetchedAt: Double, fiveHour: UsageWindow?, sevenDay: UsageWindow?) {
        self.fetchedAt = fetchedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    public var fetchedDate: Date { Date(epochMillis: fetchedAt) }
}

public enum FeedKind: String, LenientStringEnum {
    case tool, prompt, message, status, session, agent
    case unknown
    public static var unknownCase: FeedKind { .unknown }
}

/// ライブフィードの 1 行。
public struct FeedItem: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var sessionId: String
    public var project: String
    public var at: Double
    public var kind: FeedKind
    public var text: String
    public var tool: String?
    public var local: Bool?

    public init(id: Int, sessionId: String, project: String, at: Double, kind: FeedKind, text: String, tool: String?, local: Bool?) {
        self.id = id
        self.sessionId = sessionId
        self.project = project
        self.at = at
        self.kind = kind
        self.text = text
        self.tool = tool
        self.local = local
    }

    public var date: Date { Date(epochMillis: at) }
}

/// 保留中の権限確認 1 件。
public struct PendingPermission: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var requestId: String
    public var sessionId: String?
    public var project: String?
    public var toolName: String
    public var description: String
    public var inputPreview: String
    public var askedAt: Double

    public init(key: String, requestId: String, sessionId: String?, project: String?, toolName: String, description: String,
                inputPreview: String, askedAt: Double) {
        self.key = key
        self.requestId = requestId
        self.sessionId = sessionId
        self.project = project
        self.toolName = toolName
        self.description = description
        self.inputPreview = inputPreview
        self.askedAt = askedAt
    }

    public var id: String { key }
}

public enum TranscriptItemKind: String, LenientStringEnum {
    case user, assistant, tool
    case unknown
    public static var unknownCase: TranscriptItemKind { .unknown }
}

public struct TranscriptTool: Codable, Sendable, Hashable {
    public var name: String
    public var description: String?
    public var target: String?

    public init(name: String, description: String?, target: String?) {
        self.name = name
        self.description = description
        self.target = target
    }
}

/// 発話に添えられた画像 1 枚の目録。本体は mac では `MonitorStore.imageSource`、iPhone では `RemoteClient.image` で取る。
public struct TranscriptImage: Codable, Sendable, Hashable {
    /// 発話の中で何枚目の画像か（取り出しに使う位置）。
    public var index: Int
    public var mediaType: String

    public init(index: Int, mediaType: String) {
        self.index = index
        self.mediaType = mediaType
    }
}

/// 会話履歴の 1 要素。
public struct TranscriptItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: TranscriptItemKind
    public var at: Double?
    public var text: String?
    public var tool: TranscriptTool?
    public var parentId: String?
    public var images: [TranscriptImage] = []

    public init(id: String, kind: TranscriptItemKind, at: Double?, text: String?, tool: TranscriptTool?, parentId: String?,
                images: [TranscriptImage] = []) {
        self.id = id
        self.kind = kind
        self.at = at
        self.text = text
        self.tool = tool
        self.parentId = parentId
        self.images = images
    }
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

    public init(sessionId: String, items: [TranscriptItem], reset: Bool) {
        self.sessionId = sessionId
        self.items = items
        self.reset = reset
    }
}

/// 会話の追記分。
public struct TranscriptEvent: Codable, Sendable, Hashable {
    public var sessionId: String
    public var items: [TranscriptItem]

    public init(sessionId: String, items: [TranscriptItem]) {
        self.sessionId = sessionId
        self.items = items
    }
}

/// 権限確認への返答。Channels は allow / deny しか返せない。
public enum PermissionDecision: String, Codable, Sendable {
    case allow, deny
}

extension Date {
    public init(epochMillis: Double) {
        self.init(timeIntervalSince1970: epochMillis / 1000)
    }
}
