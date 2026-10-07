import Foundation

/// 見出しの「リンク」で開く先。設定の `links` のうち開けるものだけを扱う。
public enum ProjectLinks {
    /// 開いてよい URL か（http / https で host があり userinfo の無いもの。`javascript:`・`file:`・資格情報付きは開かない）。
    public static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    /// 設定のリンクのうち、名前があって URL が開けるもの（並びは設定の順。同じ名前はメニューに並べないため先のものだけ残す）。
    public static func openable(_ links: [ProjectLink]) -> [ProjectLink] {
        var seen = Set<String>()
        return links.filter {
            SettingsValidation.projectLinkProblems($0).isEmpty && seen.insert($0.name.trimmingCharacters(in: .whitespaces)).inserted
        }
    }

    public static func help(for link: ProjectLink) -> String {
        "\(link.name) を開く: \(link.url.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// 種類ごとにまとめる（種類は定義の順・中は元の順。無い種類は出さない）。
    public static func grouped(_ links: [ProjectLink]) -> [(kind: ProjectLinkKind, links: [ProjectLink])] {
        ProjectLinkKind.allCases.compactMap { kind in
            let members = links.filter { $0.resolvedKind == kind }
            return members.isEmpty ? nil : (kind, members)
        }
    }

    /// host から名前を提案する（`www.` と末尾の TLD を除いた主要部分を先頭大文字に。`dashboard.stripe.com` → `Stripe`）。
    public static func suggestedName(for url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let labels = host.split(separator: ".").map(String.init)
        guard let first = labels.first, !first.isEmpty else { return nil }
        // IP アドレスはそのまま。
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return host }
        let main: String
        if labels.count >= 3, secondLevelTLDs.contains(labels.suffix(2).joined(separator: ".")) {
            main = labels[labels.count - 3]
        } else if labels.count >= 2 {
            main = labels[labels.count - 2]
        } else {
            main = first
        }
        return main.prefix(1).uppercased() + main.dropFirst()
    }

    /// `co.jp` のように国別の下に種別を置く TLD（末尾 3 ラベルで見るもの）。
    private static let secondLevelTLDs: Set<String> = [
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "ad.jp", "gr.jp", "ed.jp", "lg.jp",
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "com.br", "com.cn", "com.hk", "com.sg", "com.tw", "com.mx", "co.kr", "co.nz", "co.in", "co.za", "com.ar",
    ]
}

extension ProjectLinkKind {
    /// URL から種類を提案する（host とパスを小文字で見る。請求 → ストア → ドキュメント → ダッシュボード の順に当て、どれでもなければその他）。
    public static func suggest(for url: URL) -> ProjectLinkKind {
        var host = url.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = url.path.lowercased()
        let hostAndPath = host + path
        if billingWords.contains(where: { hostAndPath.contains($0) }) { return .billing }
        if storeHosts.contains(host) { return .store }
        if host.hasPrefix("docs.") || path.hasPrefix("/docs") { return .docs }
        if dashboardPrefixes.contains(where: { host.hasPrefix($0) }) || dashboardHosts.contains(host) { return .dashboard }
        return .other
    }

    private static let billingWords = ["billing", "invoice", "usage", "payment", "subscription"]
    private static let storeHosts: Set<String> = ["appstoreconnect.apple.com", "apps.apple.com", "play.google.com"]
    private static let dashboardPrefixes = ["console.", "dashboard.", "app.", "platform.", "admin.", "portal."]
    private static let dashboardHosts: Set<String> = [
        "vercel.com", "github.com", "gitlab.com", "supabase.com", "netlify.com", "cloudflare.com", "render.com",
        "railway.app", "fly.io", "heroku.com", "aws.amazon.com", "firebase.google.com", "cloud.google.com",
    ]
}
