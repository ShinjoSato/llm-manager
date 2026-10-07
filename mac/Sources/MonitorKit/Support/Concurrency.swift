import Foundation

/// 一度だけ通す印（完了・失敗・時間切れのうち先に来た 1 回だけを通すため）。
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool { lock.withLock { defer { used = true }; return !used } }
}

/// `interval` ごとに `body` を回す。持ち主が解放されるか取り消されたら抜ける。
func repeatingTask<Owner: AnyObject & Sendable>(every interval: Duration, owner: Owner,
                                                 _ body: @escaping @Sendable (Owner) async -> Void) -> Task<Void, Never> {
    Task { [weak owner] in
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard let owner, !Task.isCancelled else { return }
            await body(owner)
        }
    }
}
