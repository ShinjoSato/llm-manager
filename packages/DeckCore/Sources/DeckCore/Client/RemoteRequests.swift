import Foundation

/// ペアリング済みの mac（iPhone がキーチェーンに残すもの）。
public struct RemotePairing: Codable, Sendable, Equatable {
    /// QR に載っていた接続先（LAN の IPv4）。
    public var host: String
    public var port: Int
    /// mDNS の名前。IP が替わった時の予備の接続先。
    public var localHostName: String?
    /// ピン留めした証明書の SHA-256（小文字 16 進 64 桁）。
    public var fingerprint: String
    public var serverName: String
    public var deviceId: String
    public var deviceToken: String
    /// epoch ミリ秒。
    public var pairedAt: Double

    public init(host: String, port: Int, localHostName: String?, fingerprint: String, serverName: String, deviceId: String,
                deviceToken: String, pairedAt: Double) {
        self.host = host
        self.port = port
        self.localHostName = localHostName
        self.fingerprint = fingerprint
        self.serverName = serverName
        self.deviceId = deviceId
        self.deviceToken = deviceToken
        self.pairedAt = pairedAt
    }

    public init(payload: RemotePairingPayload, response: RemotePairResponse, pairedAt: Double) {
        self.init(host: payload.host, port: payload.port, localHostName: payload.localHostName, fingerprint: payload.fingerprint,
                  serverName: response.serverName.isEmpty ? payload.name : response.serverName, deviceId: response.deviceId,
                  deviceToken: response.deviceToken, pairedAt: pairedAt)
    }

    /// 試す順の接続先（QR のアドレス → mDNS の名前）。
    public var hosts: [String] {
        var out = [host]
        if let localHostName, !localHostName.isEmpty, localHostName != host { out.append(localHostName) }
        return out
    }
}

extension RemotePairingPayload {
    /// 読み取った QR を使えるか。使えなければ人に見せる理由。
    public func problem(now: Double) -> String? {
        if apiVersion != RemoteAPI.version {
            return apiVersion > RemoteAPI.version
                ? "mac アプリの方が新しい版です。iPhone アプリを更新してください。"
                : "mac アプリが古い版です。mac アプリを更新してください。"
        }
        if expiresAt <= now { return "この QR は期限切れです。mac で新しい QR を出してください。" }
        return nil
    }

    /// 接続先が手元の LAN の外を指していないか。外れていれば人に見せる理由（端末トークンを外へ送らせない）。
    public var addressProblem: String? {
        if !Self.isLocalNetworkHost(host) {
            return "接続先（\(host)）が家庭内の LAN のアドレスではないので使えません。Mac の claude-deck で出した QR を読み取ってください。"
        }
        if let localHostName, !Self.isLocalHostName(localHostName) {
            return "予備の接続先（\(localHostName)）が .local の名前ではないので使えません。Mac の claude-deck で出した QR を読み取ってください。"
        }
        return nil
    }

    /// プライベートの IPv4（10/8・172.16/12・192.168/16）とリンクローカル（169.254/16）、`.local` の名前だけを LAN とみなす。
    public static func isLocalNetworkHost(_ host: String) -> Bool {
        if let octets = ipv4Octets(host) {
            switch (octets[0], octets[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, let b): return (16...31).contains(b)
            default: return false
            }
        }
        return isLocalHostName(host)
    }

    /// `xxx.local` の形の mDNS の名前か（ラベルは英数字とハイフンだけ）。
    public static func isLocalHostName(_ name: String) -> Bool {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.last?.lowercased() == "local" else { return false }
        return labels.dropLast().allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.utf8.allSatisfy { $0 == 0x2d || (0x30...0x39).contains($0) || (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0) }
                && label.first != "-" && label.last != "-"
        }
    }

    /// 10 進の 4 つ組だけを IPv4 とみなす（先頭の 0 は 8 進と読まれ得るので認めない）。
    static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [Int] = []
        for part in parts {
            guard (1...3).contains(part.count), part.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                  part.count == 1 || part.first != "0", let value = Int(part), value <= 255 else { return nil }
            out.append(value)
        }
        return out
    }
}

/// `/v1` の各口の要求を組み立てる。
public struct RemoteRequestBuilder: Sendable {
    public var host: String
    public var port: Int
    /// 端末トークン（ペアリング前は nil）。
    public var token: String?
    /// 操作の待ち時間。mac での操作は最大 30 秒かかるので、それより長く待つ。
    static let actionTimeout: TimeInterval = 40
    /// ストリームの無通信の許容（mac は 15 秒ごとに ping を送る）。
    static let streamIdleTimeout: TimeInterval = 40

    public init(host: String, port: Int, token: String?) {
        self.host = host
        self.port = port
        self.token = token
    }

    /// パスの 1 区切り分の文字（`/` や `?` を含む id でも区切りを壊さない）。
    static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#;")
        return set
    }()

    static func segment(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? raw
    }

    public func url(_ segments: [String], query: [URLQueryItem] = []) -> URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.port = port
        c.percentEncodedPath = "/v1/" + segments.map(Self.segment).joined(separator: "/")
        if !query.isEmpty { c.queryItems = query }
        return c.url
    }

    private func request(_ method: String, _ segments: [String], query: [URLQueryItem] = [], timeout: TimeInterval? = nil,
                         authorized: Bool = true) throws -> URLRequest {
        guard let url = url(segments, query: query) else { throw RemoteClientError.invalidAddress }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout ?? Self.actionTimeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if authorized, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func post<Body: Encodable>(_ segments: [String], _ body: Body, authorized: Bool = true) throws -> URLRequest {
        var req = try request("POST", segments, authorized: authorized)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }

    public func pair(token: String, deviceName: String) throws -> URLRequest {
        try post(["pair"], RemotePairRequest(token: token, deviceName: deviceName), authorized: false)
    }

    public func info() throws -> URLRequest { try request("GET", ["info"], timeout: 10) }

    public func unpair() throws -> URLRequest {
        var req = try request("POST", ["unpair"], timeout: 10)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        return req
    }

    public func rooms() throws -> URLRequest { try request("GET", ["rooms"], timeout: 15) }

    /// `transcripts` が nil なら会話を購読しない。`["*"]` は全部。
    public func events(transcripts: [String]?) throws -> URLRequest {
        let query = transcripts.map { [URLQueryItem(name: "transcripts", value: $0.joined(separator: ","))] } ?? []
        var req = try request("GET", ["events"], query: query, timeout: Self.streamIdleTimeout)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return req
    }

    public func transcript(sessionId: String, after: String?) throws -> URLRequest {
        let query = after.map { [URLQueryItem(name: "after", value: $0)] } ?? []
        return try request("GET", ["sessions", sessionId, "transcript"], query: query, timeout: 20)
    }

    public func image(sessionId: String, itemId: String, index: Int) throws -> URLRequest {
        try request("GET", ["sessions", sessionId, "items", itemId, "images", String(index)], timeout: 30)
    }

    public func decide(key: String, decision: PermissionDecision) throws -> URLRequest {
        try post(["permissions", "decision"], RemotePermissionDecisionRequest(key: key, decision: decision))
    }

    public func terminalPermission(roomId: String, promptId: String, decision: PermissionDecision) throws -> URLRequest {
        try post(["rooms", roomId, "permission"], RemoteTerminalPermissionRequest(promptId: promptId, decision: decision))
    }

    public func menu(roomId: String, _ body: RemoteMenuAnswerRequest) throws -> URLRequest {
        try post(["rooms", roomId, "menu"], body)
    }

    public func menuTab(roomId: String, _ body: RemoteMenuTabRequest) throws -> URLRequest {
        try post(["rooms", roomId, "menu", "tab"], body)
    }

    public func menuDismiss(roomId: String, _ body: RemoteMenuDismissRequest) throws -> URLRequest {
        try post(["rooms", roomId, "menu", "dismiss"], body)
    }

    public func message(roomId: String, text: String) throws -> URLRequest {
        try post(["rooms", roomId, "messages"], RemoteMessageRequest(text: text))
    }
}
