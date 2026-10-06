import Foundation
import Observation
import MonitorKit

/// ホスト中のセッションを `hosted-sessions.json` に書き残し、次の起動で `claude --resume` し直す。作業の途中だったものには続きを頼む。
@MainActor
@Observable
final class SessionRestorer {
    /// 一覧の上に出す再開の結果（閉じるまで出す）。
    private(set) var notice: String?
    /// 上限到達中で再開しなかった記録（解除後に再開できるよう一覧に残し、ファイルにも書き続ける）。
    private(set) var deferred: [HostedSessionRecord] = []

    @ObservationIgnored weak var model: ChatModel?
    @ObservationIgnored private let file = HostedSessionsFile(url: HostedSessionsFile.defaultURL())
    @ObservationIgnored private let settings = LaunchSettings.shared
    /// 読んだがまだ再開の判定をしていない記録（判定までの保存で消さないため）。
    @ObservationIgnored private var awaiting: [HostedSessionRecord] = []
    @ObservationIgnored private var nudges: [UUID: Nudge] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var lastSaved: [HostedSessionRecord]?

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
        guard timer == nil else { return }
        awaiting = settings.resumeOnLaunch ? file.load() : []
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // 終了の確認中（モーダルの run loop）でも記録と見張りを止めない。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        guard !awaiting.isEmpty else { return }
        Task { [weak self] in
            await self?.waitForMonitor()
            self?.restoreAwaiting()
        }
    }

    /// 今の記録をすぐ書く（ルームの起動・終了・アプリの終了時）。
    func saveNow() {
        let records = currentRecords()
        guard records != lastSaved else { return }
        do {
            try file.save(records)
            lastSaved = records
        } catch {
            FileHandle.standardError.write(Data("[claude-deck] ホスト中のセッションの記録を書けませんでした（\(file.url.path)）\n".utf8))
        }
    }

    func dismissNotice() {
        notice = nil
    }

    /// 上限で見送った分を再開する。まだ上限中なら何もしない。
    func resumeDeferred() {
        guard !deferred.isEmpty else { return }
        if LimitWatch.shared.isLimitReached {
            notice = "まだ Max 枠の上限に達しているため再開していません（リセット後にもう一度お試しください）"
            return
        }
        let records = deferred
        deferred = []
        restore(records)
    }

    func discardDeferred() {
        deferred = []
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
        var launched = 0, nudged = 0, elsewhere = 0, skipped = 0
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
                deferred.append(plan.record)
            case .runningElsewhere:
                elsewhere += 1
            case .skipped:
                skipped += 1
            }
        }
        notice = SessionRestore.summary(launched: launched, nudged: nudged, deferred: deferred.count,
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
        for (id, var nudge) in nudges {
            guard let session = nudge.session, session.end == nil else {
                nudges[id] = nil
                continue
            }
            switch nudge.gate.step(ready: isReady(session), now: now) {
            case .wait:
                nudges[id] = nudge
            case .giveUp:
                nudges[id] = nil
                putDraft(for: session)
            case .send:
                let result = session.send(SessionRestore.continueMessage) { [weak self, weak session] completion in
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

    private func currentRecords() -> [HostedSessionRecord] {
        guard let model else { return awaiting + deferred }
        var records: [HostedSessionRecord] = []
        for room in model.rooms {
            guard let session = room.hosted, session.end == nil, let sessionId = room.sessionId else { continue }
            let draft = model.outbox.drafts[room.id].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            // 続きを頼む前に止まったら、次の起動でも頼めるよう作業中として残す。
            let status: SessionStatus = nudges[session.id] != nil ? .working : room.status
            records.append(HostedSessionRecord(name: room.name, cwd: room.cwd, sessionId: sessionId, status: status, draft: draft))
        }
        var seen = Set(records.map(\.sessionId))
        for record in awaiting + deferred where seen.insert(record.sessionId).inserted { records.append(record) }
        return records
    }
}
