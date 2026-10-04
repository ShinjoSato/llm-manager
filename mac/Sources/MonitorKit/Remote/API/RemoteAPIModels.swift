import Foundation

// iPhone アプリと共有する API の型（`/v1/...`）。仕様は mac/docs/remote-api.md。
// このディレクトリ（Remote/API）と MonitorModels.swift は Foundation / Security / CryptoKit だけに依存させ、
// 後で共有パッケージへそのまま切り出せるようにする。

/// API の版。互換の無い変更をしたら上げ、パスの `/v1` も替える。
public enum RemoteAPI {
    public static let version = 1
    /// 既定の待ち受けポート（設定で変えられる）。
    public static let defaultPort = 8767
}

// MARK: - ペアリング

/// QR に載せる中身。`claude-deck://pair?...` の URL として表す。
public struct RemotePairingPayload: Codable, Sendable, Equatable {
    /// 接続先（LAN の IPv4 アドレス）。
    public var host: String
    public var port: Int
    /// ペアリング用の一時トークン（数分で失効・1 回限り）。
    public var token: String
    /// サーバー証明書（DER）の SHA-256 を小文字 16 進 64 桁で。iPhone はこれでピン留めする。
    public var fingerprint: String
    /// mac の名前（表示用）。
    public var name: String
    /// 一時トークンの期限（epoch ミリ秒）。
    public var expiresAt: Double
    /// mDNS の名前（`xxx.local`）。IP が替わった時の予備の接続先。
    public var localHostName: String?
    public var apiVersion: Int

    public init(host: String, port: Int, token: String, fingerprint: String, name: String, expiresAt: Double,
                localHostName: String? = nil, apiVersion: Int = RemoteAPI.version) {
        self.host = host
        self.port = port
        self.token = token
        self.fingerprint = fingerprint
        self.name = name
        self.expiresAt = expiresAt
        self.localHostName = localHostName
        self.apiVersion = apiVersion
    }

    public static let scheme = "claude-deck"

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "pair"
        var items = [URLQueryItem(name: "v", value: String(apiVersion)),
                     URLQueryItem(name: "host", value: host),
                     URLQueryItem(name: "port", value: String(port)),
                     URLQueryItem(name: "token", value: token),
                     URLQueryItem(name: "fp", value: fingerprint),
                     URLQueryItem(name: "name", value: name),
                     URLQueryItem(name: "exp", value: String(Int64(expiresAt)))]
        if let localHostName { items.append(URLQueryItem(name: "local", value: localHostName)) }
        c.queryItems = items
        return c.url!
    }

    /// QR から読んだ URL を解く。形が違えば nil。
    public init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == Self.scheme, c.host == "pair" else {
            return nil
        }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { if let v = item.value { q[item.name] = v } }
        guard let host = q["host"], !host.isEmpty, let port = q["port"].flatMap(Int.init), (1...65535).contains(port),
              let token = q["token"], !token.isEmpty,
              let fp = q["fp"]?.lowercased(), fp.count == 64, fp.allSatisfy(\.isHexDigit),
              let exp = q["exp"].flatMap(Double.init), let version = q["v"].flatMap(Int.init) else { return nil }
        self.init(host: host, port: port, token: token, fingerprint: fp, name: q["name"] ?? "", expiresAt: exp,
                  localHostName: q["local"], apiVersion: version)
    }
}

/// `POST /v1/pair` の本文。
public struct RemotePairRequest: Codable, Sendable, Equatable {
    public var token: String
    /// 端末の名前（mac の端末一覧に出る）。
    public var deviceName: String

    public init(token: String, deviceName: String) {
        self.token = token
        self.deviceName = deviceName
    }
}

/// `POST /v1/pair` の応答。`deviceToken` はこの時だけ返る（mac にはハッシュしか残らない）。
public struct RemotePairResponse: Codable, Sendable, Equatable {
    public var deviceId: String
    /// 以降の全 API で `Authorization: Bearer <deviceToken>` に使う。
    public var deviceToken: String
    public var serverName: String
    public var apiVersion: Int

    public init(deviceId: String, deviceToken: String, serverName: String, apiVersion: Int = RemoteAPI.version) {
        self.deviceId = deviceId
        self.deviceToken = deviceToken
        self.serverName = serverName
        self.apiVersion = apiVersion
    }
}

/// ペアリング済みの端末（mac の一覧・`/v1/info` に出す分）。
public struct RemoteDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var pairedAt: Double
    public var lastUsedAt: Double?

    public init(id: String, name: String, pairedAt: Double, lastUsedAt: Double?) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.lastUsedAt = lastUsedAt
    }
}

/// `GET /v1/info` の応答。
public struct RemoteInfo: Codable, Sendable, Equatable {
    public var apiVersion: Int
    public var serverName: String
    public var device: RemoteDevice

    public init(apiVersion: Int = RemoteAPI.version, serverName: String, device: RemoteDevice) {
        self.apiVersion = apiVersion
        self.serverName = serverName
        self.device = device
    }
}

// MARK: - ルーム一覧と状態

public enum RemoteRoomKind: String, LenientStringEnum {
    /// mac アプリが PTY でホストしているセッション。入力欄へ送れる。
    case hosted
    /// ターミナル・VS Code 等で動いているセッション。送れるのは伝言だけ。
    case external
    case unknown
    public static var unknownCase: RemoteRoomKind { .unknown }
}

/// 一覧のグループ（要対応 → 稼働中 → 待機）。
public enum RemoteRoomPhase: String, LenientStringEnum {
    case attention, active, idle
    case unknown
    public static var unknownCase: RemoteRoomPhase { .unknown }
}

/// 送信の口。
public enum RemoteSendMode: String, LenientStringEnum {
    /// 端末の入力欄へ（本人の入力と同じ）。
    case input
    /// 外部セッションへの伝言（「別セッションからのメッセージ」として届く）。
    case relay
    case unknown
    public static var unknownCase: RemoteSendMode { .unknown }
}

/// 端末画面に出ている権限プロンプト（Channels が無いホスト中のセッション）。
public struct RemoteTerminalPermission: Codable, Sendable, Equatable {
    /// 答える時に返す。今のプロンプトと違えば mac は送らない。
    public var promptId: String
    public var title: String
    public var lines: [String]

    public init(promptId: String, title: String, lines: [String]) {
        self.promptId = promptId
        self.title = title
        self.lines = lines
    }
}

public struct RemoteMenuOption: Codable, Sendable, Equatable {
    /// 回答で `choice` に渡す位置。
    public var index: Int
    public var number: Int?
    public var label: String
    public var detail: [String]
    /// 複数選択のチェック欄。無ければ nil。
    public var checked: Bool?
    /// 複数選択の「Submit」/「Next」の行。
    public var isSubmit: Bool
    /// 押せるか（文字入力に移る選択肢は押せない）。
    public var selectable: Bool

    public init(index: Int, number: Int?, label: String, detail: [String], checked: Bool?, isSubmit: Bool, selectable: Bool) {
        self.index = index
        self.number = number
        self.label = label
        self.detail = detail
        self.checked = checked
        self.isSubmit = isSubmit
        self.selectable = selectable
    }
}

public struct RemoteMenuTab: Codable, Sendable, Equatable {
    public var title: String
    public var answered: Bool

    public init(title: String, answered: Bool) {
        self.title = title
        self.answered = answered
    }
}

/// AskUserQuestion の問いのタブ。`current == tabs.count` は Submit タブ。
public struct RemoteMenuTabs: Codable, Sendable, Equatable {
    public var tabs: [RemoteMenuTab]
    public var hasSubmit: Bool
    public var current: Int?
    public var canMoveNext: Bool
    public var canMovePrevious: Bool

    public init(tabs: [RemoteMenuTab], hasSubmit: Bool, current: Int?, canMoveNext: Bool, canMovePrevious: Bool) {
        self.tabs = tabs
        self.hasSubmit = hasSubmit
        self.current = current
        self.canMoveNext = canMoveNext
        self.canMovePrevious = canMovePrevious
    }
}

/// 端末に出ている選択メニュー（plan の承認・AskUserQuestion・trust 確認など）。
public struct RemoteMenu: Codable, Sendable, Equatable {
    /// 回答で返す識別子。❯ の位置以外（問い・選択肢・チェック・タブ）が替われば変わる。
    public var menuId: String
    public var context: [String]
    public var question: String
    public var options: [RemoteMenuOption]
    /// ❯ の付いている選択肢の位置。
    public var cursor: Int
    public var footer: String
    public var tabs: RemoteMenuTabs?
    /// 複数選択（押すとチェックの切り替えになり、メニューは閉じない）。
    public var isMultiSelect: Bool
    /// AskUserQuestion の最後の確認（Submit タブ）。
    public var isReview: Bool
    /// 取り消し（Esc）が claude の終了になる。取り消すには `confirmExit: true` が要る。
    public var cancelExits: Bool

    public init(menuId: String, context: [String], question: String, options: [RemoteMenuOption], cursor: Int, footer: String,
                tabs: RemoteMenuTabs?, isMultiSelect: Bool, isReview: Bool, cancelExits: Bool) {
        self.menuId = menuId
        self.context = context
        self.question = question
        self.options = options
        self.cursor = cursor
        self.footer = footer
        self.tabs = tabs
        self.isMultiSelect = isMultiSelect
        self.isReview = isReview
        self.cancelExits = cancelExits
    }
}

/// 中身を読み取れない選択メニュー（取り消し（Esc）だけできる）。
public struct RemoteUnreadableMenu: Codable, Sendable, Equatable {
    public var menuId: String
    public var lines: [String]
    public var cancelExits: Bool

    public init(menuId: String, lines: [String], cancelExits: Bool) {
        self.menuId = menuId
        self.lines = lines
        self.cancelExits = cancelExits
    }
}

/// ルームへ送れるか。
public struct RemoteSendState: Codable, Sendable, Equatable {
    public var mode: RemoteSendMode
    /// 送れない理由（nil なら送れる）。
    public var disabledReason: String?

    public init(mode: RemoteSendMode, disabledReason: String?) {
        self.mode = mode
        self.disabledReason = disabledReason
    }
}

/// ルーム 1 つ（mac のルーム一覧の 1 行と、会話末尾のカードに出るもの）。
public struct RemoteRoom: Codable, Sendable, Equatable, Identifiable {
    /// `h:<UUID>`（ホスト中）/ `e:<sessionId>`（外部）。
    public var id: String
    public var kind: RemoteRoomKind
    public var phase: RemoteRoomPhase
    public var name: String
    public var branch: String?
    public var status: SessionStatus
    /// 一覧に出す直近の一行。
    public var line: String
    public var activityAt: Double?
    /// 会話の取得に使う。ホスト中で最初の発話前は nil。
    public var sessionId: String?
    public var cwd: String
    /// ホスト中のセッションが終わった理由（`exited` / `limitReached` / `launchFailed`）。動いていれば nil。
    public var ended: String?
    public var session: SessionSnapshot?
    /// 保留中の権限確認（Channels）。あれば `POST /v1/permissions/decision` で答える。
    public var permissions: [PendingPermission]
    /// Channels が無い時に端末画面から読んだ権限プロンプト。
    public var terminalPermission: RemoteTerminalPermission?
    public var menu: RemoteMenu?
    public var unreadableMenu: RemoteUnreadableMenu?
    /// 権限・選択肢の操作を送っている最中（mac 側・iPhone 側を問わず）。終わるまで押せない。
    public var busy: Bool
    public var send: RemoteSendState

    public init(id: String, kind: RemoteRoomKind, phase: RemoteRoomPhase, name: String, branch: String?, status: SessionStatus,
                line: String, activityAt: Double?, sessionId: String?, cwd: String, ended: String?, session: SessionSnapshot?,
                permissions: [PendingPermission], terminalPermission: RemoteTerminalPermission?, menu: RemoteMenu?,
                unreadableMenu: RemoteUnreadableMenu?, busy: Bool, send: RemoteSendState) {
        self.id = id
        self.kind = kind
        self.phase = phase
        self.name = name
        self.branch = branch
        self.status = status
        self.line = line
        self.activityAt = activityAt
        self.sessionId = sessionId
        self.cwd = cwd
        self.ended = ended
        self.session = session
        self.permissions = permissions
        self.terminalPermission = terminalPermission
        self.menu = menu
        self.unreadableMenu = unreadableMenu
        self.busy = busy
        self.send = send
    }

    /// 要対応のカード（権限・選択肢）が出ているか。
    public var needsAnswer: Bool {
        !permissions.isEmpty || terminalPermission != nil || menu != nil || unreadableMenu != nil
    }
}

/// `GET /v1/rooms` の応答と、`/v1/events` の `state` イベントの中身。
public struct RemoteState: Codable, Sendable, Equatable {
    /// 要対応 → 稼働中 → 待機、各グループ内は新しく動いた順。
    public var rooms: [RemoteRoom]
    public var usage: UsageSnapshot?
    /// mac の監視が動いているか（false の間は一覧が古い）。
    public var monitoring: Bool

    public init(rooms: [RemoteRoom], usage: UsageSnapshot?, monitoring: Bool) {
        self.rooms = rooms
        self.usage = usage
        self.monitoring = monitoring
    }
}

// MARK: - 操作

/// `POST /v1/permissions/decision`（Channels の権限確認）。
public struct RemotePermissionDecisionRequest: Codable, Sendable, Equatable {
    /// `PendingPermission.key`。
    public var key: String
    public var decision: PermissionDecision

    public init(key: String, decision: PermissionDecision) {
        self.key = key
        self.decision = decision
    }
}

/// `POST /v1/rooms/{roomId}/permission`（端末画面の権限プロンプト）。
public struct RemoteTerminalPermissionRequest: Codable, Sendable, Equatable {
    public var promptId: String
    public var decision: PermissionDecision

    public init(promptId: String, decision: PermissionDecision) {
        self.promptId = promptId
        self.decision = decision
    }
}

/// `POST /v1/rooms/{roomId}/menu`。`choice`（選択肢の位置）か `cancel: true`（Esc）のどちらか一方。
public struct RemoteMenuAnswerRequest: Codable, Sendable, Equatable {
    public var menuId: String
    public var choice: Int?
    public var cancel: Bool?
    /// 取り消しが claude の終了になるメニュー（`cancelExits`）を取り消す時に true。
    public var confirmExit: Bool?

    public init(menuId: String, choice: Int? = nil, cancel: Bool? = nil, confirmExit: Bool? = nil) {
        self.menuId = menuId
        self.choice = choice
        self.cancel = cancel
        self.confirmExit = confirmExit
    }
}

public enum RemoteTabDirection: String, Codable, Sendable {
    case next, previous
}

/// `POST /v1/rooms/{roomId}/menu/tab`。
public struct RemoteMenuTabRequest: Codable, Sendable, Equatable {
    public var menuId: String
    public var direction: RemoteTabDirection

    public init(menuId: String, direction: RemoteTabDirection) {
        self.menuId = menuId
        self.direction = direction
    }
}

/// `POST /v1/rooms/{roomId}/menu/dismiss`（読み取れないメニューを Esc で閉じる）。
public struct RemoteMenuDismissRequest: Codable, Sendable, Equatable {
    public var menuId: String
    public var confirmExit: Bool?

    public init(menuId: String, confirmExit: Bool? = nil) {
        self.menuId = menuId
        self.confirmExit = confirmExit
    }
}

/// `POST /v1/rooms/{roomId}/messages`。添付は受け付けない。
public struct RemoteMessageRequest: Codable, Sendable, Equatable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// 操作の結果。`code` は機械向け、`message` は人向け（日本語）。
public struct RemoteActionResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var code: String
    public var message: String?

    public init(ok: Bool, code: String, message: String? = nil) {
        self.ok = ok
        self.code = code
        self.message = message
    }

    public static func success(_ code: String, _ message: String? = nil) -> RemoteActionResult {
        RemoteActionResult(ok: true, code: code, message: message)
    }

    public static func failure(_ code: String, _ message: String) -> RemoteActionResult {
        RemoteActionResult(ok: false, code: code, message: message)
    }
}

/// 失敗時の本文（操作以外の口）。
public struct RemoteErrorBody: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String
    public var message: String?

    public init(error: String, message: String? = nil) {
        self.ok = false
        self.error = error
        self.message = message
    }
}

/// `/v1/events` のイベント名。
public enum RemoteEventName: String, Sendable {
    /// `RemoteState`。接続直後に 1 回と、変わるたび。
    case state
    /// `TranscriptEvent`（購読しているセッションの会話の追記）。
    case transcript
}
