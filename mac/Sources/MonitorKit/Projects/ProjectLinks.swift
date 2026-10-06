import Foundation

/// 見出しの「リンク」で開く先。設定の `links` のうち開けるものだけを扱う。
public enum ProjectLinks {
    /// 開いてよい URL か（http / https で host があるもの）。`javascript:` や `file:` は開かない。
    public static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              let url = components.url else { return nil }
        return url
    }

    /// 設定のリンクのうち、名前があって URL が開けるもの（並びは設定の順）。
    public static func openable(_ links: [ProjectLink]) -> [ProjectLink] {
        links.filter { SettingsValidation.projectLinkProblems($0).isEmpty }
    }

    public static func help(for link: ProjectLink) -> String {
        "\(link.name) を開く: \(link.url.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
