import AppKit
import Observation
import MonitorKit

/// 外部セッション（ターミナル起動・VS Code の拡張）の claude を止めるか終わるのを待って、同じ会話をこのアプリで再開する。
/// 引き継いだ後に同じ会話が外で動き出していないかも見張る。
@MainActor
@Observable
final class ChatHandover {
    private let alerts: ChatAlerts

    /// 引き継ぎ中の sessionId（終了待ち〜再開まで）。
    private(set) var inProgress: Set<String> = []
    /// VS Code のタブが閉じられるのを待っている引き継ぎ（記録しないので、アプリの終了で消える）。
    private(set) var closeWaits: [String: CloseWait] = [:]

    struct CloseWait: Equatable {
        var target: HandoverTarget
        var roomId: RoomID
        var name: String
        var cwd: String
        var wait = HandoverCloseWait()
    }

    /// 終了を確認できた後の再開（HostedSession の起動と一覧への追加は ChatModel が持つ）。
    @ObservationIgnored var onResume: (_ project: ManagedProject, _ sessionId: String, _ from: RoomID) -> Void = { _, _, _ in assertionFailure("onResume 未設定") }
    /// ホスト中のセッションと今の sessionId（待ちの間にホストし始めたかと、外での二重起動の見張りに使う）。
    @ObservationIgnored var hostedSessions: () -> [(session: HostedSession, sessionId: String?)] = { assertionFailure("hostedSessions 未設定"); return [] }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticks = 0

    /// 見張りの間隔。二重起動の見張りはこの何回かに 1 回。
    private static let tickInterval: TimeInterval = 0.5
    private static let duplicateCheckEveryTicks = 2

    init(alerts: ChatAlerts) {
        self.alerts = alerts
    }

    /// 引き継ぎの途中（止めている・タブが閉じられるのを待っている）か。
    func isHandingOver(_ sessionId: String) -> Bool {
        inProgress.contains(sessionId) || closeWaits[sessionId] != nil
    }

    var handingOverIds: Set<String> { inProgress.union(closeWaits.keys) }

    func closeWaitPhase(sessionId: String) -> HandoverCloseWait.Phase? {
        closeWaits[sessionId]?.wait.phase
    }

    // MARK: - 起動元

    /// 引き継げる起動元か。VS Code の拡張は記録の entrypoint と実行ファイルの置き場所の両方で見る。
    func source(for room: Room) -> SessionHandover.SourceCheck {
        guard let snapshot = room.snapshot else { return .unsupported("このルームは引き継げません") }
        let record = ClaudeSessionRegistry().record(forPid: snapshot.pid).flatMap { $0.sessionId == snapshot.sessionId ? $0 : nil }
        let entrypoint = record?.entrypoint ?? snapshot.entrypoint
        guard let facts = ProcessFacts.inspect(pid: snapshot.pid) else {
            // 終わったセッションは実行ファイルを読めないので、ボタンを消さず「終了しています」で断る。
            return entrypoint == "claude-vscode" ? .supported(.editorExtension)
                : SessionHandover.checkSource(entrypoint: entrypoint, kind: record?.kind, executablePath: nil)
        }
        return SessionHandover.checkSource(entrypoint: entrypoint, kind: record?.kind, executablePath: facts.executablePath)
    }

    /// 引き継げない理由。nil なら引き継げる。
    func disabledReason(for room: Room) -> String? {
        guard room.hosted == nil, let snapshot = room.snapshot, let sessionId = room.sessionId else {
            return "このルームは引き継げません"
        }
        if inProgress.contains(sessionId) { return "引き継ぎ中…" }
        if closeWaits[sessionId] != nil { return "VS Code のタブが閉じられるのを待っています" }
        if !snapshot.alive || room.status == .stopped { return "このセッションは終了しています" }
        if !SessionHandover.isResumableSessionId(sessionId) { return "sessionId の形式が想定外のため引き継げません" }
        if case .unsupported(let reason) = source(for: room) { return reason }
        if QuitCoordinator.shared.isHolding { return "終了の確認中のため引き継げません" }
        if LimitWatch.shared.isLimitReached { return "Max 枠の上限に達しているため引き継げません（リセット後に試してください）" }
        return nil
    }

    // MARK: - 今すぐ止めて引き継ぐ

    /// 確認ダイアログを出し、了承されたら外部の claude を止めてこのアプリで再開する。キャンセルなら何もしない。
    func request(_ room: Room) {
        if let reason = disabledReason(for: room) {
            alerts.message = reason
            return
        }
        guard let snapshot = room.snapshot, let sessionId = room.sessionId,
              case .supported(let source) = source(for: room) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch source {
        case .terminal:
            alert.messageText = "「\(room.name)」をアプリに引き継ぎますか？"
            alert.informativeText = """
                1. ターミナルで動いている claude（pid \(snapshot.pid)）を終了します（Ctrl-C と同じ SIGINT。数秒で終わらなければ SIGTERM）。作業中なら中断されます。
                2. 終了を確認できたら、同じフォルダでこのアプリから claude --resume を起動し、同じ会話を続きから再開します。

                元のターミナルのウィンドウは閉じません。終了を確認できなかった場合は再開しません。
                フォルダ: \(room.cwd)
                """
            alert.addButton(withTitle: "引き継ぐ")
        case .editorExtension:
            alert.messageText = "「\(room.name)」を今すぐ止めてアプリに引き継ぎますか？"
            alert.informativeText = """
                VS Code 側の claude を止めてアプリで再開します。VS Code のタブはそのまま残るので、そこでは打たないでください。打つと同じ会話が 2 本動きます。

                1. VS Code の拡張で動いている claude（pid \(snapshot.pid)）を終了します（SIGINT。数秒で終わらなければ SIGTERM）。作業中なら中断されます。
                2. 終了を確認できたら、同じフォルダでこのアプリから claude --resume を起動し、同じ会話を続きから再開します。

                終了を確認できなかった場合は再開しません。
                フォルダ: \(room.cwd)
                """
            alert.addButton(withTitle: "止めて引き継ぐ")
        }
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        handOver(room: room, pid: snapshot.pid, sessionId: sessionId, source: source)
    }

    private func handOver(room: Room, pid: Int32, sessionId: String, source: SessionHandover.Source) {
        guard !inProgress.contains(sessionId) else { return }
        // 確認ダイアログを出している間に上限到達・終了などが起きうるので、止める前に判定し直す。
        if let reason = disabledReason(for: room) {
            alerts.message = "引き継ぎを中止しました（何も終了していません）: \(reason)"
            return
        }
        inProgress.insert(sessionId)
        let project = SettingsStore.shared.project(atPath: room.cwd, orNamed: room.name)
        let roomId = room.id
        let label = "\(source.label)の claude"
        Task {
            let outcome = await SessionTerminator().terminate(pid: pid, sessionId: sessionId)
            defer { inProgress.remove(sessionId) }
            switch outcome {
            case .exited:
                // 待っている間に上限へ達したら起動しない（起動してもすぐ止められる）。
                if LimitWatch.shared.isLimitReached {
                    alerts.message = "\(label)は終了しましたが、Max 枠の上限に達しているため再開しませんでした。"
                    return
                }
                onResume(project, sessionId, roomId)
            case .refused(let reason):
                alerts.message = "引き継ぎを中止しました（何も終了していません）: \(reason)"
            case .runningElsewhere(let other):
                alerts.message = "同じ会話が別の claude（pid \(other)）で動いているため、再開していません（二重起動を避けるため）。"
            case .stillRunning:
                alerts.message = "\(label)が終了しなかったため、再開していません（同じ会話の二重起動を避けるため）。"
                    + (source == .terminal ? "ターミナルで終了してからもう一度お試しください。" : "VS Code のタブを閉じてからもう一度お試しください。")
            }
        }
    }

    // MARK: - VS Code のタブを閉じたら引き継ぐ

    /// VS Code の claude が終わるのを待つ（アプリからは止めない）。終わって同じ会話の claude が他に無くなったら再開する。
    func requestOnClose(_ room: Room) {
        if let reason = disabledReason(for: room) {
            alerts.message = reason
            return
        }
        guard let snapshot = room.snapshot, let sessionId = room.sessionId else { return }
        let pid = snapshot.pid
        switch SessionHandover.checkTarget(pid: pid, sessionId: sessionId, record: ClaudeSessionRegistry().record(forPid: pid),
                                           facts: ProcessFacts.inspect(pid: pid), ownUid: getuid()) {
        case .ok(let target):
            guard target.source == .editorExtension else {
                alerts.message = "VS Code の拡張で動いている claude ではないため、タブを閉じるのを待てません"
                return
            }
            closeWaits[sessionId] = CloseWait(target: target, roomId: room.id, name: room.name, cwd: room.cwd)
            startWatching()
        case .notRunning:
            alerts.message = "このセッションは終了しています"
        case .refused(let reason):
            alerts.message = "引き継げません: \(reason)"
        }
    }

    /// 帯の［やめる］。VS Code の claude はそのまま。
    func cancelCloseWait(sessionId: String) {
        closeWaits[sessionId] = nil
    }

    // MARK: - 見張り

    /// 待ちと二重起動の見張りを始める（終了の確認中のモーダルでも止めない）。
    func startWatching() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        ticks += 1
        advanceCloseWaits()
        if ticks % Self.duplicateCheckEveryTicks == 0 { checkDuplicates() }
    }

    private func advanceCloseWaits() {
        guard !closeWaits.isEmpty else { return }
        let records = ClaudeSessionRegistry().allRecords()
        let hostedIds = Set(hostedSessions().filter { $0.session.end == nil }.compactMap(\.sessionId))
        let limitReached = LimitWatch.shared.isLimitReached
        let holding = QuitCoordinator.shared.isHolding
        let now = Date()
        for (sessionId, entry) in closeWaits {
            var next = entry
            let observation = HandoverCloseWait.observe(entry.target, records: records, inspect: ProcessFacts.inspect,
                                                        limitReached: limitReached, holding: holding,
                                                        alreadyHosted: hostedIds.contains(sessionId))
            switch next.wait.step(observation, now: now) {
            case .wait:
                if next != entry { closeWaits[sessionId] = next }
            case .cancel(.alreadyHosted):
                closeWaits[sessionId] = nil
            case .cancel(.limit):
                closeWaits[sessionId] = nil
                alerts.message = "Max 枠の上限に達したため、「\(entry.name)」の引き継ぎの待ちをやめました（VS Code の claude はそのままです）。"
            case .resume:
                closeWaits[sessionId] = nil
                onResume(SettingsStore.shared.project(atPath: entry.cwd, orNamed: entry.name), sessionId, entry.roomId)
            }
        }
    }

    /// ホスト中の会話と同じ会話がアプリの外で動いていれば、そのルームに印を付ける（送信を止めて警告を出す）。
    private func checkDuplicates() {
        let hosted = hostedSessions()
        let running = hosted.filter { $0.session.isRunning && $0.sessionId != nil }
        let records = running.isEmpty ? [] : ClaudeSessionRegistry().allRecords()
        let hostedPids = Set(hosted.compactMap { $0.session.pid })
        for (session, sessionId) in hosted {
            var duplicate: ExternalDuplicate?
            if session.isRunning, let sessionId {
                duplicate = ExternalDuplicate.find(sessionId: sessionId, hostedPids: hostedPids, records: records,
                                                   inspect: ProcessFacts.inspect)
            }
            if session.externalDuplicate != duplicate { session.externalDuplicate = duplicate }
        }
    }
}
