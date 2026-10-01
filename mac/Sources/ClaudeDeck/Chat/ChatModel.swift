import AppKit
import Observation
import MonitorKit

enum RoomID: Hashable {
    case hosted(UUID)
    case external(String)
}

enum RoomMode: Hashable, CaseIterable {
    case chat, terminal, github, appstore

    var title: String {
        switch self {
        case .chat: return "チャット"
        case .terminal: return "ターミナル"
        case .github: return "GitHub"
        case .appstore: return "App Store"
        }
    }

    var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .terminal: return "terminal"
        case .github: return "checklist"
        case .appstore: return "app.badge"
        }
    }
}

/// ルーム一覧と会話画面が描く 1 ルーム分の値。
struct Room: Identifiable {
    let id: RoomID
    let name: String
    let branch: String?
    let status: SessionStatus
    let line: String
    let activityAt: Double?
    let sessionId: String?
    let cwd: String
    let hosted: HostedSession?
    let snapshot: SessionSnapshot?
    let unread: Int

    var isExternal: Bool { hosted == nil }
    var activityDate: Date? { activityAt.map(Date.init(epochMillis:)) }
}

struct RoomGroup: Identifiable {
    let phase: RoomPhase
    let rooms: [Room]
    var id: RoomPhase { phase }
}

/// ルーム一覧の 1 段。id は `RoomListEntry.id`（行はグループを移っても同じ）。
struct RoomListItem: Identifiable {
    enum Kind {
        case header(RoomPhase, count: Int)
        case row(Room)
    }

    let id: String
    let kind: Kind
}

/// チャット画面の状態。monitor のストアと、アプリがホストするセッションを束ねる。
@MainActor
@Observable
final class ChatModel {
    let store: MonitorStore

    private(set) var hosted: [HostedSession] = []
    var selection: RoomID?
    var query = ""
    /// ルームごとの書きかけ。ルームを行き来しても残す。
    var drafts: [RoomID: String] = [:]
    private var modes: [RoomID: RoomMode] = [:]

    private(set) var transcripts: [String: TranscriptBuffer] = [:]
    private(set) var loadingTranscripts: Set<String> = []
    private(set) var transcriptErrors: [String: String] = [:]
    @ObservationIgnored private var staleTranscripts: Set<String> = []
    @ObservationIgnored private var transcriptRetries: [String: Int] = [:]

    /// ルーム一覧。feed・セッション・ホスト中のセッションが変わった時だけ作り直す（描画のたびに feed を走査しない）。
    private(set) var rooms: [Room] = []
    private(set) var groupedRooms: [RoomGroup] = []
    /// 一覧に描く順の見出しと行。
    private(set) var listItems: [RoomListItem] = []

    /// sessionId → 最後に開いた時刻（epoch ミリ秒）。未読数の起点。
    private var lastSeen: [String: Double] = [:]
    @ObservationIgnored private let launchedAt = Date().timeIntervalSince1970 * 1000

    /// sessionId → アプリから送った伝言。transcript には出ないので手元で持つ。
    private(set) var relayNotes: [String: [RelayNote]] = [:]
    /// 引き継ぎ中の sessionId（終了待ち〜再開まで）。
    private(set) var handingOver: Set<String> = []

    /// 送信中の権限確認（monitor の key か "pty:<ルーム>"）。二度押しさせない。
    private(set) var busyPermissionKeys: Set<String> = []
    var alertMessage: String?

    @ObservationIgnored private var boards: [String: GitHubBoardView] = [:]
    @ObservationIgnored private var appStoreViews: [String: AppStoreView] = [:]
    @ObservationIgnored private var xcodeProjects: [String: URL?] = [:]
    @ObservationIgnored private var boardMappings: [String: BoardMapping?] = [:]
    @ObservationIgnored private var appStoreNames: Set<String>?

    init(store: MonitorStore) {
        self.store = store
        store.onTranscript = { [weak self] event in self?.receive(event) }
        refreshRooms()
    }

    // MARK: - ルーム

    /// 一覧を作り直し、読んだ値（feed・sessions・ホスト中のセッション・検索語・既読）が変わったら次の周回でもう一度作る。
    private func refreshRooms() {
        let (all, grouped) = withObservationTracking {
            let all = buildRooms()
            return (all, group(all))
        } onChange: { [weak self] in
            // onChange は値が書き換わる前に呼ばれるので、書き換え後に作り直す。
            Task { @MainActor [weak self] in self?.refreshRooms() }
        }
        rooms = all
        groupedRooms = grouped.groups
        listItems = grouped.items
    }

    private func buildRooms() -> [Room] {
        let connected = store.connection.isConnected
        var latestLine: [String: String] = [:]
        for item in store.feed where !item.text.isEmpty { latestLine[item.sessionId] = item.text }
        let unread = RoomGrouping.unreadCounts(feed: store.feed, since: lastSeen, defaultSince: launchedAt)

        var result: [Room] = hosted.map { session in
            let sessionId = session.resolveSessionId(store)
            let snapshot = sessionId.flatMap { store.session(id: $0) }
            let status: SessionStatus
            if session.end != nil {
                status = .stopped
            } else if session.permissionPrompt != nil {
                status = .permission
            } else if session.inputBlock != nil {
                status = .waiting
            } else if connected, let snapshot {
                status = snapshot.status
            } else {
                status = Self.status(from: session.localStatus)
            }
            let line: String
            switch session.end {
            case .limitReached: line = "上限に達したため終了しました"
            case .exited: line = "claude は終了しました"
            case .launchFailed: line = "claude を起動できませんでした"
            case nil:
                line = sessionId.flatMap { latestLine[$0] } ?? snapshot.flatMap(Self.line(of:))
                    ?? (session.pid == nil ? "起動中…" : "セッション開始")
            }
            let activity = snapshot?.lastActivityAt ?? session.lastChangeAt.timeIntervalSince1970 * 1000
            return Room(id: .hosted(session.id), name: session.project.name, branch: snapshot?.branch, status: status,
                        line: line, activityAt: activity, sessionId: sessionId, cwd: session.project.path,
                        hosted: session, snapshot: snapshot, unread: sessionId.flatMap { unread[$0] } ?? 0)
        }

        let hostedIds = Set(result.compactMap(\.sessionId))
        let hostedPids = Set(hosted.compactMap(\.pid))
        for snapshot in store.sessions where !hostedIds.contains(snapshot.sessionId) && !hostedPids.contains(snapshot.pid) {
            result.append(Room(id: .external(snapshot.sessionId), name: snapshot.name, branch: snapshot.branch,
                               status: snapshot.status,
                               line: latestLine[snapshot.sessionId] ?? Self.line(of: snapshot) ?? "",
                               activityAt: snapshot.lastActivityAt ?? snapshot.startedAt, sessionId: snapshot.sessionId,
                               cwd: snapshot.cwd, hosted: nil, snapshot: snapshot, unread: unread[snapshot.sessionId] ?? 0))
        }
        return result
    }

    private func group(_ all: [Room]) -> (groups: [RoomGroup], items: [RoomListItem]) {
        let byKey = Dictionary(all.map { (key(of: $0.id), $0) }, uniquingKeysWith: { a, _ in a })
        let keys = all.map { room in
            RoomKey(id: key(of: room.id), name: room.name, status: room.status, activityAt: room.activityAt,
                    searchText: [room.branch, room.snapshot?.title, room.line, room.cwd].compactMap { $0 }.joined(separator: " "))
        }
        let grouped = RoomGrouping.group(keys, query: query)
        let groups = grouped.map { group in
            RoomGroup(phase: group.phase, rooms: group.ids.compactMap { byKey[$0] })
        }
        let items = RoomGrouping.entries(grouped).compactMap { entry -> RoomListItem? in
            switch entry {
            case .header(let phase, let count): return RoomListItem(id: entry.id, kind: .header(phase, count: count))
            case .row(let key): return byKey[key].map { RoomListItem(id: entry.id, kind: .row($0)) }
            }
        }
        return (groups, items)
    }

    var selectedRoom: Room? {
        guard let selection else { return nil }
        return rooms.first { $0.id == selection }
    }

    func select(_ id: RoomID) {
        selection = id
        markSelectedSeen()
    }

    func mode(for id: RoomID) -> RoomMode { modes[id] ?? .chat }

    func setMode(_ mode: RoomMode, for id: RoomID) { modes[id] = mode }

    /// 選択中のルームを既読にする（新着を受けるたびにも呼ぶ）。
    func markSelectedSeen() {
        guard let sessionId = selectedRoom?.sessionId else { return }
        lastSeen[sessionId] = Date().timeIntervalSince1970 * 1000
    }

    private func key(of id: RoomID) -> String {
        switch id {
        case .hosted(let uuid): return "h:\(uuid.uuidString)"
        case .external(let sessionId): return "e:\(sessionId)"
        }
    }

    static func status(from local: ClaudeStatus) -> SessionStatus {
        switch local {
        case .working: return .working
        // 権限プロンプト・選択メニューは inputBlock で先に見ているので、ここに来るのは文言だけで決めた入力待ち（バッジ用）。
        case .waitingInput: return .waiting
        case .idle: return .idle
        }
    }

    private static func line(of snapshot: SessionSnapshot) -> String? {
        [snapshot.currentAction, snapshot.title, snapshot.lastPrompt].compactMap { $0 }.first { !$0.isEmpty }
    }

    // MARK: - ホストするセッション

    func launch(_ project: ManagedProject) {
        // 同じプロジェクトを二重に起動しない（動いているルームがあればそこへ移る）。
        if let running = hosted.first(where: { $0.project.path == project.path && $0.end == nil }) {
            select(.hosted(running.id))
            return
        }
        let session = HostedSession(project: project)
        session.onLimitReached = { [weak self] session in self?.showLimitAlert(for: session) }
        hosted.append(session)
        session.start()
        select(.hosted(session.id))
    }

    func close(_ session: HostedSession) {
        session.terminate()
        hosted.removeAll { $0.id == session.id }
        if selection == .hosted(session.id) { selection = nil }
    }

    func send(_ text: String, to room: Room) -> Bool {
        guard let session = room.hosted else { return false }
        let result = session.send(text) { [weak self] block in
            // 入力欄に入った本文を安全に消すキーが無い（Esc はメニューの取り消しになる）ので、下書きには戻さず二重送信を避ける。
            self?.alertMessage = "送信の途中で\(Self.blockName(block))が出たため、Enter を押さずに取りやめました。"
                + "端末側の入力欄に本文が残っています（ターミナル表示で確認）。確認に答えた後、ターミナルで Enter を押すか本文を消してください。"
                + "消さずにここから送ると、残っている本文とつながって送られます。"
        }
        switch result {
        case .sent: return true
        case .leftover:
            alertMessage = "端末側の入力欄に前回の本文が残っているようです。ターミナル表示で消してから送ってください。"
                + "このままもう一度送ると、残っている本文の後ろにつながって送られます。"
            return false
        case .blocked(.permission):
            alertMessage = "権限の確認に答えてから送ってください（今 Enter を送ると確認への「Yes」になります）。"
            return false
        case .blocked:
            alertMessage = "端末側で選択肢が出ています。ターミナル表示で選択に答えてから送ってください（今 Enter を送るとその選択が確定します）。"
            return false
        case .empty, nil: return false
        }
    }

    /// 入力欄を無効にする理由（送信時の判定と同じ条件）。nil なら送れる。外部ルームは伝言を送れるか。
    func inputDisabledReason(for room: Room) -> String? {
        guard room.hosted != nil else {
            if let sessionId = room.sessionId, handingOver.contains(sessionId) { return "引き継ぎ中…" }
            if !store.connection.isConnected { return "monitor に未接続のため伝言を送れません" }
            if room.snapshot?.alive == false || room.status == .stopped { return "このセッションは終了しています" }
            return nil
        }
        return Self.inputDisabledReason(for: room)
    }

    static func inputDisabledReason(for room: Room) -> String? {
        guard let session = room.hosted else { return "外部セッションにはここから送れません" }
        switch session.end {
        case .limitReached: return "上限に達したため終了しました"
        case .exited: return "claude は終了しました"
        case .launchFailed: return "claude を起動できませんでした"
        case nil:
            if session.pid == nil { return "起動中…" }
            switch session.inputBlock {
            case .permission: return "権限の確認に答えると送れます"
            case .menu: return "端末側の選択に答えると送れます（ターミナル表示で操作）"
            case nil: return nil
            }
        }
    }

    // MARK: - 伝言（外部セッション）

    func notes(for sessionId: String?) -> [RelayNote] {
        guard let sessionId else { return [] }
        return relayNotes[sessionId] ?? []
    }

    /// 外部セッションへ伝言を送る。受け手には「別セッションからのメッセージ」として届き、本人の入力にはならない。
    func sendRelay(_ text: String, to room: Room) -> Bool {
        guard room.hosted == nil, let sessionId = room.sessionId, inputDisabledReason(for: room) == nil else { return false }
        let body = RelayNotes.normalized(text)
        guard !body.isEmpty else { return false }
        let note = RelayNote(text: body, sentAt: Date().timeIntervalSince1970 * 1000)
        relayNotes[sessionId, default: []].append(note)
        Task {
            do {
                try await store.sendMessage(to: sessionId, text: body)
                updateNote(note.id, in: sessionId, state: .sent)
            } catch {
                let reason = RelayNotes.failureReason(error)
                updateNote(note.id, in: sessionId, state: .failed(reason))
                alertMessage = "伝言を送れませんでした: \(reason)"
            }
        }
        return true
    }

    private func updateNote(_ id: String, in sessionId: String, state: RelayNote.State) {
        guard let index = relayNotes[sessionId]?.firstIndex(where: { $0.id == id }) else { return }
        relayNotes[sessionId]?[index].state = state
    }

    // MARK: - アプリに引き継ぐ

    /// 起動元（VS Code 拡張等）のせいで引き継げない理由。nil ならターミナルの対話セッション。
    func handoverSourceReason(for room: Room) -> String? {
        guard let snapshot = room.snapshot else { return "このルームは引き継げません" }
        let record = ClaudeSessionRegistry().record(forPid: snapshot.pid).flatMap { $0.sessionId == snapshot.sessionId ? $0 : nil }
        return SessionHandover.unsupportedSourceReason(entrypoint: record?.entrypoint ?? snapshot.entrypoint, kind: record?.kind)
    }

    /// 引き継げない理由。nil なら引き継げる。
    func handoverDisabledReason(for room: Room) -> String? {
        guard room.hosted == nil, let snapshot = room.snapshot, let sessionId = room.sessionId else {
            return "このルームは引き継げません"
        }
        if handingOver.contains(sessionId) { return "引き継ぎ中…" }
        if !snapshot.alive || room.status == .stopped { return "このセッションは終了しています" }
        if !SessionHandover.isValidSessionId(sessionId) { return "sessionId の形式が想定外のため引き継げません" }
        if let reason = handoverSourceReason(for: room) { return reason }
        if LimitWatch.shared.isLimitReached { return "Max 枠の上限に達しているため引き継げません（リセット後に試してください）" }
        return nil
    }

    /// 確認ダイアログを出し、了承されたら外部の claude を止めてこのアプリで再開する。キャンセルなら何もしない。
    func requestHandover(_ room: Room) {
        if let reason = handoverDisabledReason(for: room) {
            alertMessage = reason
            return
        }
        guard let snapshot = room.snapshot, let sessionId = room.sessionId else { return }
        let alert = NSAlert()
        alert.messageText = "「\(room.name)」をアプリに引き継ぎますか？"
        alert.informativeText = """
            1. ターミナルで動いている claude（pid \(snapshot.pid)）を終了します（Ctrl-C と同じ SIGINT。数秒で終わらなければ SIGTERM）。作業中なら中断されます。
            2. 終了を確認できたら、同じフォルダでこのアプリから claude --resume を起動し、同じ会話を続きから再開します。

            元のターミナルのウィンドウは閉じません。終了を確認できなかった場合は再開しません。
            フォルダ: \(room.cwd)
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "引き継ぐ")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        handOver(room: room, pid: snapshot.pid, sessionId: sessionId)
    }

    private func handOver(room: Room, pid: Int32, sessionId: String) {
        guard !handingOver.contains(sessionId) else { return }
        // 確認ダイアログを出している間に上限到達・終了などが起きうるので、止める前に判定し直す。
        if let reason = handoverDisabledReason(for: room) {
            alertMessage = "引き継ぎを中止しました（何も終了していません）: \(reason)"
            return
        }
        handingOver.insert(sessionId)
        let project = ProjectStore.load().first(where: { $0.path == room.cwd })
            ?? ManagedProject(name: room.name, path: room.cwd, status: "active", note: "")
        let roomId = room.id
        Task {
            let outcome = await SessionTerminator().terminate(pid: pid, sessionId: sessionId)
            defer { handingOver.remove(sessionId) }
            switch outcome {
            case .exited:
                // 待っている間に上限へ達したら起動しない（起動してもすぐ止められる）。
                if LimitWatch.shared.isLimitReached {
                    alertMessage = "ターミナルの claude は終了しましたが、Max 枠の上限に達しているため再開しませんでした。"
                    return
                }
                resume(project: project, sessionId: sessionId, from: roomId)
            case .refused(let reason):
                alertMessage = "引き継ぎを中止しました（何も終了していません）: \(reason)"
            case .runningElsewhere(let other):
                alertMessage = "同じ会話が別の claude（pid \(other)）で動いているため、再開していません（二重起動を避けるため）。"
            case .stillRunning:
                alertMessage = "ターミナルの claude が終了しなかったため、再開していません（同じ会話の二重起動を避けるため）。"
                    + "ターミナルで終了してからもう一度お試しください。"
            }
        }
    }

    private func resume(project: ManagedProject, sessionId: String, from roomId: RoomID) {
        let session = HostedSession(project: project, resumeSessionId: sessionId)
        session.onLimitReached = { [weak self] session in self?.showLimitAlert(for: session) }
        hosted.append(session)
        session.start()
        if let draft = drafts.removeValue(forKey: roomId) { drafts[.hosted(session.id)] = draft }
        modes[roomId] = nil
        select(.hosted(session.id))
    }

    private static func blockName(_ block: InputBlock) -> String {
        switch block {
        case .permission: return "権限の確認"
        case .menu: return "端末側の選択肢"
        }
    }

    private func showLimitAlert(for session: HostedSession) {
        let alert = NSAlert()
        alert.messageText = "Max 枠の上限に達しました"
        alert.informativeText = "「\(session.project.name)」のセッションを強制終了しました。枠がリセットされるまでお待ちください。（API 課金は発生しません）"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - 権限確認

    func monitorPermissions(for room: Room) -> [PendingPermission] {
        guard let sessionId = room.sessionId else { return [] }
        return store.permissions(forSessionId: sessionId)
    }

    func decide(_ permission: PendingPermission, _ decision: PermissionDecision) {
        guard !busyPermissionKeys.contains(permission.key) else { return }
        busyPermissionKeys.insert(permission.key)
        Task {
            defer { busyPermissionKeys.remove(permission.key) }
            do {
                try await store.decide(permission, decision)
            } catch {
                alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    static func ptyPermissionKey(_ session: HostedSession) -> String { "pty:\(session.id.uuidString)" }

    /// `prompt` はカードに出していたもの。端末の今のプロンプトと違えば何も送らない（別の確認を承認しないため）。
    func answerOnTerminal(_ session: HostedSession, prompt: PermissionPrompt, allow: Bool) {
        let key = Self.ptyPermissionKey(session)
        guard !busyPermissionKeys.contains(key) else { return }
        switch session.answerPermission(prompt, allow: allow) {
        case .sent:
            break
        case .noPrompt:
            alertMessage = "端末に権限確認が見当たりません。ターミナルで確認してください。"
            return
        case .changed:
            alertMessage = "権限の確認の内容が替わったため送りませんでした。カードの内容を確かめてから答えてください。"
            return
        }
        busyPermissionKeys.insert(key)
        // キーを送ってからプロンプトが消えるまで少し掛かるので、その間は押せないままにする。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.busyPermissionKeys.remove(key) }
    }

    // MARK: - 会話履歴

    func transcript(for sessionId: String?) -> [TranscriptItem] {
        guard let sessionId else { return [] }
        return transcripts[sessionId]?.items ?? []
    }

    /// 選択中のルームの履歴を揃える。未取得・再接続後なら GET する（SSE は `*` で常に張っている）。
    /// 取り直しも常に全件で置き換える（切れていた間の発話は手元の末尾より前に入りうるので `after=` では埋まらない）。
    func ensureTranscript(for sessionId: String?) {
        guard let sessionId, store.connection.isConnected, !loadingTranscripts.contains(sessionId) else { return }
        guard transcripts[sessionId] == nil || staleTranscripts.contains(sessionId) else { return }
        var buffer = transcripts[sessionId] ?? TranscriptBuffer()
        buffer.beginFetch()
        transcripts[sessionId] = buffer
        staleTranscripts.remove(sessionId)
        loadingTranscripts.insert(sessionId)
        Task {
            var failed = false
            do {
                let response = try await store.client.fetchTranscript(sessionId: sessionId, after: nil)
                transcripts[sessionId]?.apply(response, fullReplace: true)
                transcriptErrors[sessionId] = nil
                transcriptRetries[sessionId] = nil
            } catch MonitorError.http(status: 404, _, _) {
                // 最初の発話前はログが無い。以降は SSE で届くので空のまま待つ。
                transcriptErrors[sessionId] = nil
                transcriptRetries[sessionId] = nil
            } catch {
                transcriptErrors[sessionId] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                staleTranscripts.insert(sessionId)
                failed = true
            }
            loadingTranscripts.remove(sessionId)
            if failed {
                retryTranscript(sessionId)
            } else if staleTranscripts.contains(sessionId) {
                // 取得中に繋ぎ直した。その応答は切断前の内容かもしれないので取り直す。
                ensureTranscript(for: sessionId)
            }
        }
    }

    /// 失敗した取得を間隔を空けて数回だけやり直す（monitor が落ちている間に叩き続けない）。
    private func retryTranscript(_ sessionId: String) {
        let attempt = (transcriptRetries[sessionId] ?? 0) + 1
        guard attempt <= 3 else { return }
        transcriptRetries[sessionId] = attempt
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(attempt) * 2))
            self?.ensureTranscript(for: sessionId)
        }
    }

    /// monitor に繋ぎ直した。切れていた間の分を取り直す。
    func reconnected() {
        staleTranscripts = Set(transcripts.keys)
        transcriptRetries = [:]
        ensureTranscript(for: selectedRoom?.sessionId)
    }

    private func receive(_ event: TranscriptEvent) {
        // 一度も開いていないセッションは、開いた時に GET でまとめて取る。
        guard transcripts[event.sessionId] != nil else { return }
        transcripts[event.sessionId]?.append(event.items)
    }

    // MARK: - 付随ビュー

    /// 見出しは毎秒描き直されるので、TSV / 一覧の読み込みはルームごとに一度だけにする。
    func boardMapping(for room: Room) -> BoardMapping? {
        let key = "\(room.cwd)|\(room.name)"
        if let cached = boardMappings[key] { return cached }
        let mapping: BoardMapping?
        // owner/number は後から設定できるので、起動時に持っていた値より保存済みの一覧を優先する。
        if let project = ProjectStore.load().first(where: { $0.path == room.cwd }) ?? room.hosted?.project {
            mapping = GitHubBoard.mapping(forProject: project)
        } else {
            mapping = GitHubBoard.mapping(forProjectNamed: room.name)
        }
        boardMappings[key] = mapping
        return mapping
    }

    /// プロジェクト一覧（GitHub の紐づけ等）を書き換えた後に、読み込み済みの値を捨てる。
    func projectsChanged() {
        boardMappings = [:]
        appStoreNames = nil
    }

    /// appstore.tsv に載っているプロジェクトだけ App Store を出す。
    func hasAppStore(_ room: Room) -> Bool {
        if appStoreNames == nil { appStoreNames = AppStoreClient.registeredNames() }
        return appStoreNames?.contains(room.name) ?? false
    }

    /// App Store 表示は server に取りに行くので、ルームを行き来しても作り直さない。
    func appStoreView(for room: Room) -> AppStoreView {
        if let view = appStoreViews[room.name] { return view }
        let view = AppStoreView(projectName: room.name)
        appStoreViews[room.name] = view
        return view
    }

    /// GitHub ボードは取得に gh を叩くので、ルームを行き来しても作り直さない。
    func boardView(for mapping: BoardMapping) -> GitHubBoardView {
        let key = "\(mapping.owner)/\(mapping.number)"
        if let view = boards[key] { return view }
        let view = GitHubBoardView(mapping: mapping)
        boards[key] = view
        return view
    }

    func xcodeProject(for room: Room) -> URL? {
        if let cached = xcodeProjects[room.cwd] { return cached }
        let found = TerminalPaneViewController.findXcodeProject(in: room.cwd)
        xcodeProjects[room.cwd] = found
        return found
    }

    func openInVSCode(_ room: Room) {
        let folder = URL(fileURLWithPath: room.cwd, isDirectory: true)
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
            alertMessage = "Visual Studio Code が見つかりません。"
            return
        }
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func openInXcode(_ room: Room) {
        guard let url = xcodeProject(for: room) else { return }
        NSWorkspace.shared.open(url)
    }
}
