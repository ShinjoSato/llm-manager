import Foundation

/// アプリ内サーバー（:8766）の口: `GET /api/health`・`POST /hook`・`POST /api/channel/permissions`（判断が出るまで待たせる）。
/// 認証が無く承認の口もあるので、ループバックでしか待ち受けず、Host / Origin / 接続元も確かめる。
public enum HookServerRoutes {
    /// 既定の待ち受け。`~/.claude/settings.json` のフックと claude-deck-channel がこのポートを宛先にしている。
    public static let defaultPort = 8766

    /// 全ての口に先に掛ける検査。外れたら handler を呼ばずに返す。
    public static func guarded(_ request: HTTPRequest, port: Int,
                               handler: @Sendable (HTTPRequest) async -> HTTPResponse) async -> HTTPResponse {
        if let rejected = rejection(request, port: port) { return rejected }
        return await handler(request)
    }

    /// 本文を読む前にも掛けられる検査（ヘッダーと接続元だけを見る）。通れば nil。
    public static func rejection(_ request: HTTPRequest, port: Int) -> HTTPResponse? {
        // DNS リバインディング対策。CORS は付けない（任意のサイトから作業内容を読ませないため）。
        guard LoopbackGuard.isAllowedHost(request.header("host"), port: port) else {
            return .json(403, ["ok": false, "error": "invalid host header"])
        }
        if let origin = request.header("origin"), !LoopbackGuard.isAllowedOrigin(origin, port: port) {
            return .json(403, ["ok": false, "error": "invalid origin header"])
        }
        // 承認を受け付ける口なので、Host は詐称できる前提で接続元でも確かめる。ループバック以外には存在ごと伏せる。
        guard LoopbackGuard.isLoopbackAddress(request.remoteAddress) else { return notFound }
        return nil
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
        guard request.isJSONContentType else {
            return .rejected(.json(415, ["ok": false, "error": "content-type must be application/json"]))
        }
        guard let object = JSONLoose.object(request.body) else {
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
        // フック側の curl は短い時間で諦めるので、反映を待たずに返す（反映は届いた順に後で流す）。
        if let o = body as? [String: Any] { hub.enqueueHook(HookPayload(json: o)) }
        return .json(200, ["ok": true])
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
