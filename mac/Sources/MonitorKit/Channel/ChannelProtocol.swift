import Foundation

/// Claude Code が渡す権限確認（`notifications/claude/channel/permission_request` の params）。
public struct ChannelPermissionRequest: Sendable, Equatable {
    public var requestId: String
    public var toolName: String
    /// 説明も引数も Claude Code が組み立てた表示用の文字列。中継するだけで解釈しない。
    public var description: String
    public var inputPreview: String

    public init(requestId: String, toolName: String, description: String, inputPreview: String) {
        self.requestId = requestId
        self.toolName = toolName
        self.description = description
        self.inputPreview = inputPreview
    }
}

/// 1 行分の JSON-RPC メッセージをどう扱うか。
public enum ChannelInbound {
    /// そのまま 1 行で返す応答。
    case reply(String)
    /// 権限確認の中継を始める。
    case permissionRequest(ChannelPermissionRequest)
    /// 何もしない（通知・応答・壊れた行）。
    case ignore
}

/// チャネルの MCP（stdio・改行区切りの JSON-RPC 2.0）を必要な分だけ扱う。応答は @modelcontextprotocol/sdk 1.30 の Server に合わせる。
public enum ChannelProtocol {
    public static let serverName = "claude-deck-channel"
    public static let serverVersion = "0.1.0"
    public static let instructions = "claude-deck へ権限確認を中継するだけのチャネルです。イベントは届かないので、返信も不要です。"

    /// SDK の SUPPORTED_PROTOCOL_VERSIONS。知らない版を求められたら先頭（最新）で答える。
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05", "2024-10-07"]

    static let permissionRequestMethod = "notifications/claude/channel/permission_request"
    static let permissionMethod = "notifications/claude/channel/permission"
    static let methodNotFound = -32601

    /// 受け取った 1 行を読み解く。SDK と同じく、壊れた行・知らない通知には何も返さない。
    public static func handle(line: String) -> ChannelInbound {
        let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
        guard let message = JSONLoose.dict(JSONLoose.object(Array(trimmed.utf8))),
              JSONLoose.string(message["jsonrpc"]) == "2.0" else { return .ignore }
        guard let method = JSONLoose.string(message["method"]) else { return .ignore }
        let params = JSONLoose.dict(message["params"])
        guard let id = message["id"] else {
            return method == permissionRequestMethod ? permissionRequest(params).map(ChannelInbound.permissionRequest) ?? .ignore : .ignore
        }
        guard isValidId(id) else { return .ignore }
        switch method {
        case "initialize":
            return .reply(result(id: id, initializeResult(requested: JSONLoose.string(params?["protocolVersion"]))))
        case "ping":
            return .reply(result(id: id, [String: Any]()))
        default:
            // tools / prompts / resources は capabilities に載せていないので、SDK と同じく Method not found。
            return .reply(encode(["jsonrpc": "2.0", "id": id, "error": ["code": methodNotFound, "message": "Method not found"]]))
        }
    }

    /// JSON-RPC の id は文字列か整数（真偽値・小数は弾く）。
    static func isValidId(_ id: Any) -> Bool {
        if id is String { return true }
        guard let n = JSONLoose.number(id) else { return false }
        return n == n.rounded()
    }

    static func initializeResult(requested: String?) -> [String: Any] {
        let version = requested.flatMap { supportedProtocolVersions.contains($0) ? $0 : nil } ?? supportedProtocolVersions[0]
        return [
            "protocolVersion": version,
            "capabilities": [
                "experimental": [
                    "claude/channel": [String: Any](), // チャネルとして登録させる
                    "claude/channel/permission": [String: Any](), // 権限確認の中継をオプトイン
                ],
            ],
            "serverInfo": ["name": serverName, "version": serverVersion],
            "instructions": instructions,
        ]
    }

    static func permissionRequest(_ params: [String: Any]?) -> ChannelPermissionRequest? {
        guard let params,
              let requestId = JSONLoose.string(params["request_id"]),
              let toolName = JSONLoose.string(params["tool_name"]),
              let description = JSONLoose.string(params["description"]),
              let inputPreview = JSONLoose.string(params["input_preview"]) else { return nil }
        return ChannelPermissionRequest(requestId: requestId, toolName: toolName, description: description, inputPreview: inputPreview)
    }

    /// 判断を Claude Code へ返す通知。`allow` / `deny` しかない（「常に許可」は表現できない）。
    public static func permissionNotification(requestId: String, decision: PermissionDecision) -> String {
        encode(["jsonrpc": "2.0", "method": permissionMethod,
                "params": ["request_id": requestId, "behavior": decision.rawValue]])
    }

    static func result(id: Any, _ result: [String: Any]) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    /// 改行は区切りなので、JSONSerialization が文字列中の改行をエスケープすることに頼る。
    static func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
