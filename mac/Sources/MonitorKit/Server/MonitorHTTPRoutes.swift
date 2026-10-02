import Foundation

/// アプリ内サーバーの口（移植元: monitor/src/server.ts のうち外から叩かれるものだけ）。
///   GET  /api/health                 疎通確認
///   POST /hook                       Claude Code のフックから状態遷移を受け取る
///   POST /api/channel/permissions    チャネル（monitor/src/channel.ts）からの権限確認（判断が出るまで待たせる）
/// 認証が無く承認の口もあるので、ループバックでしか待ち受けず、Host / Origin / 接続元も確かめる。
public enum MonitorHTTPRoutes {
    /// 既定の待ち受け。`~/.claude/settings.json` のフックと channel.ts がこのポートを宛先にしている。
    public static let defaultPort = 8766

    /// 全ての口に先に掛ける検査。外れたら handler を呼ばずに返す。
    public static func guarded(_ request: HTTPRequest, port: Int,
                               handler: @Sendable (HTTPRequest) async -> HTTPResponse) async -> HTTPResponse {
        // DNS リバインディング対策。CORS は付けない（任意のサイトから作業内容を読ませないため）。
        guard LoopbackGuard.isAllowedHost(request.header("host"), port: port) else {
            return .json(403, ["ok": false, "error": "invalid host header"])
        }
        if let origin = request.header("origin"), !LoopbackGuard.isAllowedOrigin(origin, port: port) {
            return .json(403, ["ok": false, "error": "invalid origin header"])
        }
        // 承認を受け付ける口なので、Host は詐称できる前提で接続元でも確かめる。ループバック以外には存在ごと伏せる。
        guard LoopbackGuard.isLoopbackAddress(request.remoteAddress) else { return notFound }
        return await handler(request)
    }

    static let notFound = HTTPResponse.json(404, ["ok": false, "error": "not found"])

    /// 口の振り分け。`guarded` を通った後に呼ぶ。
    public static func handle(_ request: HTTPRequest, hub: SessionHub) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/api/health"):
            let count = await hub.snapshot().count
            return .json(200, ["ok": true, "sessions": count, "server": "claude-deck"])
        case ("POST", "/hook"):
            return await hook(request, hub: hub)
        case ("POST", "/api/channel/permissions"):
            return await channelPermission(request, hub: hub)
        default:
            return notFound
        }
    }

    /// content-type を必須にして、プリフライトを回避した cross-origin POST を弾く。
    enum Body {
        case object(Any)
        case rejected(HTTPResponse)
    }

    static func jsonBody(_ request: HTTPRequest) -> Body {
        guard request.header("content-type")?.lowercased().hasPrefix("application/json") == true else {
            return .rejected(.json(415, ["ok": false, "error": "content-type must be application/json"]))
        }
        guard let object = try? JSONSerialization.jsonObject(with: request.body, options: [.fragmentsAllowed]) else {
            return .rejected(.json(400, ["ok": false, "error": "invalid json"]))
        }
        return .object(object)
    }

    static func hook(_ request: HTTPRequest, hub: SessionHub) async -> HTTPResponse {
        let body: Any
        switch jsonBody(request) {
        case .rejected(let response): return response
        case .object(let object): body = object
        }
        let applied: Bool
        if let o = body as? [String: Any] {
            applied = await hub.applyHook(HookPayload(json: o))
        } else {
            applied = false
        }
        // 未知のセッションでも 200 を返す（フック側を失敗させないため）。
        return .json(200, ["ok": true, "applied": applied])
    }

    static func channelPermission(_ request: HTTPRequest, hub: SessionHub) async -> HTTPResponse {
        let body: Any
        switch jsonBody(request) {
        case .rejected(let response): return response
        case .object(let object): body = object
        }
        guard let input = PermissionRelay.parseRequest(body) else {
            return .json(400, ["ok": false, "error": "申請の形が不正です"])
        }
        let outcome = await hub.awaitPermission(input)
        return .json(200, ["ok": true, "outcome": outcome.rawValue])
    }
}
