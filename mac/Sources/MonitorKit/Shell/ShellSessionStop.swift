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
    /// 一覧を取れない時に待ち続けない上限。
    public static let giveUpAfter: TimeInterval = hangupGrace + terminateGrace + killWait + 2

    public static func next(alive: Bool, hangupAt: Date?, terminateAt: Date?, killAt: Date?, now: Date) -> ShellStopStep {
        guard alive else { return .finished }
        guard let hangupAt else { return .hangup }
        guard let terminateAt else { return now.timeIntervalSince(hangupAt) >= hangupGrace ? .terminate : .wait }
        guard let killAt else { return now.timeIntervalSince(terminateAt) >= terminateGrace ? .kill : .wait }
        return now.timeIntervalSince(killAt) >= killWait ? .finished : .wait
    }
}

/// PTY のシェルのセッション（シェルと、そこから起動したジョブ。ジョブは別のプロセスグループ）をまとめて止める。
/// 対象はシェルが先頭のセッションのうち、同じ端末を持つものか、動いている間に記録したグループのもの（番号の使い回しで他人を止めないため）。
public final class ShellSessionStop: @unchecked Sendable {
    public let leader: pid_t
    private let lock = NSLock()
    private let reapLeader: Bool
    private let startedAt: Date
    private var groups: Set<pid_t>
    private var hangupAt: Date?
    private var terminateAt: Date?
    private var killAt: Date?
    private var done = false

    /// 端末（master）を閉じる前に呼ぶ。対象のグループを集め、SIGHUP を送る。
    /// `knownGroups` は動いている間に記録したもの（先頭が終わると端末の紐づけが外れるため）。`reapLeader` は先頭をまだ誰も刈り取っていない時。
    public init(leader: pid_t, master: Int32, knownGroups: Set<pid_t> = [], reapLeader: Bool = false, now: Date = Date()) {
        self.leader = leader
        self.reapLeader = reapLeader
        startedAt = now
        let tty = master >= 0 ? Self.ttyDevice(master: master) : nil
        var members: [Member]?
        for _ in 0..<3 where members == nil { members = Self.sessionProcesses(leader: leader) }
        if let members {
            groups = Set(members.filter { member in
                (tty != nil && member.tty == tty) || knownGroups.contains(member.group)
            }.map(\.group))
            // 端末で確かめられない時は、先頭がまだ自分の子である間だけ全体を止める。
            if tty == nil, Self.isOwnChild(leader) { groups.formUnion(members.map(\.group)) }
        } else {
            groups = knownGroups
            if Self.isOwnChild(leader) { groups.insert(leader) }
        }
        _ = advance(now: now)
    }

    /// 手順を 1 つ進める。止め切ったら（またはあきらめたら）true。
    @discardableResult
    public func advance(now: Date) -> Bool {
        lock.withLock {
            guard !done else { return true }
            guard let living = livingGroups() else {
                // 一覧を取れなかった。次の周回でやり直し、上限を過ぎたらあきらめる。
                if now.timeIntervalSince(startedAt) >= ShellStopPlan.giveUpAfter { finish() }
                return done
            }
            switch ShellStopPlan.next(alive: !living.isEmpty, hangupAt: hangupAt, terminateAt: terminateAt, killAt: killAt, now: now) {
            case .hangup:
                signal(living, SIGHUP)
                hangupAt = now
            case .terminate:
                signal(living, SIGTERM)
                // 一時停止中のジョブにも届くよう動かす。
                signal(living, SIGCONT)
                terminateAt = now
            case .kill:
                signal(living, SIGKILL)
                killAt = now
            case .wait:
                break
            case .finished:
                finish()
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

    private func finish() {
        done = true
        guard reapLeader else { return }
        // SwiftTerm は terminate で終了の見張りをやめるので、先頭のゾンビはこちらで刈り取る。
        var status: Int32 = 0
        guard waitpid(leader, &status, WNOHANG) == 0 else { return }
        let leader = leader
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(leader, &status, 0)
        }
    }

    /// 集めたグループのうち、まだセッションの中に生きているもの（一覧を取れなければ nil）。
    private func livingGroups() -> Set<pid_t>? {
        guard !groups.isEmpty else { return [] }
        return Self.sessionProcesses(leader: leader).map { Set($0.map(\.group)).intersection(groups) }
    }

    private func signal(_ targets: Set<pid_t>, _ signal: Int32) {
        for group in targets { killpg(group, signal) }
    }

    // MARK: - プロセスの一覧

    struct Member: Equatable {
        var pid: pid_t
        var group: pid_t
        var tty: dev_t
    }

    /// 動いているシェルのセッションのうち、同じ端末を持つグループ（記録用。一覧を取れなければ nil）。
    public static func currentGroups(leader: pid_t, master: Int32) -> Set<pid_t>? {
        guard master >= 0, let tty = ttyDevice(master: master) else { return nil }
        return sessionProcesses(leader: leader, tty: tty).map { Set($0.map(\.group)) }
    }

    /// 自分の uid のプロセスのうち、`leader` が先頭のセッションにいて終わっていないもの（`tty` があればその端末のものだけ）。一覧を取れなければ nil。
    static func sessionProcesses(leader: pid_t, tty: dev_t? = nil) -> [Member]? {
        guard leader > 1, leader != getpid() else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        let stride = MemoryLayout<kinfo_proc>.stride
        // 測った後に増えても入るよう、少し余らせる。
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return nil }
        return procs.prefix(size / stride).compactMap { info in
            let pid = info.kp_proc.p_pid
            guard pid > 1, info.kp_proc.p_stat != SZOMB else { return nil }
            if let tty, info.kp_eproc.e_tdev != tty { return nil }
            guard getsid(pid) == leader else { return nil }
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
