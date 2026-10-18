import Foundation

/// 取得の失敗。文言は画面に出す（鍵・トークンは含めない）。429 / 5xx も自動では取り直さない。
public enum AppStoreFailure: Error, Equatable, Sendable {
    case credentials(AppStoreCredentialProblem)
    case unauthorized
    case forbidden(String?)
    case notFound
    case rateLimited
    case server(Int)
    case http(Int, String?)
    case network(String)
    case badResponse
    case invalidRequest

    public var message: String {
        switch self {
        case .credentials(let problem):
            return problem.message
        case .unauthorized:
            return "App Store Connect に認証を断られました（401）。\(AppStoreEnvFile.displayPath) の ASC_KEY_ID・ASC_ISSUER_ID と鍵の組み合わせ、鍵が取り消されていないかを確かめてください"
        case .forbidden(let detail):
            return "このキーでは見られません（403）。キーの役割とアプリへのアクセスを App Store Connect で確かめてください" + (detail.map { "（\($0)）" } ?? "")
        case .notFound:
            return "見つかりません（404）。appId が正しいか、このキーで見られるアプリかを確かめてください"
        case .rateLimited:
            return "要求が多すぎると断られました（429）。しばらく待ってから「再読み込み」を押してください"
        case .server(let code):
            return "App Store Connect の側で失敗しました（\(code)）。しばらく待ってから「再読み込み」を押してください"
        case .http(let code, let detail):
            return "取得できませんでした（\(code)）" + (detail.map { ": \($0)" } ?? "")
        case .network(let reason):
            return "App Store Connect につながりませんでした（\(reason)）"
        case .badResponse:
            return "App Store Connect の応答を読めませんでした"
        case .invalidRequest:
            return "appId の形が正しくありません（数字だけです）"
        }
    }

    static func from(status: Int, body: Data) -> AppStoreFailure {
        let summary = AppStoreResponse.errorSummary(body)
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden(summary)
        case 404: return .notFound
        case 429: return .rateLimited
        case 500...599: return .server(status)
        default: return .http(status, summary)
        }
    }
}

/// App Store Connect API の読み取りだけのクライアント。要求は `AppStoreRequest` でしか作れず、GET だけを送る。
public actor AppStoreClient {
    /// 要求を送って本文と応答を返す（試験では差し替える）。
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public typealias CredentialLoader = @Sendable () -> Result<AppStoreCredentials, AppStoreCredentialProblem>

    /// 一覧をたどる回数の上限（`links.next`）。
    static let maxPages = 4

    private let transport: Transport
    private let loadCredentials: CredentialLoader
    private let now: @Sendable () -> Date
    private var tokens = AppStoreTokenCache()

    public init(transport: @escaping Transport = AppStoreClient.urlSessionTransport,
                credentials: @escaping CredentialLoader = { AppStoreEnvFile.load() },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.loadCredentials = credentials
        self.now = now
    }

    /// 次の要求で鍵を読み直す（env を直した後の「再読み込み」で効かせるため）。
    public func resetToken() {
        tokens.clear()
    }

    public func apps() async throws(AppStoreFailure) -> [AppStoreApp] {
        try await all(.apps, parse: AppStoreResponse.apps)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func overview(appId: String) async throws(AppStoreFailure) -> AppStoreAppOverview {
        let versions = try await all(.appStoreVersions(appId: appId), parse: AppStoreResponse.versions)
        let infos = try await all(.appInfos(appId: appId), parse: AppStoreResponse.appInfos, pages: 1)
        let submissions = try await all(.reviewSubmissions(appId: appId), parse: AppStoreResponse.reviewSubmissions, pages: 1)
        return AppStoreAppOverview(versions: versions, appInfos: infos, submissions: submissions)
    }

    public func metadata(versionId: String, appInfoId: String?, primaryLocale: String?) async throws(AppStoreFailure) -> [AppStoreLocaleMetadata] {
        let version = try await all(.versionLocalizations(versionId: versionId), parse: AppStoreResponse.versionLocalizations)
        var info: [AppStoreAppInfoLocalization] = []
        if let appInfoId {
            info = try await all(.appInfoLocalizations(appInfoId: appInfoId), parse: AppStoreResponse.appInfoLocalizations)
        }
        return AppStoreLocaleMetadata.merge(version: version, info: info, primaryLocale: primaryLocale)
    }

    private func all<Item: Sendable>(_ endpoint: AppStoreRequest.Endpoint, parse: (Data) throws -> AppStoreResponse.Page<Item>,
                                     pages: Int = maxPages) async throws(AppStoreFailure) -> [Item] {
        guard var request = AppStoreRequest.make(endpoint) else { throw .invalidRequest }
        var items: [Item] = []
        for page in 1...max(pages, 1) {
            let data = try await send(request)
            let parsed: AppStoreResponse.Page<Item>
            do { parsed = try parse(data) } catch { throw .badResponse }
            items += parsed.items
            guard page < pages, let link = parsed.next, let next = AppStoreRequest.next(link) else { break }
            request = next
        }
        return items
    }

    private func send(_ request: AppStoreRequest) async throws(AppStoreFailure) -> Data {
        let credentials: AppStoreCredentials
        switch loadCredentials() {
        case .success(let loaded): credentials = loaded
        case .failure(let problem): throw .credentials(problem)
        }
        let token: String
        do { token = try tokens.token(credentials: credentials, now: now()) } catch { throw .credentials(.privateKeyInvalid) }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request.urlRequest(token: token))
        } catch let error as URLError {
            throw .network(Self.networkReason(error))
        } catch {
            throw .network("通信の失敗")
        }
        if response.statusCode == 401 { tokens.clear() }
        guard (200..<300).contains(response.statusCode) else { throw AppStoreFailure.from(status: response.statusCode, body: data) }
        return data
    }

    static func networkReason(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost: return "ネットワークにつながっていません"
        case .timedOut: return "時間切れ"
        case .cannotFindHost, .dnsLookupFailed: return "宛先が見つかりません"
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .secureConnectionFailed: return "TLS の確認に失敗"
        case .cancelled: return "取りやめ"
        default: return "通信の失敗 \(error.code.rawValue)"
        }
    }

    /// クッキー・キャッシュ・資格情報の保存なし。リダイレクトは辿らない（Bearer を他所へ送らないため）。
    public static let urlSessionTransport: Transport = { request in
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.host == AppStoreRequest.host else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
