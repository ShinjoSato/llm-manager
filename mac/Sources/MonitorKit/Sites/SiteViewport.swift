import CryptoKit
import Foundation

/// プレビューの表示幅。サイトはこの幅（CSS ピクセル）で組ませ、枠に収まるよう縮めて見せる。
public enum SiteViewport: String, CaseIterable, Identifiable, Sendable {
    case desktop, tablet, phone

    public var id: String { rawValue }

    public var width: Double {
        switch self {
        case .desktop: return 1280
        case .tablet: return 820
        case .phone: return 390
        }
    }

    /// 縦横比の目安（高さ / 幅）。端末の画面の形に寄せる。
    public var aspect: Double {
        switch self {
        case .desktop: return 800.0 / 1280.0
        case .tablet: return 1180.0 / 820.0
        case .phone: return 844.0 / 390.0
        }
    }

    public var label: String {
        switch self {
        case .desktop: return "PC"
        case .tablet: return "タブレット"
        case .phone: return "スマホ"
        }
    }

    public var symbol: String {
        switch self {
        case .desktop: return "desktopcomputer"
        case .tablet: return "ipad"
        case .phone: return "iphone"
        }
    }

    /// 端末の枠の太さ（スマホだけ）。
    public var bezel: Double { self == .phone ? 10 : 0 }

    /// `available` の幅・`maxHeight` の高さに収める時の見え方。拡大はしない。
    public func layout(available: Double, maxHeight: Double) -> SiteViewportLayout {
        let inner = max(available - bezel * 2, 1)
        let fullHeight = width * aspect
        let byWidth = inner / width
        let byHeight = max(maxHeight - bezel * 2, 1) / fullHeight
        let scale = min(1, byWidth, byHeight)
        return SiteViewportLayout(scale: scale, frameWidth: (width * scale).rounded(.down),
                                  frameHeight: (fullHeight * scale).rounded(.down))
    }

    /// 欄が低くても、これより低くはしない（その分は欄をスクロールする）。
    public static let minimumPreviewHeight = 320.0

    /// 欄の幅いっぱいに収まる高さを上限とし、タブの中で枠に使える高さ `room` を超えない（`minimumPreviewHeight` は保つ）。
    public func heightLimit(available: Double, room: Double?) -> Double {
        let fill = layout(available: available, maxHeight: .infinity).frameHeight + bezel * 2
        guard let room, room.isFinite else { return fill }
        return min(fill, max(room, Self.minimumPreviewHeight))
    }
}

/// 縮めた後の大きさ（画面のポイント）と縮める率。
public struct SiteViewportLayout: Equatable, Sendable {
    public var scale: Double
    public var frameWidth: Double
    public var frameHeight: Double
}

/// 一覧のサムネイルのキャッシュ（`~/Library/Caches/claude-deck/site-thumbs/`）。書き出しのトップの更新時刻が変わった時だけ撮り直す。
public enum SiteThumbnails {
    /// 撮る時の大きさ（CSS ピクセル）と、保存する画像の幅。
    public static let captureWidth = 1280.0
    public static let captureHeight = 800.0
    public static let storedWidth = 320.0

    public static var directory: URL { DeckPaths.caches.appendingPathComponent("site-thumbs", isDirectory: true) }

    /// サイトと更新時刻ごとのファイル名。更新時刻が変われば名前が変わり、古いものは掃除の対象になる。
    public static func fileName(exportDir: String, modified: Date) -> String {
        "\(prefix(exportDir: exportDir))-\(Int64((modified.timeIntervalSince1970 * 1000).rounded())).png"
    }

    /// 同じサイトの古いサムネイルを見分ける頭の部分。
    public static func prefix(exportDir: String) -> String {
        let digest = SHA256.hash(data: Data((exportDir as NSString).standardizingPath.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 同じサイトの、今のもの以外のサムネイル。
    public static func stale(in names: [String], exportDir: String, keep: String) -> [String] {
        let head = prefix(exportDir: exportDir) + "-"
        return names.filter { $0.hasPrefix(head) && $0 != keep }
    }
}

/// プレビューの中で開いてよい行き先。外部のサイトへの遷移はそのまま許すが、手元のファイルやスクリプトの URL は開かない。
public enum SiteNavigationPolicy {
    public static func allows(_ url: URL?, mainFrame: Bool) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https", "about", "blob": return true
        // 埋め込みの画像や iframe の data: は通し、ページそのものを差し替える data: は通さない。
        case "data": return !mainFrame
        default: return false
        }
    }

    /// 遷移の扱い。
    public enum Decision: Equatable, Sendable {
        case allow
        case cancel
        /// プレビューでは開かず、既定のブラウザで開く。
        case openInBrowser(URL)
    }

    /// `origin`（開発サーバー）があればページの遷移は同じ origin に限り他はブラウザへ回す。無ければ `allows` のとおり。
    public static func decide(_ url: URL?, mainFrame: Bool, origin: URL?) -> Decision {
        guard let origin, mainFrame else { return allows(url, mainFrame: mainFrame) ? .allow : .cancel }
        if let url, sameOrigin(url, origin) { return .allow }
        if url?.scheme?.lowercased() == "about" { return .allow }
        if let external = browserURL(url) { return .openInBrowser(external) }
        return .cancel
    }

    /// スキーム・ホスト・ポート（省略時は既定のポート）が同じか。
    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let schemeA = a.scheme?.lowercased(), let schemeB = b.scheme?.lowercased(), schemeA == schemeB,
              let hostA = a.host?.lowercased(), let hostB = b.host?.lowercased(), hostA == hostB else { return false }
        return effectivePort(a, scheme: schemeA) == effectivePort(b, scheme: schemeB)
    }

    private static func effectivePort(_ url: URL, scheme: String) -> Int? {
        if let port = url.port { return port }
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// 「ブラウザで開く」に渡してよいもの（http / https だけ）。
    public static func browserURL(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}
