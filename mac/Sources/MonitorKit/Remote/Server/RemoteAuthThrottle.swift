import Foundation

/// 認証・ペアリングの失敗の回数制限（接続元のアドレスごと）。どのスレッドからでも呼べる。
public final class RemoteAuthThrottle: @unchecked Sendable {
    /// この時間内に `maxFailures` 回失敗したら、同じ時間だけ塞ぐ。
    public let window: TimeInterval
    public let maxFailures: Int
    /// 覚えておく接続元の上限（多数のアドレスから叩かれても膨らませない）。
    static let maxTracked = 256

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var failures: [String: [Date]] = [:]
    private var blockedUntil: [String: Date] = [:]

    public init(window: TimeInterval = 300, maxFailures: Int = 10, now: @escaping @Sendable () -> Date = { Date() }) {
        self.window = window
        self.maxFailures = maxFailures
        self.now = now
    }

    public func isBlocked(_ address: String) -> Bool {
        lock.withLock {
            guard let until = blockedUntil[address] else { return false }
            if until > now() { return true }
            blockedUntil[address] = nil
            return false
        }
    }

    public func recordFailure(_ address: String) {
        lock.withLock {
            let at = now()
            var list = (failures[address] ?? []).filter { at.timeIntervalSince($0) < window }
            list.append(at)
            if list.count >= maxFailures {
                blockedUntil[address] = at.addingTimeInterval(window)
                list = []
            }
            failures[address] = list.isEmpty ? nil : list
            if failures.count + blockedUntil.count > Self.maxTracked { pruneLocked(at) }
        }
    }

    public func recordSuccess(_ address: String) {
        lock.withLock { failures[address] = nil }
    }

    private func pruneLocked(_ at: Date) {
        failures = failures.filter { $0.value.contains { at.timeIntervalSince($0) < window } }
        blockedUntil = blockedUntil.filter { $0.value > at }
        // それでも多ければ古い失敗から捨てる（塞いでいる分は残す）。
        if failures.count + blockedUntil.count > Self.maxTracked {
            let keep = max(0, Self.maxTracked - blockedUntil.count)
            let sorted = failures.sorted { ($0.value.last ?? .distantPast) > ($1.value.last ?? .distantPast) }
            failures = Dictionary(uniqueKeysWithValues: sorted.prefix(keep).map { ($0.key, $0.value) })
        }
    }
}
