import Foundation

/// App Store Connect のアプリ 1 件（一覧の行）。
public struct AppStoreApp: Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var bundleId: String
    public var sku: String?
    public var primaryLocale: String?

    public init(id: String, name: String, bundleId: String, sku: String? = nil, primaryLocale: String? = nil) {
        self.id = id
        self.name = name
        self.bundleId = bundleId
        self.sku = sku
        self.primaryLocale = primaryLocale
    }
}

/// App Store の版 1 件。
public struct AppStoreVersion: Equatable, Sendable, Identifiable {
    public var id: String
    public var versionString: String
    public var platform: String?
    /// `appVersionState` を先に、無ければ `appStoreState`（古い名前）。
    public var state: String?
    public var createdDate: Date?
    public var releaseType: String?
    public var earliestReleaseDate: Date?

    public init(id: String, versionString: String, platform: String? = nil, state: String? = nil, createdDate: Date? = nil,
                releaseType: String? = nil, earliestReleaseDate: Date? = nil) {
        self.id = id
        self.versionString = versionString
        self.platform = platform
        self.state = state
        self.createdDate = createdDate
        self.releaseType = releaseType
        self.earliestReleaseDate = earliestReleaseDate
    }

    public var isLive: Bool { AppStoreStates.isLive(state) }
}

/// 版のロケールごとの文面。
public struct AppStoreVersionLocalization: Equatable, Sendable, Identifiable {
    public var id: String
    public var locale: String
    public var description: String?
    public var keywords: String?
    public var promotionalText: String?
    public var whatsNew: String?
    public var supportUrl: String?
    public var marketingUrl: String?

    public init(id: String, locale: String, description: String? = nil, keywords: String? = nil, promotionalText: String? = nil,
                whatsNew: String? = nil, supportUrl: String? = nil, marketingUrl: String? = nil) {
        self.id = id
        self.locale = locale
        self.description = description
        self.keywords = keywords
        self.promotionalText = promotionalText
        self.whatsNew = whatsNew
        self.supportUrl = supportUrl
        self.marketingUrl = marketingUrl
    }
}

/// アプリの情報（名前・サブタイトルの入れ物）。公開中と編集中で 2 つあることがある。
public struct AppStoreAppInfo: Equatable, Sendable, Identifiable {
    public var id: String
    /// `state` を先に、無ければ `appStoreState`。
    public var state: String?

    public init(id: String, state: String? = nil) {
        self.id = id
        self.state = state
    }

    public var isLive: Bool { AppStoreStates.isLive(state) }
}

public struct AppStoreAppInfoLocalization: Equatable, Sendable, Identifiable {
    public var id: String
    public var locale: String
    public var name: String?
    public var subtitle: String?

    public init(id: String, locale: String, name: String? = nil, subtitle: String? = nil) {
        self.id = id
        self.locale = locale
        self.name = name
        self.subtitle = subtitle
    }
}

/// 審査の提出 1 件。
public struct AppStoreReviewSubmission: Equatable, Sendable, Identifiable {
    public var id: String
    public var state: String?
    public var platform: String?
    public var submittedDate: Date?

    public init(id: String, state: String? = nil, platform: String? = nil, submittedDate: Date? = nil) {
        self.id = id
        self.state = state
        self.platform = platform
        self.submittedDate = submittedDate
    }
}

/// JSON:API の応答の読み取り。知らない属性は無視し、型の違う値は無いものとして読む。
public enum AppStoreResponse {
    public struct Page<Item: Sendable>: Sendable {
        public var items: [Item]
        public var next: String?
    }

    public enum ParseError: Error, Equatable {
        case notJSON
        case noData
    }

    public static func apps(_ data: Data) throws -> Page<AppStoreApp> {
        try page(data) { id, a in
            AppStoreApp(id: id, name: a.string("name") ?? "", bundleId: a.string("bundleId") ?? "",
                        sku: a.string("sku"), primaryLocale: a.string("primaryLocale"))
        }
    }

    public static func versions(_ data: Data) throws -> Page<AppStoreVersion> {
        try page(data) { id, a in
            AppStoreVersion(id: id, versionString: a.string("versionString") ?? "", platform: a.string("platform"),
                            state: a.string("appVersionState") ?? a.string("appStoreState"),
                            createdDate: a.date("createdDate"), releaseType: a.string("releaseType"),
                            earliestReleaseDate: a.date("earliestReleaseDate"))
        }
    }

    public static func versionLocalizations(_ data: Data) throws -> Page<AppStoreVersionLocalization> {
        try page(data) { id, a in
            AppStoreVersionLocalization(id: id, locale: a.string("locale") ?? "", description: a.string("description"),
                                        keywords: a.string("keywords"), promotionalText: a.string("promotionalText"),
                                        whatsNew: a.string("whatsNew"), supportUrl: a.string("supportUrl"),
                                        marketingUrl: a.string("marketingUrl"))
        }
    }

    public static func appInfos(_ data: Data) throws -> Page<AppStoreAppInfo> {
        try page(data) { id, a in AppStoreAppInfo(id: id, state: a.string("state") ?? a.string("appStoreState")) }
    }

    public static func appInfoLocalizations(_ data: Data) throws -> Page<AppStoreAppInfoLocalization> {
        try page(data) { id, a in
            AppStoreAppInfoLocalization(id: id, locale: a.string("locale") ?? "", name: a.string("name"), subtitle: a.string("subtitle"))
        }
    }

    public static func reviewSubmissions(_ data: Data) throws -> Page<AppStoreReviewSubmission> {
        try page(data) { id, a in
            AppStoreReviewSubmission(id: id, state: a.string("state"), platform: a.string("platform"), submittedDate: a.date("submittedDate"))
        }
    }

    /// 失敗の応答の `errors[].title` / `detail`（あれば最初の 1 件）。
    public static func errorSummary(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = root["errors"] as? [[String: Any]], let first = errors.first else { return nil }
        let parts = [first["title"] as? String, first["detail"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return String(parts.joined(separator: ": ").prefix(300))
    }

    struct Attributes {
        let raw: [String: Any]

        func string(_ key: String) -> String? { raw[key] as? String }

        func date(_ key: String) -> Date? {
            guard let text = string(key) else { return nil }
            return AppStoreResponse.parseDate(text)
        }
    }

    static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    private static func page<Item: Sendable>(_ data: Data, _ make: (String, Attributes) -> Item) throws -> Page<Item> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ParseError.notJSON }
        guard let list = root["data"] as? [[String: Any]] else { throw ParseError.noData }
        let items = list.compactMap { resource -> Item? in
            guard let id = resource["id"] as? String, !id.isEmpty else { return nil }
            return make(id, Attributes(raw: resource["attributes"] as? [String: Any] ?? [:]))
        }
        let next = (root["links"] as? [String: Any])?["next"] as? String
        return Page(items: items, next: next)
    }
}
