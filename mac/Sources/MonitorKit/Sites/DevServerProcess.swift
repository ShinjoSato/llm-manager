import Foundation

/// 新しいプロセスグループで起動した子（開発サーバー）。出力と終了を知らせ、止める時はグループごと止める。
/// 先頭のプロセスはグループが止まり切るまで刈り取らない（番号が使い回されず、グループが自分の子のものだと言い切れるため）。
public final class DevServerProcess: @unchecked Sendable {
    public let pid: pid_t
    /// 受け手が詰まっている間にため込む出力の上限（超えたら古い方から捨てる）。
    static let maxPendingOutput = 256 * 1024

    private let lock = NSLock()
    private var exited: DevServerExit?
    private var reaped = false
    private var termSentAt: Date?
    private var killSentAt: Date?
    private var stopTask: Task<Void, Never>?
    private var exitSource: DispatchSourceProcess?
    private var output: FileHandle?
    private let deliveryQueue: DispatchQueue
    private let onOutput: @Sendable (Data) -> Void
    private let onExit: @Sendable (DevServerExit) -> Void
    private var exitReported = false
    private var pendingOutput = Data()
    private var flushScheduled = false

    private init(pid: pid_t, deliveryQueue: DispatchQueue, onOutput: @escaping @Sendable (Data) -> Void,
                 onExit: @escaping @Sendable (DevServerExit) -> Void) {
        self.pid = pid
        self.deliveryQueue = deliveryQueue
        self.onOutput = onOutput
        self.onExit = onExit
    }

    /// 起動する。stdin は /dev/null、stdout と stderr は 1 本にまとめて `onOutput` へ。
    /// `onOutput` と `onExit` は `deliveryQueue`（直列のキュー）で、届いた順に呼ぶ。
    public static func spawn(executable: String, arguments: [String], environment: [String: String], directory: String,
                             deliveryQueue: DispatchQueue = .main,
                             onOutput: @escaping @Sendable (Data) -> Void,
                             onExit: @escaping @Sendable (DevServerExit) -> Void) throws -> DevServerProcess {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw PosixSpawnError.failed(errno) }
        let (readFD, writeFD) = (fds[0], fds[1])
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // 新しいグループにして、止める時に孫（npm → node 等）までまとめて届くようにする。親の fd は持ち込ませない。
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attr, &empty)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        close(writeFD)
        guard rc == 0 else {
            close(readFD)
            throw PosixSpawnError.failed(rc)
        }

        let process = DevServerProcess(pid: pid, deliveryQueue: deliveryQueue, onOutput: onOutput, onExit: onExit)
        let handle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                process.enqueue(data)
            }
        }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        // 持ち主が手放しても、刈り取るまでは自分を保つ（ゾンビを残さない）。刈り取りで source を外して輪を切る。
        source.setEventHandler { process.leaderExited() }
        process.lock.withLock {
            process.output = handle
            process.exitSource = source
        }
        source.resume()
        // 登録より先に終わっていた時の取りこぼしを拾う。
        if process.peekExit() != nil { process.leaderExited() }
        return process
    }

    /// 先頭のプロセスが終わったか（刈り取らずに見る）。
    private func peekExit() -> DevServerExit? {
        var info = siginfo_t()
        guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid else { return nil }
        return DevServerExit(siginfoCode: info.si_code, status: info.si_status)
    }

    /// 受け取った出力をためて、受け手のキューへまとめて渡す（届いた順のまま、詰まっても際限なくはためない）。
    private func enqueue(_ data: Data) {
        let schedule = lock.withLock { () -> Bool in
            pendingOutput.append(data)
            if pendingOutput.count > Self.maxPendingOutput {
                pendingOutput = Self.trimmedOutput(pendingOutput, limit: Self.maxPendingOutput)
            }
            guard !flushScheduled else { return false }
            flushScheduled = true
            return true
        }
        if schedule { deliveryQueue.async { [self] in flushOutput() } }
    }

    private func flushOutput() {
        let data = lock.withLock { () -> Data in
            flushScheduled = false
            defer { pendingOutput = Data() }
            return pendingOutput
        }
        if !data.isEmpty { onOutput(data) }
    }

    /// 古い方を捨てて `limit` 以下にする。行の途中から始まらないよう、残す側の最初の改行の後ろから残す。
    static func trimmedOutput(_ data: Data, limit: Int) -> Data {
        guard data.count > limit else { return data }
        let tail = data.suffix(limit)
        if let newline = tail.firstIndex(of: 0x0A), newline < tail.endIndex - 1 {
            return Data(tail[(newline + 1)...])
        }
        return Data(tail)
    }

    private func leaderExited() {
        guard let exit = peekExit() else { return }
        let report = lock.withLock { () -> Bool in
            exited = exit
            exitSource?.cancel()
            exitSource = nil
            defer { exitReported = true }
            return !exitReported
        }
        guard report else { return }
        // 残った孫を片付けてから刈り取る。
        Task { await self.stop() }
        // 出力の最後を読み切ってから、出力と同じキューで知らせる（理由の判定に使うため）。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) { [self] in
            deliveryQueue.async { [self] in
                flushOutput()
                onExit(exit)
            }
        }
    }

    /// 先頭のプロセスが終わっていれば、その終わり方。
    public var exitStatus: DevServerExit? { lock.withLock { exited } }

    /// グループを止め切って（またはあきらめて）先頭を刈り取ったか。
    public var isFinished: Bool { lock.withLock { reaped } }

    /// グループごと止める（SIGTERM → 猶予の後 SIGKILL）。何度呼んでも 1 回分の手順になる。
    public func stop() async {
        let task = lock.withLock { () -> Task<Void, Never> in
            if let stopTask { return stopTask }
            let task = Task.detached(priority: .utility) { [self] in
                while !advance(now: Date()) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            stopTask = task
            return task
        }
        await task.value
    }

    /// アプリの終了時。まとめて SIGTERM を送り、全部が止まるか猶予が尽きるまでこのスレッドで待つ。
    public static func stopAllBlocking(_ processes: [DevServerProcess]) {
        var remaining = processes
        while !remaining.isEmpty {
            let now = Date()
            remaining.removeAll { $0.advance(now: now) }
            if !remaining.isEmpty { usleep(50_000) }
        }
    }

    /// 手順を 1 つ進める。終わったら true。
    private func advance(now: Date) -> Bool {
        lock.withLock {
            let owns = ownsGroupLocked()
            // 一覧を取れない時は、先頭が生きていれば残っているとみなして手順を続ける。
            let alive = owns && (Self.groupAlive(pid) ?? (peekExit() == nil))
            let step = DevServerStopPlan.next(ownsGroup: owns, groupAlive: alive, termSentAt: termSentAt,
                                              killSentAt: killSentAt, now: now)
            switch step {
            case .terminate:
                killpg(pid, SIGTERM)
                termSentAt = now
                return false
            case .kill:
                killpg(pid, SIGKILL)
                killSentAt = now
                return false
            case .wait:
                return false
            case .finished:
                reapLocked()
                return true
            }
        }
    }

    /// 刈り取る前で、今も自分の子か（終わっていても刈り取っていなければ番号は使い回されない）。
    private func ownsGroupLocked() -> Bool {
        guard !reaped else { return false }
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0
    }

    private func reapLocked() {
        guard !reaped else { return }
        reaped = true
        exitSource?.cancel()
        exitSource = nil
        var status: Int32 = 0
        // SIGKILL の後もまだ終わっていなければ、終わるのを待って刈り取る（ゾンビを残さない）。
        guard waitpid(pid, &status, WNOHANG) == 0 else { return }
        let pid = pid
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    /// グループに終わっていないプロセスが残っているか（一覧を取れなければ nil）。
    static func groupAlive(_ pgid: pid_t) -> Bool? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return nil }
        guard size > 0 else { return false }
        let stride = MemoryLayout<kinfo_proc>.stride
        // 測った後に増えても入るよう、少し余らせる。
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 8)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return nil }
        return procs.prefix(size / stride).contains { $0.kp_eproc.e_pgid == pgid && $0.kp_proc.p_stat != SZOMB }
    }
}
