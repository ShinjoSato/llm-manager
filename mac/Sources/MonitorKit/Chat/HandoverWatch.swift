import Foundation
import Darwin

/// 引き継ぐ相手（止めるか、終わるのを待つ claude）。
public struct HandoverTarget: Sendable, Equatable {
    public var pid: Int32
    public var sessionId: String
    public var source: SessionHandover.Source
    /// 確かめた時の素性。pid が再利用されて別物に替わったら「終わった」とみなすため。
    public var original: ProcessFacts

    public init(pid: Int32, sessionId: String, source: SessionHandover.Source, original: ProcessFacts) {
        self.pid = pid
        self.sessionId = sessionId
        self.source = source
        self.original = original
    }
}

extension SessionHandover {
    public enum TargetCheck: Sendable, Equatable {
        case ok(HandoverTarget)
        case notRunning
        case refused(String)
    }

    /// 待つ・止める相手として確かめる（`verify` と同じ条件）。
    public static func checkTarget(pid: Int32, sessionId: String, record: ClaudeSessionRecord?, facts: ProcessFacts?,
                                   ownUid: uid_t) -> TargetCheck {
        switch verify(pid: pid, sessionId: sessionId, record: record, facts: facts, ownUid: ownUid) {
        case .notRunning: return .notRunning
        case .refused(let reason): return .refused(reason)
        case .ok:
            guard let facts, let record,
                  case .supported(let source) = checkSource(entrypoint: record.entrypoint, kind: record.kind,
                                                            executablePath: facts.executablePath) else {
                return .refused("起動元を確かめられないため引き継げません")
            }
            return .ok(HandoverTarget(pid: pid, sessionId: sessionId, source: source, original: facts))
        }
    }

    /// 相手が確かめた時のその claude のまま動いているか。
    public static func isAlive(_ target: HandoverTarget, inspect: (Int32) -> ProcessFacts?) -> Bool {
        guard let current = inspect(target.pid), !current.isZombie else { return false }
        return current.isSameProcess(as: target.original)
    }
}

/// VS Code のタブが閉じられて claude が終わるのを待ち、同じ会話の claude が他に無くなったら再開する。
public struct HandoverCloseWait: Sendable, Equatable {
    /// 終わった直後に拡張が同じ会話を起動し直しても二重に動かさないよう、終わった状態が続くのを少し待つ。
    public static let settle: TimeInterval = 1

    public enum Phase: Sendable, Equatable {
        /// 元の claude が動いている（タブが閉じられるのを待っている）。
        case waitingForClose
        /// 元の claude は終わったが、同じ会話を別の claude が動かしている。
        case waitingForOther(Int32)
        /// 終わったのを確かめている。
        case settling
    }

    public enum Step: Sendable, Equatable {
        case wait
        case resume
        case cancel(CancelReason)
    }

    public enum CancelReason: Sendable, Equatable {
        /// Max 枠の上限に達した（再開してもすぐ止められる）。
        case limit
        /// 同じ会話をこのアプリがもうホストしている。
        case alreadyHosted
    }

    public struct Observation: Sendable, Equatable {
        public var originalAlive: Bool
        /// 元の claude 以外で同じ会話を動かしている pid。
        public var otherPid: Int32?
        public var limitReached: Bool
        /// 終了の確認中・保留中（終わるつもりの時に新しく起動しない）。
        public var holding: Bool
        public var alreadyHosted: Bool

        public init(originalAlive: Bool, otherPid: Int32? = nil, limitReached: Bool = false, holding: Bool = false,
                    alreadyHosted: Bool = false) {
            self.originalAlive = originalAlive
            self.otherPid = otherPid
            self.limitReached = limitReached
            self.holding = holding
            self.alreadyHosted = alreadyHosted
        }
    }

    public private(set) var phase: Phase = .waitingForClose
    private var goneSince: Date?

    public init() {}

    public mutating func step(_ observation: Observation, now: Date) -> Step {
        if observation.alreadyHosted { return .cancel(.alreadyHosted) }
        if observation.limitReached { return .cancel(.limit) }
        if observation.originalAlive {
            phase = .waitingForClose
            goneSince = nil
            return .wait
        }
        if let other = observation.otherPid {
            phase = .waitingForOther(other)
            goneSince = nil
            return .wait
        }
        phase = .settling
        let since = goneSince ?? now
        goneSince = since
        if observation.holding { return .wait }
        return now.timeIntervalSince(since) >= Self.settle ? .resume : .wait
    }

    /// 今の様子を読む（上限・終了の確認中・ホスト中かは呼ぶ側が渡す）。
    public static func observe(_ target: HandoverTarget, records: [ClaudeSessionRecord], inspect: (Int32) -> ProcessFacts?,
                               limitReached: Bool, holding: Bool, alreadyHosted: Bool) -> Observation {
        let alive = SessionHandover.isAlive(target, inspect: inspect)
        let other = SessionHandover.liveRecords(sessionId: target.sessionId, records: records,
                                                excluding: alive ? [target.pid] : [], inspect: inspect).first?.pid
        return Observation(originalAlive: alive, otherPid: other, limitReached: limitReached, holding: holding,
                           alreadyHosted: alreadyHosted)
    }
}

/// ホスト中の会話と同じ sessionId を、アプリの外の claude が動かしている（引き継いだ後に VS Code 等で動き出した）。
public struct ExternalDuplicate: Sendable, Equatable {
    public var pid: Int32
    public var entrypoint: String?

    public init(pid: Int32, entrypoint: String?) {
        self.pid = pid
        self.entrypoint = entrypoint
    }

    /// 外で同じ会話を動かしている claude（アプリがホストしている pid は除く）。
    public static func find(sessionId: String, hostedPids: Set<Int32>, records: [ClaudeSessionRecord],
                            inspect: (Int32) -> ProcessFacts?) -> ExternalDuplicate? {
        SessionHandover.liveRecords(sessionId: sessionId, records: records, excluding: hostedPids, inspect: inspect)
            .min { $0.pid < $1.pid }
            .map { ExternalDuplicate(pid: $0.pid, entrypoint: $0.entrypoint) }
    }

    /// ホストのルームに出す警告。
    public var warning: String {
        let tail = "止まるまで、同じ会話に二重に書き込まないようここからの送信を止めています。"
        switch entrypoint {
        case "claude-vscode":
            return "VS Code で同じ会話が動き出しました（pid \(pid)）。VS Code のタブを閉じてください。" + tail
        case "cli":
            return "ターミナルで同じ会話が動き出しました（pid \(pid)）。そちらの claude を終了してください。" + tail
        default:
            return "このアプリの外で同じ会話が動き出しました（pid \(pid)）。そちらの claude を終了してください。" + tail
        }
    }

    /// 入力欄に出す送れない理由。
    public var sendBlockedReason: String {
        switch entrypoint {
        case "claude-vscode": return "VS Code で同じ会話が動いているため送れません（VS Code のタブを閉じると送れます）"
        case "cli": return "ターミナルで同じ会話が動いているため送れません（そちらの claude を終了すると送れます）"
        default: return "アプリの外で同じ会話が動いているため送れません（そちらの claude を終了すると送れます）"
        }
    }
}
