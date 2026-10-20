import Foundation
import Darwin

/// PTY でホストする子プロセスの fd の受け渡しと、アプリの終了時の止め方。
public enum ChildProcessControl {
    /// exec で閉じる印を付ける。付けないと後から起動した子が先の子の PTY の master を持ち、先の子に切断が届かなくなる。
    @discardableResult
    public static func setCloseOnExec(_ fd: Int32) -> Bool {
        guard fd >= 0 else { return false }
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0
    }

    public static func isCloseOnExec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && flags & FD_CLOEXEC != 0
    }

    /// 終了時に子の後片付けを待つ上限（終了を長く引き止めない）。
    public static let hangUpGrace: TimeInterval = 3

    /// 全部へ同時に SIGHUP を送り、終わるまで `grace` まで待つ。終わらなかった pid を返す（残りはアプリの終了で master が閉じて切断が届く）。
    @discardableResult
    public static func hangUp(_ pids: [Int32], grace: TimeInterval = hangUpGrace, pollInterval: TimeInterval = 0.05,
                              inspect: (Int32) -> ProcessFacts? = { ProcessFacts.inspect(pid: $0) },
                              signal: (Int32, Int32) -> Void = { _ = kill($0, $1) }) -> [Int32] {
        var remaining: [Int32: ProcessFacts] = [:]
        for pid in Set(pids) where pid > 1 {
            if let facts = inspect(pid), !facts.isZombie { remaining[pid] = facts }
        }
        for pid in remaining.keys.sorted() { signal(pid, SIGHUP) }
        let deadline = Date().addingTimeInterval(grace)
        while true {
            // 刈り取られる前のゾンビや、別物に替わった pid は終わったとみなす。
            remaining = remaining.filter { pid, original in
                guard let current = inspect(pid), !current.isZombie else { return false }
                return current.isSameProcess(as: original)
            }
            if remaining.isEmpty || Date() >= deadline { break }
            usleep(useconds_t(pollInterval * 1_000_000))
        }
        return remaining.keys.sorted()
    }
}
