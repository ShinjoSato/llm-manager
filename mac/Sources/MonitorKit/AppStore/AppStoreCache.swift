import Foundation

/// 取った結果を少しの間だけ覚える（タブの行き来で取り直さない）。期限を過ぎたものは返さない。
public struct AppStoreCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    /// 取得から 10 分。自動では取り直さず、次に開いた時か「再読み込み」で取る。
    public static var defaultLifetime: TimeInterval { 10 * 60 }

    public struct Entry: Sendable {
        public var value: Value
        public var fetchedAt: Date
    }

    public let lifetime: TimeInterval
    private var entries: [Key: Entry] = [:]

    public init(lifetime: TimeInterval = defaultLifetime) {
        self.lifetime = lifetime
    }

    public func fresh(_ key: Key, now: Date = Date()) -> Entry? {
        guard let entry = entries[key], now.timeIntervalSince(entry.fetchedAt) < lifetime, entry.fetchedAt <= now else { return nil }
        return entry
    }

    public mutating func store(_ value: Value, for key: Key, at date: Date = Date()) {
        entries[key] = Entry(value: value, fetchedAt: date)
    }

    public mutating func remove(_ key: Key) {
        entries[key] = nil
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
