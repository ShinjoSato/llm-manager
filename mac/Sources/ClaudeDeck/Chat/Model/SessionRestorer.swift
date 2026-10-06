import Foundation
import Observation
import MonitorKit

/// ホスト中のセッションを `hosted-sessions.json` に書き残し、次の起動で `claude --resume` し直す。作業の途中だったものには続きを頼む。
@MainActor
@Observable
final class SessionRestorer {
    /// 一覧の上に出す再開の結果（閉じるまで出す）。
    private(set) var notice: String?
    /// 再開を見送った記録（解除後に再開できるよう一覧に残し、ファイルにも書き続ける）。
    private(set) var deferred: [Deferred] = []

    struct Deferred: Equatable {
        var record: HostedSessionRecord
        var reason: SessionRestore.DeferReason
    }

    var deferredSummary: String? { SessionRestore.deferredSummary(deferred.map(\.reason)) }

    @ObservationIgnored weak var model: ChatModel?
    @ObservationIgnored private let file = HostedSessionsFile(url: HostedSessionsFile.defaultURL())
    @ObservationIgnored private let settings = LaunchSettings.shared
    /// 記録のロック。取れなければ別のアプリが動いているので、再開も書き込みもしない。
    @ObservationIgnored private var lock: HostedSessionsLock?
    /// 読んだがまだ再開の判定をしていない記録（判定までの保存で消さないため）。
    @ObservationIgnored private var awaiting: [HostedSessionRecord] = []
    /// 自動で再開した時刻。正常に終わる時に外し、残っていれば次の起動で再開の直後に落ちたとみなす。
    @ObservationIgnored private var restoreMark: Date?
    @ObservationIgnored private var nudges: [UUID: Nudge] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var lastSaved: (records: [HostedSessionRecord], mark: Date?)?

    /// 続きを頼む相手と、送る時機の見張り。
    private struct Nudge {
        weak var session: HostedSession?
        var gate: ResumeNudgeGate
    }

    /// 送る時機の見張りの間隔。保存はこの何回かに 1 回。
    private static let tickInterval: TimeInterval = 0.5
    private static let saveEveryTicks = 6
    /// 監視の開始を待つ上限（残量を読む前に再開して上限到達を見落とさないため待つ）。
    private static let monitorWait: Duration = .seconds(10)

    func start() {
        guard timer == nil, lock == nil else { return }
        guard let lock = HostedSessionsLock.acquire(for: file) else {
            notice = "別の claude-deck が動いているため、前回のセッションの再開と記録をしていません"
            return
        }
        self.lock = lock
        let snapshot = file.loadSnapshot()
        let records = settings.resumeOnLaunch ? (snapshot?.sessions ?? []) : []
        if !records.isEmpty, SessionRestore.isCrashLoop(restoredAt: snapshot?.restoredDate, now: Date()) {
            deferred = Self.unique(records).map { Deferred(record: $0, reason: .crashLoop) }
            notice = "前回は再開の直後にアプリが終了したため、自動では再開していません"
        } else {
            awaiting = records
        }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // 終了の確認中（モーダルの run loop）でも記録と見張りを止めない。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        saveNow()
        guard !awaiting.isEmpty else { return }
        Task { [weak self] in
            await self?.waitForMonitor()
            self?.restoreAwaiting()
        }
    }

    /// 今の記録をすぐ書く（ルームの起動・終了・アプリの終了時）。
    func saveNow() {
        guard lock != nil else { return }
        let records = currentRecords()
        if let lastSaved, lastSaved.records == records, lastSaved.mark == restoreMark { return }
        do {
            try file.save(records, restoredAt: restoreMark)
            lastSaved = (records, restoreMark)
        } catch {
            FileHandle.standardError.write(Data("[claude-deck] ホスト中のセッションの記録を書けませんでした（\(file.url.path)）\n".utf8))
        }
    }

    /// アプリの正常な終了。再開の直後に落ちたのではないので印を外して書き切る。
    func saveOnTermination() {
        restoreMark = nil
        saveNow()
    }

    func dismissNotice() {
        notice = nil
    }

    /// 見送った分を再開する。まだ上限中なら何もしない。
    func resumeDeferred() {
        guard !deferred.isEmpty else { return }
        if LimitWatch.shared.isLimitReached {
            notice = "まだ Max 枠の上限に達しているため再開していません（リセット後にもう一度お試しください）"
            return
        }
        let records = deferred.map(\.record)
        deferred = []
        restore(records)
    }

    func discardDeferred() {
        deferred = []
        saveNow()
    }

    /// 上限で止められたセッション。記録を失わず見送りに移す（リセット後に帯か次の起動で再開する）。
    func deferLimited(_ session: HostedSession) {
        guard let sessionId = session.lastSessionId else { return }
        let status: SessionStatus = nudges[session.id] != nil ? .working : ChatModel.status(from: session.localStatus)
        nudges[session.id] = nil
        let draft = model?.outbox.drafts[.hosted(session.id)].flatMap(Self.nonBlank)
        let record = HostedSessionRecord(name: session.project.name, cwd: session.project.path, sessionId: sessionId,
                                         status: status, draft: draft)
        if !deferred.contains(where: { $0.record.sessionId == sessionId }) {
            deferred.append(Deferred(record: record, reason: .limit))
        }
        saveNow()
    }

    // MARK: - 再開

    private func waitForMonitor() async {
        guard let store = model?.store else { return }
        let deadline = ContinuousClock.now + Self.monitorWait
        while !store.connection.isConnected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        // 接続と同時に届く残量の反映を待つ。
        try? await Task.sleep(for: .seconds(1))
    }

    private func restoreAwaiting() {
        let records = awaiting
        awaiting = []
        guard settings.resumeOnLaunch else {
            saveNow()
            return
        }
        restore(records)
    }

    private func restore(_ records: [HostedSessionRecord]) {
        guard let model, !records.isEmpty else { return }
        let registry = ClaudeSessionRegistry().allRecords()
        let plans = SessionRestore.plan(
            records: records,
            limitReached: LimitWatch.shared.isLimitReached,
            askToContinue: settings.askToContinue,
            hostedSessionIds: Set(model.hosted.filter { $0.end == nil }.compactMap(\.lastSessionId)),
            directoryExists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            liveDuplicate: { sessionId in
                SessionHandover.liveDuplicate(sessionId: sessionId, records: registry, inspect: ProcessFacts.inspect)
            })
        var launched = 0, nudged = 0, limited = 0, elsewhere = 0, skipped = 0
        for plan in plans {
            switch plan.decision {
            case .launch(let nudge):
                let session = model.resumeRestored(plan.record)
                launched += 1
                if nudge {
                    nudged += 1
                    nudges[session.id] = Nudge(session: session, gate: ResumeNudgeGate(startedAt: Date()))
                }
            case .deferredByLimit:
                limited += 1
                deferred.append(Deferred(record: plan.record, reason: .limit))
            case .runningElsewhere:
                elsewhere += 1
                deferred.append(Deferred(record: plan.record, reason: .runningElsewhere))
            case .skipped:
                skipped += 1
            }
        }
        if launched > 0 { restoreMark = Date() }
        notice = SessionRestore.summary(launched: launched, nudged: nudged, deferred: limited,
                                        elsewhere: elsewhere, skipped: skipped)
        saveNow()
    }

    // MARK: - 見張り

    private func tick() {
        advanceNudges()
        ticks += 1
        if ticks % Self.saveEveryTicks == 0 { saveNow() }
    }

    private func advanceNudges() {
        guard !nudges.isEmpty else { return }
        let now = Date()
        let holding = QuitCoordinator.shared.isHolding
        for (id, var nudge) in nudges {
            guard let session = nudge.session, session.end == nil else {
                nudges[id] = nil
                continue
            }
            let observation = ResumeNudgeGate.Observation(
                ready: isReady(session), working: session.localStatus == .working,
                userSent: session.userSendCount > 0, holding: holding)
            switch nudge.gate.step(observation, now: now) {
            case .wait:
                nudges[id] = nudge
            case .cancel:
                nudges[id] = nil
            case .giveUp:
                nudges[id] = nil
                putDraft(for: session)
            case .send:
                let result = session.send(SessionRestore.continueMessage, byUser: false) { [weak self, weak session] completion in
                    // 本文を貼る前にやめた時だけ下書きへ戻す（貼った後なら端末の入力欄に残っている）。
                    guard completion.restoresDraft, let self, let session else { return }
                    self.putDraft(for: session)
                }
                if case .started = result {
                    nudges[id] = nil
                } else {
                    nudge.gate.refused()
                    nudges[id] = nudge
                }
            }
        }
    }

    /// 通常の送信と同じく、選択待ち・送信中は送らない。端末の入力欄が空で見えるまで待つ。
    private func isReady(_ session: HostedSession) -> Bool {
        guard session.isRunning, session.inputBlock == nil, !session.isSending else { return false }
        return InputBox.text(screen: session.terminal.screenLines())?.isEmpty == true
    }

    private func putDraft(for session: HostedSession) {
        guard let outbox = model?.outbox else { return }
        let roomId = RoomID.hosted(session.id)
        outbox.drafts[roomId] = ComposerRestore.draft(restoring: SessionRestore.continueMessage, current: outbox.drafts[roomId] ?? "")
    }

    // MARK: - 記録

    /// ホスト中のセッションそのものから組み立てる（一覧は次の周回まで古いことがあるので使わない）。
    private func currentRecords() -> [HostedSessionRecord] {
        var records: [HostedSessionRecord] = []
        if let model {
            for session in model.hosted where session.end == nil {
                guard let sessionId = session.resolveSessionId(model.store) else { continue }
                let draft = model.outbox.drafts[.hosted(session.id)].flatMap(Self.nonBlank)
                // 続きを頼む前に止まったら、次の起動でも頼めるよう作業中として残す。
                let status: SessionStatus = nudges[session.id] != nil ? .working : model.liveStatus(of: session)
                records.append(HostedSessionRecord(name: session.project.name, cwd: session.project.path,
                                                   sessionId: sessionId, status: status, draft: draft))
            }
        }
        return Self.unique(records + awaiting + deferred.map(\.record))
    }

    private static func unique(_ records: [HostedSessionRecord]) -> [HostedSessionRecord] {
        var seen = Set<String>()
        return records.filter { seen.insert($0.sessionId).inserted }
    }

    private static func nonBlank(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
