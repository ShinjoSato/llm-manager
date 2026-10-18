import Foundation

/// 1 つのアプリの版・アプリの情報・審査の提出（タブを開いた時に取るもの）。
public struct AppStoreAppOverview: Equatable, Sendable {
    public var versions: [AppStoreVersion]
    public var appInfos: [AppStoreAppInfo]
    public var submissions: [AppStoreReviewSubmission]

    public init(versions: [AppStoreVersion], appInfos: [AppStoreAppInfo], submissions: [AppStoreReviewSubmission]) {
        self.versions = AppStoreVersions.sorted(versions)
        self.appInfos = appInfos
        self.submissions = AppStoreVersions.sortedSubmissions(submissions)
    }

    /// プラットフォームごとの最新の版と公開中の版（iOS を先に）。
    public var platforms: [AppStorePlatformSummary] { AppStoreVersions.summaries(versions) }
}

public struct AppStorePlatformSummary: Equatable, Sendable, Identifiable {
    public var platform: String?
    public var latest: AppStoreVersion
    /// 最新が公開中なら nil（同じ版を 2 度出さない）。
    public var live: AppStoreVersion?

    public var id: String { platform ?? "-" }

    /// メタデータを見られる版（最新、公開中が別にあればそれも）。
    public var metadataVersions: [AppStoreVersion] { [latest] + (live.map { [$0] } ?? []) }
}

/// 版の並べ方・選び方。
public enum AppStoreVersions {
    /// 版番号の数で新しい順（"1.10" > "1.9"）、同じなら作った日の新しい順。
    public static func sorted(_ versions: [AppStoreVersion]) -> [AppStoreVersion] {
        versions.sorted { a, b in
            let order = compare(a.versionString, b.versionString)
            if order != .orderedSame { return order == .orderedDescending }
            return (a.createdDate ?? .distantPast) > (b.createdDate ?? .distantPast)
        }
    }

    /// 数字の区切りごとに比べる（数字でない区切りは文字として比べる）。
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let pb = b.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : "0"
            let y = i < pb.count ? pb[i] : "0"
            if let nx = Int(x), let ny = Int(y) {
                if nx != ny { return nx < ny ? .orderedAscending : .orderedDescending }
            } else if x != y {
                return x.compare(y, options: .numeric)
            }
        }
        return .orderedSame
    }

    public static func summaries(_ versions: [AppStoreVersion]) -> [AppStorePlatformSummary] {
        let sorted = sorted(versions)
        var platforms: [String?] = []
        for version in sorted where !platforms.contains(version.platform) { platforms.append(version.platform) }
        platforms.sort { platformRank($0) < platformRank($1) }
        return platforms.compactMap { platform in
            let own = sorted.filter { $0.platform == platform }
            guard let latest = own.first else { return nil }
            let live = latest.isLive ? nil : own.first(where: \.isLive)
            return AppStorePlatformSummary(platform: platform, latest: latest, live: live)
        }
    }

    private static func platformRank(_ platform: String?) -> Int {
        switch platform {
        case "IOS": return 0
        case "MAC_OS": return 1
        case "VISION_OS": return 2
        case "TV_OS": return 3
        default: return 4
        }
    }

    /// 提出の新しい順（まだ提出していない下書きは先頭）。
    public static func sortedSubmissions(_ submissions: [AppStoreReviewSubmission]) -> [AppStoreReviewSubmission] {
        submissions.sorted { a, b in
            switch (a.submittedDate, b.submittedDate) {
            case (nil, nil): return a.id < b.id
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?): return x > y
            }
        }
    }

    /// 版に合うアプリの情報: 公開中の版には公開中の情報、それ以外には公開中でない情報（無ければある方）。
    public static func appInfo(for version: AppStoreVersion, in infos: [AppStoreAppInfo]) -> AppStoreAppInfo? {
        let live = infos.filter(\.isLive)
        let other = infos.filter { !$0.isLive && !isReplaced($0.state) }
        if version.isLive { return live.first ?? other.first ?? infos.first }
        return other.first ?? live.first ?? infos.first
    }

    private static func isReplaced(_ state: String?) -> Bool {
        state == "REPLACED_WITH_NEW_INFO"
    }
}

/// メタデータの欄と文字数の上限。
public enum AppStoreMetadataField: String, CaseIterable, Sendable, Identifiable {
    case name, subtitle, description, keywords, promotionalText, whatsNew, supportUrl, marketingUrl

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .name: return "名前"
        case .subtitle: return "サブタイトル"
        case .description: return "説明文"
        case .keywords: return "キーワード"
        case .promotionalText: return "プロモーションテキスト"
        case .whatsNew: return "What's New"
        case .supportUrl: return "サポート URL"
        case .marketingUrl: return "マーケティング URL"
        }
    }

    /// 上限（URL は数えない）。
    public var limit: Int? {
        switch self {
        case .name, .subtitle: return 30
        case .description, .whatsNew: return 4000
        case .keywords: return 100
        case .promotionalText: return 170
        case .supportUrl, .marketingUrl: return nil
        }
    }

    public var isURL: Bool { self == .supportUrl || self == .marketingUrl }

    /// 数え方は appstore-plugin と同じ（Unicode のコードポイントの数）。
    public static func count(_ text: String?) -> Int {
        text?.unicodeScalars.count ?? 0
    }

    public func isOver(_ text: String?) -> Bool {
        guard let limit else { return false }
        return Self.count(text) > limit
    }
}

/// ロケール 1 つ分の文面（版の文面とアプリの情報の名前・サブタイトルを合わせたもの）。
public struct AppStoreLocaleMetadata: Equatable, Sendable, Identifiable {
    public var locale: String
    public var values: [AppStoreMetadataField: String]

    public var id: String { locale }

    public func value(_ field: AppStoreMetadataField) -> String? { values[field] }

    public var overLimitFields: [AppStoreMetadataField] {
        AppStoreMetadataField.allCases.filter { $0.isOver(values[$0]) }
    }

    /// 版の文面のロケールを主に、名前・サブタイトルだけのロケールも足す。並びは主の言語を先に、あとは名前順。
    public static func merge(version: [AppStoreVersionLocalization], info: [AppStoreAppInfoLocalization],
                             primaryLocale: String?) -> [AppStoreLocaleMetadata] {
        var byLocale: [String: [AppStoreMetadataField: String]] = [:]
        func set(_ locale: String, _ field: AppStoreMetadataField, _ value: String?) {
            guard !locale.isEmpty else { return }
            if byLocale[locale] == nil { byLocale[locale] = [:] }
            if let value { byLocale[locale]?[field] = value }
        }
        for loc in version {
            set(loc.locale, .description, loc.description)
            set(loc.locale, .keywords, loc.keywords)
            set(loc.locale, .promotionalText, loc.promotionalText)
            set(loc.locale, .whatsNew, loc.whatsNew)
            set(loc.locale, .supportUrl, loc.supportUrl)
            set(loc.locale, .marketingUrl, loc.marketingUrl)
        }
        for loc in info {
            set(loc.locale, .name, loc.name)
            set(loc.locale, .subtitle, loc.subtitle)
        }
        return byLocale.keys.sorted { a, b in
            if a == primaryLocale { return b != primaryLocale }
            if b == primaryLocale { return false }
            return a < b
        }.map { AppStoreLocaleMetadata(locale: $0, values: byLocale[$0] ?? [:]) }
    }
}
