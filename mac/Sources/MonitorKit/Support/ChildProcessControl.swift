import Foundation
import Darwin

/// PTY でホストする子プロセスの fd の受け渡しと、アプリの終了時の止め方。
public enum ChildProcessControl {
    private static let spawnLock = NSLock()

    /// fd を作ってから CLOEXEC を付けるまでの間に forkpty が割り込むと子に漏れるので、作る側も forkpty 側もこのロックで囲む。
    public static func withSpawnLock<T>(_ body: () throws -> T) rethrows -> T {
        spawnLock.lock()
        defer { spawnLock.unlock() }
        return try body()
    }

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

    /// 両端に CLOEXEC を付けたパイプ（子へ渡す側も posix_spawn の dup2 で印が外れるので、子の標準入出力には今までどおり届く）。
    public static func makePipe() -> (read: Int32, write: Int32)? {
        withSpawnLock {
            var fds: [Int32] = [0, 0]
            guard Darwin.pipe(&fds) == 0 else { return nil }
            fds.forEach { setCloseOnExec($0) }
            return (fds[0], fds[1])
        }
    }

    /// Foundation の Pipe は CLOEXEC を付けないので、作る時に付ける。
    public static func makeFoundationPipe() -> Pipe {
        withSpawnLock {
            let pipe = Pipe()
            setCloseOnExec(pipe.fileHandleForReading.fileDescriptor)
            setCloseOnExec(pipe.fileHandleForWriting.fileDescriptor)
            return pipe
        }
    }

    public static func makeSocket(domain: Int32, type: Int32, protocol proto: Int32 = 0) -> Int32 {
        withSpawnLock {
            let fd = socket(domain, type, proto)
            if fd >= 0 { setCloseOnExec(fd) }
            return fd
        }
    }

    /// 終了時に子の後片付けを待つ上限（終了を長く引き止めない）。
    public static let hangUpGrace: TimeInterval = 3

    /// SIGHUP を送る相手。起動時刻が合う時だけ送る（pid が別物に替わっていたら撃たない）。
    public struct Target: Sendable, Equatable {
        public var pid: Int32
        public var startedAt: Date

        public init(pid: Int32, startedAt: Date) {
            self.pid = pid
            self.startedAt = startedAt
        }
    }

    /// SIGHUP を送った後の待ち。
    public struct PendingHangUp {
        public private(set) var remaining: [Int32: ProcessFacts]
        public let deadline: Date
        let inspect: (Int32) -> ProcessFacts?

        /// 締め切りまで終わるのを待ち、終わらなかった pid を返す（残りはアプリの終了で master が閉じて切断が届く）。
        public mutating func waitForExit(pollInterval: TimeInterval = 0.05) -> [Int32] {
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

    /// 全部へ同時に SIGHUP を送る（待たない）。締め切りは送った時から `grace`。
    public static func sendHangUp(_ targets: [Target], grace: TimeInterval = hangUpGrace,
                                  inspect: @escaping (Int32) -> ProcessFacts? = { ProcessFacts.inspect(pid: $0) },
                                  signal: (Int32, Int32) -> Void = { _ = kill($0, $1) }) -> PendingHangUp {
        var remaining: [Int32: ProcessFacts] = [:]
        for target in targets where target.pid > 1 {
            guard let facts = inspect(target.pid), !facts.isZombie,
                  abs(facts.startedAt.timeIntervalSince(target.startedAt)) < 1 else { continue }
            remaining[target.pid] = facts
        }
        for pid in remaining.keys.sorted() { signal(pid, SIGHUP) }
        return PendingHangUp(remaining: remaining, deadline: Date().addingTimeInterval(grace), inspect: inspect)
    }

    /// 送って待つまでを続けて行う。終わらなかった pid を返す。
    @discardableResult
    public static func hangUp(_ targets: [Target], grace: TimeInterval = hangUpGrace, pollInterval: TimeInterval = 0.05,
                              inspect: @escaping (Int32) -> ProcessFacts? = { ProcessFacts.inspect(pid: $0) },
                              signal: (Int32, Int32) -> Void = { _ = kill($0, $1) }) -> [Int32] {
        var pending = sendHangUp(targets, grace: grace, inspect: inspect, signal: signal)
        return pending.waitForExit(pollInterval: pollInterval)
    }
}
