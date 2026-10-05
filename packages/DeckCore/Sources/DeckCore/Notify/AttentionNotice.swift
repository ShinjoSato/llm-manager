import Foundation

// 要対応を iCloud（CloudKit のプライベート DB）経由で iPhone に知らせるための共有の形。
// iCloud に載せるのはルーム名・何を待っているかの定型文・時刻・識別子だけで、会話の本文やツールの入力は持たない。

/// 何を待っているか。
public enum AttentionKind: String, Codable, Sendable, CaseIterable {
    case permission, waiting, error

    public init?(status: SessionStatus) {
        switch status {
        case .permission: self = .permission
        case .waiting: self = .waiting
        case .error: self = .error
        default: return nil
        }
    }
}

/// mac が毎回渡す、要対応のルーム 1 つ。
public struct AttentionCandidate: Sendable, Equatable {
    public var roomId: String
    public var sessionId: String?
    public var roomName: String
    public var kind: AttentionKind
    /// 権限待ちのツール名。形を確かめてから使うので、ここには未検証の値を入れてよい。
    public var toolName: String?

    public init(roomId: String, sessionId: String?, roomName: String, kind: AttentionKind, toolName: String? = nil) {
        self.roomId = roomId
        self.sessionId = sessionId
        self.roomName = roomName
        self.kind = kind
        self.toolName = toolName
    }
}

/// iCloud に置く知らせ 1 件（1 回の通知）。後から来た要対応をまとめて 1 件にすることがある。
public struct AttentionNotice: Sendable, Equatable, Codable {
    public var recordName: String
    /// 通知を開いた時に出すルーム（まとめた中で一番新しいもの）。
    public var roomId: String
    public var sessionId: String?
    public var roomName: String
    public var kind: AttentionKind
    public var summary: String
    public var title: String
    public var body: String
    /// 待ち始めた時刻（epoch ミリ秒）。
    public var since: Double
    /// この知らせがまとめているルーム。
    public var roomIds: [String]
    public var macName: String

    public init(recordName: String, roomId: String, sessionId: String?, roomName: String, kind: AttentionKind, summary: String,
                title: String, body: String, since: Double, roomIds: [String], macName: String) {
        self.recordName = recordName
        self.roomId = roomId
        self.sessionId = sessionId
        self.roomName = roomName
        self.kind = kind
        self.summary = summary
        self.title = title
        self.body = body
        self.since = since
        self.roomIds = roomIds
        self.macName = macName
    }
}

/// CloudKit のレコードの形。mac（書き手）と iPhone（購読側）で同じ名前を使う。
public enum AttentionNoticeSchema {
    /// Info.plist でコンテナを渡すキー（値はビルド設定 `DECK_ICLOUD_CONTAINER` から入る）。
    public static let containerInfoKey = "DeckICloudContainer"
    public static let recordType = "AttentionNotice"
    public static let subscriptionID = "attention-notice-created"
    /// 形を変えた時に古い読み手が取り違えないための版。
    public static let version: Int64 = 1
    /// 通知の見出し・本文はレコードの値をそのまま出す（Localizable の "%@"）。
    public static let titleLocalizationKey = "ATTENTION_TITLE"
    public static let bodyLocalizationKey = "ATTENTION_BODY"
    public static let notificationCategory = "ATTENTION"

    /// Info.plist の値からコンテナを決める。空・未展開の変数は「設定されていない」として nil。
    public static func containerIdentifier(infoValue: Any?) -> String? {
        guard let raw = (infoValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              !raw.contains("$(") else { return nil }
        return raw
    }

    public enum Field {
        public static let roomId = "roomId"
        public static let sessionId = "sessionId"
        public static let roomName = "roomName"
        public static let kind = "kind"
        public static let summary = "summary"
        public static let title = "title"
        public static let body = "body"
        public static let since = "since"
        public static let roomIds = "roomIds"
        public static let macName = "macName"
        public static let version = "version"
    }

    /// 書くフィールドの全て（これ以外は載せない）。
    public static let allFields: Set<String> = [
        Field.roomId, Field.sessionId, Field.roomName, Field.kind, Field.summary, Field.title, Field.body,
        Field.since, Field.roomIds, Field.macName, Field.version
    ]

    /// 通知に載せて iPhone に届けるフィールド（開くルームを決めるのに要るものだけ）。
    public static let desiredKeys = [Field.roomId, Field.sessionId, Field.macName]

    /// 同じルームの通知は後から来たもので置き換える。
    public static let collapseIDKey = Field.roomId

    /// CloudKit の型に依存しない値。
    public enum Value: Equatable, Sendable {
        case string(String)
        case int(Int64)
        case strings([String])
    }

    public static func fields(of notice: AttentionNotice) -> [String: Value] {
        var out: [String: Value] = [
            Field.roomId: .string(notice.roomId),
            Field.roomName: .string(notice.roomName),
            Field.kind: .string(notice.kind.rawValue),
            Field.summary: .string(notice.summary),
            Field.title: .string(notice.title),
            Field.body: .string(notice.body),
            Field.since: .int(Int64(notice.since)),
            Field.roomIds: .strings(notice.roomIds),
            Field.macName: .string(notice.macName),
            Field.version: .int(version)
        ]
        if let sessionId = notice.sessionId { out[Field.sessionId] = .string(sessionId) }
        return out
    }
}

/// 通知の文言。どれも状態と名前から組み立てる定型文で、画面や会話の文字列は使わない。
public enum AttentionNoticeText {
    static let maxNameLength = 40
    static let maxListedOthers = 3

    /// ツール名として出してよい形（`Bash`・`mcp__server__tool` 等）だけ通す。説明文やコマンドが混ざらないようにする。
    public static func toolName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw.count <= 64,
              raw.range(of: #"^[A-Za-z][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
        else { return nil }
        return raw
    }

    /// 権限待ちの通知文（`Claude needs your permission to use Bash.`）の形の時だけ、ツール名を取り出す。
    /// 他の形（エラー文・説明文・ファイル名）はツール名と見分けられないので拾わない。
    public static func toolName(fromDetail detail: String?) -> String? {
        guard let detail, let head = detail.split(separator: ":", maxSplits: 1).first,
              let range = head.range(of: #"permission to use [A-Za-z][A-Za-z0-9_.-]*[.!?。\s]*$"#,
                                     options: [.regularExpression, .caseInsensitive])
        else { return nil }
        var name = head[range].dropFirst("permission to use ".count)
        while let last = name.last, !(last.isASCII && (last.isLetter || last.isNumber)) { name = name.dropLast() }
        return toolName(String(name))
    }

    public static func summary(kind: AttentionKind, toolName raw: String?) -> String {
        switch kind {
        case .permission:
            if let tool = toolName(raw) { return "権限の確認を待っています（\(tool)）" }
            return "権限の確認を待っています"
        case .waiting:
            return "入力を待っています"
        case .error:
            return "エラーで止まっています"
        }
    }

    /// 制御文字を落として短くする（ルーム名はフォルダ名かセッション名）。
    public static func name(_ raw: String) -> String {
        let cleaned = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        let base = cleaned.isEmpty ? "Claude Code" : cleaned
        return base.count > maxNameLength ? String(base.prefix(maxNameLength - 1)) + "…" : base
    }

    public static func title(roomName: String, others: Int) -> String {
        others > 0 ? "\(name(roomName)) ほか \(others) 件" : name(roomName)
    }

    public static func body(summary: String, otherNames: [String]) -> String {
        guard !otherNames.isEmpty else { return summary }
        let listed = otherNames.prefix(maxListedOthers).map(name)
        let rest = otherNames.count - listed.count
        let names = listed.joined(separator: "、") + (rest > 0 ? " ほか \(rest) 件" : "")
        return "\(summary)。\(names) も対応を待っています"
    }
}
