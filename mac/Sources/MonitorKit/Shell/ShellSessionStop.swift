import Foundation

/// シェルを止める手順の 1 歩。
public enum ShellStopStep: Equatable, Sendable {
    case hangup
    case terminate
    case kill
    case wait
    case finished
}

/// SIGHUP（対話シェルは SIGTERM を無視するが HUP で終わり、ジョブにも HUP を回す）→ SIGTERM → SIGKILL。
public enum ShellStopPlan {
    public static let hangupGrace: TimeInterval = 1
    public static let terminateGrace: TimeInterval = 1.5
    public static let killWait: TimeInterval = 1

    public static func next(alive: Bool, hangupAt: Date?, terminateAt: Date?, killAt: Date?, now: Date) -> ShellStopStep {
        guard alive else { return .finished }
        guard let hangupAt else { return .hangup }
        guard let terminateAt else { return now.timeIntervalSince(hangupAt) >= hangupGrace ? .terminate : .wait }
        guard let killAt else { return now.timeIntervalSince(terminateAt) >= terminateGrace ? .kill : .wait }
        return now.timeIntervalSince(killAt) >= killWait ? .finished : .wait
    }
}

/// PTY のシェルのセッション（シェルと、そこから起動したジョブ。ジョブは別のプロセスグループ）をまとめて止める。
/// 対象はシェルが先頭のセッションで、最初は同じ端末を持つもの、以降は最初に見つけたグループのものだけ（番号の使い回しで他人を止めないため）。
public final class ShellSessionStop: @unchecked Sendable {
    public let leader: pid_t
    private let lock = NSLock()
    private var groups: Set<pid_t>
    private var hangupAt: Date?
    private var terminateAt: Date?
    private var killAt: Date?
    private var done = false

    /// 端末（master）を閉じる前に呼ぶ。セッションの中のプロセスグループを集め、SIGHUP を送る。
    public init(leader: pid_t, master: Int32, now: Date = Date()) {
        self.leader = leader
        let members = Self.sessionProcesses(leader: leader)
        if let tty = master >= 0 ? Self.ttyDevice(master: master) : nil {
            groups = Set(members.filter { $0.tty == tty }.map(\.group))
        } else {
            // 端末で確かめられない時は、先頭がまだ自分の子である間だけ止める。
            groups = Self.isOwnChild(leader) ? Set(members.map(\.group)) : []
        }
        _ = advance(now: now)
    }

    /// 手順を 1 つ進める。止め切ったら（またはあきらめたら）true。
    @discardableResult
    public func advance(now: Date) -> Bool {
        lock.withLock {
            guard !done else { return true }
            let alive = !groups.isEmpty && !livingGroups().isEmpty
            switch ShellStopPlan.next(alive: alive, hangupAt: hangupAt, terminateAt: terminateAt, killAt: killAt, now: now) {
            case .hangup:
                signalGroups(SIGHUP)
                hangupAt = now
            case .terminate:
                signalGroups(SIGTERM)
                // 一時停止中のジョブにも届くよう動かす。
                signalGroups(SIGCONT)
                terminateAt = now
            case .kill:
                signalGroups(SIGKILL)
                killAt = now
            case .wait:
                break
            case .finished:
                done = true
            }
            return done
        }
    }

    public var isFinished: Bool { lock.withLock { done } }

    /// 止め切るまで待つ（ルームを閉じた時）。
    public func finish() async {
        while !advance(now: Date()) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// アプリの終了時。全部が止まるか猶予が尽きるまで、このスレッドで待つ。
    public static func finishAllBlocking(_ stops: [ShellSessionStop]) {
        ProcessGroup.advanceAllBlocking(stops.map { stop in { stop.advance(now: $0) } })
    }

    /// 最初に集めたグループのうち、まだセッションの中に生きているもの。
    private func livingGroups() -> Set<pid_t> {
        Set(Self.sessionProcesses(leader: leader).map(\.group)).intersection(groups)
    }

    private func signalGroups(_ signal: Int32) {
        for group in livingGroups() { killpg(group, signal) }
    }

    // MARK: - プロセスの一覧

    struct Member: Equatable {
        var pid: pid_t
        var group: pid_t
        var tty: dev_t
    }

    /// 自分の uid のプロセスのうち、`leader` が先頭のセッションにいて終わっていないもの。
    static func sessionProcesses(leader: pid_t) -> [Member] {
        guard leader > 1, leader != getpid() else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // 測った後に増えても入るよう、少し余らせる。
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / stride).compactMap { info in
            let pid = info.kp_proc.p_pid
            guard pid > 1, info.kp_proc.p_stat != SZOMB, getsid(pid) == leader else { return nil }
            return Member(pid: pid, group: info.kp_eproc.e_pgid, tty: info.kp_eproc.e_tdev)
        }
    }

    static func isOwnChild(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_ppid == UInt32(getpid())
    }

    /// master に対応する端末の device 番号。
    static func ttyDevice(master: Int32) -> dev_t? {
        guard let name = ptsname(master) else { return nil }
        var info = stat()
        guard stat(name, &info) == 0 else { return nil }
        return info.st_rdev
    }
}
