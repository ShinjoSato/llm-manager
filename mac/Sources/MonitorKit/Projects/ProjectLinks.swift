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
}
