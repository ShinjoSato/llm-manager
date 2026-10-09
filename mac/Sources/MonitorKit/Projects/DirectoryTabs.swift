import Foundation

/// ディレクトリの詳細の本文を切り替えるタブ（並びはこの順）。
public enum DirectoryTab: String, CaseIterable, Identifiable, Sendable {
    case site
    case images
    case iosPreviews
    case links
    case threads

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .site: return "サイト"
        case .images: return "画像"
        case .iosPreviews: return "iPhone"
        case .links: return "リンク"
        case .threads: return "スレッド"
        }
    }

    public var symbol: String {
        switch self {
        case .site: return "globe"
        case .images: return "photo.on.rectangle"
        case .iosPreviews: return "iphone"
        case .links: return "link"
        case .threads: return "bubble.left.and.bubble.right"
        }
    }
}

/// 出せるタブと、開くタブの選び方。
public enum DirectoryTabs {
    /// サイトの有無が分からない間（nil）は出しておく。後から足すと並びがずれて押し間違えるため、消す向きにだけ動かす。
    public static func available(hasSite: Bool?, hasXcodeProject: Bool) -> [DirectoryTab] {
        DirectoryTab.allCases.filter { tab in
            switch tab {
            case .site: return hasSite ?? true
            case .iosPreviews: return hasXcodeProject
            case .images, .links, .threads: return true
            }
        }
    }

    /// 覚えたタブが今も出せればそれ、出せなければ先頭。
    public static func resolve(remembered: DirectoryTab?, available: [DirectoryTab]) -> DirectoryTab {
        if let remembered, available.contains(remembered) { return remembered }
        return available.first ?? .images
    }

    /// 設定の場所が使えない時も、理由を見せるためにサイトのタブは出す。
    public static func hasSite(_ lookup: SiteLookup) -> Bool {
        lookup.location != nil || lookup.problem != nil
    }
}

/// 最後に開いたタブをプロジェクトごとに覚える。
public struct DirectoryTabMemory {
    public static let keyPrefix = "directory.tab."

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func key(for projectID: UUID) -> String { keyPrefix + projectID.uuidString }

    /// 知らない値（古い版や手で書いたもの）は覚えていないものとして扱う。
    public func remembered(for projectID: UUID) -> DirectoryTab? {
        defaults.string(forKey: Self.key(for: projectID)).flatMap(DirectoryTab.init(rawValue:))
    }

    public func remember(_ tab: DirectoryTab, for projectID: UUID) {
        defaults.set(tab.rawValue, forKey: Self.key(for: projectID))
    }
}
