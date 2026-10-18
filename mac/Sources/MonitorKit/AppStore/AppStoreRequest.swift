import Foundation

/// App Store Connect API への読み取りの要求。宛先は api.appstoreconnect.apple.com の https・メソッドは GET だけで、他は作れない。
public struct AppStoreRequest: Equatable, Sendable {
    public static let scheme = "https"
    public static let host = "api.appstoreconnect.apple.com"
    public static let method = "GET"

    public let url: URL

    private init(url: URL) {
        self.url = url
    }

    /// 決まった要求だけを組み立てる。ID は数字・英数字とハイフンだけ（パスを書き換えられないように）。
    public enum Endpoint: Equatable, Sendable {
        case apps
        case appStoreVersions(appId: String)
        case versionLocalizations(versionId: String)
        case appInfos(appId: String)
        case appInfoLocalizations(appInfoId: String)
        case reviewSubmissions(appId: String)
    }

    public static func make(_ endpoint: Endpoint) -> AppStoreRequest? {
        let path: String
        let query: [(String, String)]
        switch endpoint {
        case .apps:
            path = "/v1/apps"
            query = [("limit", "200"), ("fields[apps]", "name,bundleId,sku,primaryLocale")]
        case .appStoreVersions(let appId):
            guard isAppID(appId) else { return nil }
            path = "/v1/apps/\(appId)/appStoreVersions"
            query = [("limit", "200")]
        case .versionLocalizations(let versionId):
            guard isResourceID(versionId) else { return nil }
            path = "/v1/appStoreVersions/\(versionId)/appStoreVersionLocalizations"
            query = [("limit", "50"),
                     ("fields[appStoreVersionLocalizations]", "locale,description,keywords,promotionalText,whatsNew,supportUrl,marketingUrl")]
        case .appInfos(let appId):
            guard isAppID(appId) else { return nil }
            path = "/v1/apps/\(appId)/appInfos"
            query = [("limit", "10")]
        case .appInfoLocalizations(let appInfoId):
            guard isResourceID(appInfoId) else { return nil }
            path = "/v1/appInfos/\(appInfoId)/appInfoLocalizations"
            query = [("limit", "50"), ("fields[appInfoLocalizations]", "locale,name,subtitle")]
        case .reviewSubmissions(let appId):
            guard isAppID(appId) else { return nil }
            path = "/v1/reviewSubmissions"
            query = [("filter[app]", appId), ("limit", "200")]
        }
        let encoded = query.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        return checked("\(scheme)://\(host)\(path)?\(encoded)")
    }

    /// 応答の `links.next`。同じ宛先の `/v1/` の下だけを受ける（他所へ Bearer を送らないため）。
    public static func next(_ link: String) -> AppStoreRequest? {
        checked(link)
    }

    private static func checked(_ text: String) -> AppStoreRequest? {
        guard let url = URL(string: text),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme, components.host == host,
              components.port == nil, components.user == nil, components.password == nil, components.fragment == nil,
              components.percentEncodedPath.hasPrefix("/v1/"),
              !components.percentEncodedPath.contains(".."), !components.percentEncodedPath.contains("//") else { return nil }
        return AppStoreRequest(url: url)
    }

    public func urlRequest(token: String, timeout: TimeInterval = 20) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = Self.method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-deck", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// App Store Connect の appId は数字だけ。
    public static func isAppID(_ text: String) -> Bool {
        (1...20).contains(text.count) && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func isResourceID(_ text: String) -> Bool {
        (1...64).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// 英数字と `-._~,` 以外は百分率で書く（`[` `]` も含めて、組み立てた URL を一意にするため）。
    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~,")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
