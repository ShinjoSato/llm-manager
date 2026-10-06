import Foundation

/// 上限到達の記録。起動直後は usage.json が古いことがあるので、前回覚えた到達をリセット時刻まで持ち越す。
public struct LimitStateRecord: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// 到達が解ける時刻（epoch ミリ秒）。
    public var until: Double
    /// 到達の理由（画面に出す文）。
    public var reason: String?

    public init(version: Int = Self.currentVersion, until: Date, reason: String? = nil) {
        self.version = version
        self.until = until.timeIntervalSince1970 * 1000
        self.reason = reason
    }

    public var untilDate: Date { Date(timeIntervalSince1970: until / 1000) }
}

/// `limit-state.json` の読み書き（0600・置き換えで書く）。
public struct LimitStateFile: Sendable {
    public static let environmentKey = "CLAUDE_DECK_LIMIT_STATE"

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
        return DeckPaths.applicationSupport.appendingPathComponent("limit-state.json")
    }

    /// 無い・壊れた・知らない版・既に解けた記録は nil。
    public func load(now: Date = Date()) -> LimitStateRecord? {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(LimitStateRecord.self, from: data),
              record.version == LimitStateRecord.currentVersion,
              record.untilDate > now else { return nil }
        return record
    }

    /// 到達中なら書き、解けていれば消す。
    public func save(_ record: LimitStateRecord?) throws {
        guard let record else {
            if unlink(url.path) != 0, errno != ENOENT { throw SecureFile.Failure.writeFailed(url.lastPathComponent) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFile.write(try encoder.encode(record), to: url, restrictDirectory: restrictsDirectory)
    }
}

extension UsageLimitLatch {
    /// 前回覚えた到達から始める。新しい残量が届けばそちらで上書き・解除される。
    public init(restoring record: LimitStateRecord?, now: Date = Date()) {
        self.init()
        if let record, record.untilDate > now { restore(until: record.untilDate) }
    }

    /// 書き残す記録（到達中でなければ nil）。
    public var record: LimitStateRecord? {
        until.map { LimitStateRecord(until: $0, reason: hit?.reason) }
    }
}

/// 上限で止めたセッションの知らせ。続けて止まった分を 1 回の確認にまとめる。
public enum LimitAlertText {
    public static func message(names: [String]) -> String {
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        let list = unique.prefix(3).map { "「\($0)」" }.joined()
        let more = unique.count > 3 ? " ほか \(unique.count - 3) 件" : ""
        return "\(list)\(more)のセッションを強制終了しました。枠がリセットされるまでお待ちください（一覧の上の帯から再開できます）。（API 課金は発生しません）"
    }
}
