import Foundation

/// リンクを最後に開いた時刻（`link-visits.json`）。settings.json を開くたびに書き換えないよう、アプリの状態として別に持つ。
public struct LinkVisits: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// `key(projectID:url:)` → 最後に開いた時刻（epoch ミリ秒）。
    public var visits: [String: Double]

    public init(version: Int = Self.currentVersion, visits: [String: Double] = [:]) {
        self.version = version
        self.visits = visits
    }

    /// プロジェクト id と正規化した URL の組。開けない URL には無い。
    public static func key(projectID: UUID, url: String) -> String? {
        ProjectLinks.url(from: url).map { "\(projectID.uuidString)|\($0.absoluteString)" }
    }

    public func lastOpened(projectID: UUID, url: String) -> Date? {
        guard let key = Self.key(projectID: projectID, url: url), let millis = visits[key] else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    public mutating func record(projectID: UUID, url: String, at date: Date) {
        guard let key = Self.key(projectID: projectID, url: url) else { return }
        visits[key] = date.timeIntervalSince1970 * 1000
    }

    /// URL を編集した行の記録を新しい URL へ写す（新しい方に記録があればそのまま。古い方は次の起動の片付けで消える）。
    public mutating func carry(projectID: UUID, from oldURL: String, to newURL: String) {
        guard let from = Self.key(projectID: projectID, url: oldURL), let to = Self.key(projectID: projectID, url: newURL),
              from != to, let value = visits[from], visits[to] == nil else { return }
        visits[to] = value
    }

    /// 設定にあるリンクのキー。
    public static func keys(in projects: [ManagedProject]) -> Set<String> {
        Set(projects.flatMap { project in project.links.compactMap { key(projectID: project.id, url: $0.url) } })
    }

    /// 設定から消えたリンクの分を落とす。
    public func pruned(keeping keys: Set<String>) -> LinkVisits {
        LinkVisits(version: version, visits: visits.filter { keys.contains($0.key) })
    }
}

/// `link-visits.json` の読み書き（0600・置き換えで書く）。
public struct LinkVisitsFile: Sendable {
    public static let environmentKey = "CLAUDE_DECK_LINK_VISITS"

    public let url: URL
    public let restrictsDirectory: Bool

    public init(url: URL, restrictsDirectory: Bool? = nil) {
        self.url = url
        self.restrictsDirectory = restrictsDirectory
            ?? (url.deletingLastPathComponent().standardizedFileURL.path == DeckPaths.applicationSupport.standardizedFileURL.path)
    }

    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment[environmentKey], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return DeckPaths.applicationSupport.appendingPathComponent("link-visits.json")
    }

    /// 無い・壊れた・知らない版は空（記録が消えるだけで、次の記録で書き直す）。
    public func load() -> LinkVisits {
        guard let data = try? Data(contentsOf: url),
              let visits = try? JSONDecoder().decode(LinkVisits.self, from: data),
              visits.version == LinkVisits.currentVersion else { return LinkVisits() }
        return visits
    }

    public func save(_ visits: LinkVisits) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try SecureFile.write(try encoder.encode(visits), to: url, restrictDirectory: restrictsDirectory)
    }
}
