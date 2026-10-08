import AppKit
import Observation
import MonitorKit

/// iPhone の API と同じ識別子（`h:<UUID>` / `e:<sessionId>`）。
typealias RoomID = RemoteRoomID

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

/// 「ルーム」の一覧の 1 段。id は `RoomListEntry.id`（行は状態の見出しを移っても同じ）。
struct RoomListItem: Identifiable {
    enum Kind {
        case phase(RoomPhase, count: Int)
        case row(Room)
    }

    let id: String
    let kind: Kind
}

/// 中央に出すもの（選んだルームの会話か、選んだディレクトリの詳細）。
enum ChatCenter: Equatable {
    case room
    case directory(UUID)
    /// 全プロジェクト横断のリンク一覧。
    case links
}

/// 画面に 1 つだけ出す警告。どの部品からでも出せるよう ChatModel と分けて持つ。
@MainActor
@Observable
final class ChatAlerts {
    var message: String?
}

/// チャット画面の状態。監視とホスト中のセッションからルーム一覧を組み立て、送信・伝言・引き継ぎ・回答・会話・エディタの部品を束ねる。
@MainActor
@Observable
final class ChatModel {
    let store: MonitorStore
    let alerts: ChatAlerts
    /// 下書き・添付・ホスト中のセッションへの送信。
    let outbox: ChatOutbox
    /// 外部セッションへの伝言。
    let relay: ChatRelay
    /// 外部セッションをアプリに引き継ぐ。
    let handover: ChatHandover
    /// 権限確認・選択肢への回答。
    let prompts: PromptResponder
    /// 会話の取得と購読。
    let transcripts: TranscriptCache
    /// 見出しの VS Code / GitHub / Xcode。
    let editors: EditorLauncher
    /// ホスト中のセッションの記録と、起動時の再開。
    let restorer = SessionRestorer()

    private(set) var hosted: [HostedSession] = []
    var selection: RoomID?
    var query = ""
    /// ディレクトリを選んでいる間も `selection` は最後のルームのまま残す（ステージパネルと戻った時の続きのため）。
    private(set) var center: ChatCenter = .room
    var listMode: RoomListMode = .rooms {
        didSet {
            UserDefaults.standard.set(listMode.rawValue, forKey: RoomListMode.defaultsKey)
            // 2 つの見方は検索の対象（ルームとディレクトリ）が違うので、持ち越すと片方が空になる。
            if listMode != oldValue { query = "" }
        }
    }

    /// ルーム一覧。feed・セッション・ホスト中のセッションが変わった時だけ作り直す（描画のたびに feed を走査しない）。
    private(set) var rooms: [Room] = []
    /// 「ルーム」の一覧に描く順の見出しと行。
    private(set) var listItems: [RoomListItem] = []
    /// 登録プロジェクトごとのルーム（検索で絞る前。詳細はここから引く）。
    private(set) var directories: [ProjectDirectory] = []

    /// sessionId → 最後に開いた時刻（epoch ミリ秒）。未読数の起点。
    private var lastSeen: [String: Double] = [:]
    @ObservationIgnored private let launchedAt = Date().timeIntervalSince1970 * 1000
    @ObservationIgnored private var pendingLimitNames: [String] = []
    @ObservationIgnored private var limitAlertScheduled = false

    init(store: MonitorStore) {
        self.store = store
        let alerts = ChatAlerts()
        let outbox = ChatOutbox(store: store, alerts: alerts)
        let handover = ChatHandover(alerts: alerts)
        self.alerts = alerts
        self.outbox = outbox
        self.handover = handover
        relay = ChatRelay(store: store, alerts: alerts, outbox: outbox)
        prompts = PromptResponder(store: store, alerts: alerts)
        transcripts = TranscriptCache(store: store) { sessionId, items in outbox.pruneSentImages(sessionId: sessionId, items: items) }
        editors = EditorLauncher()
        listMode = RoomListMode(saved: UserDefaults.standard.string(forKey: RoomListMode.defaultsKey))
        // 部品から ChatModel へは弱い参照のクロージャだけで戻る（循環参照を作らない）。引き継ぎは部品同士の一方向の参照。
        outbox.hostedRoomExists = { [weak self] roomId in self?.hosted.contains { RoomID.hosted($0.id) == roomId } ?? false }
        outbox.roomIds = { [weak self] sessionId in self?.rooms.filter { $0.sessionId == sessionId }.map(\.id) ?? [] }
        outbox.isHandingOver = { handover.inProgress.contains($0) }
        handover.onResume = { [weak self] project, sessionId, roomId in self?.resume(project: project, sessionId: sessionId, from: roomId) }
        refreshRooms()
        restorer.model = self
        restorer.start()
    }

    // MARK: - ルーム

    /// 一覧を作り直し、読んだ値（feed・sessions・ホスト中のセッション・検索語・既読）が変わったら次の周回でもう一度作る。
    private func refreshRooms() {
        let (all, items, dirs) = withObservationTracking {
            let all = buildRooms()
            let keys = Self.keys(all)
            return (all, listItems(all, keys: keys), Self.directories(all, keys: keys))
        } onChange: { [weak self] in
            // onChange は値が書き換わる前に呼ばれるので、書き換え後に作り直す。
            Task { @MainActor [weak self] in self?.refreshRooms() }
        }
        rooms = all
        listItems = items
        directories = dirs
        discardVanishedExternalRooms(all)
        // 読めない間の設定は古いままなので、消えたとはみなさない。
        if SettingsStore.shared.problem == nil {
            SiteThumbnailStore.shared.prune(keeping: Set(SettingsStore.shared.projects.map(\.path)))
        }
    }

    /// 一覧から消えた外部ルームの添付を片付ける。未接続の間は一覧が古いので触らない。
    private func discardVanishedExternalRooms(_ all: [Room]) {
        guard store.connection.isConnected else { return }
        outbox.discardVanishedExternalRooms(alive: Set(all.map(\.id)))
    }

    private func buildRooms() -> [Room] {
        let connected = store.connection.isConnected
        var latestLine: [String: String] = [:]
        for item in store.feed where !item.text.isEmpty { latestLine[item.sessionId] = item.text }
        let unread = RoomGrouping.unreadCounts(feed: store.feed, since: lastSeen, defaultSince: launchedAt)

        var result: [Room] = hosted.map { session in
            let sessionId = session.resolveSessionId(store)
            let snapshot = sessionId.flatMap { store.session(id: $0) }
            let status = session.end != nil ? .stopped : liveStatus(of: session, snapshot: snapshot, connected: connected)
            let line = session.end?.message
                ?? sessionId.flatMap { latestLine[$0] } ?? snapshot.flatMap(Self.line(of:))
                ?? (session.pid == nil ? "起動中…" : "セッション開始")
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

    /// 動いているホスト中のセッションの状態（端末の確認・選択待ちを先に見て、監視があればその状態）。
    func liveStatus(of session: HostedSession) -> SessionStatus {
        let snapshot = session.resolveSessionId(store).flatMap { store.session(id: $0) }
        return liveStatus(of: session, snapshot: snapshot, connected: store.connection.isConnected)
    }

    private func liveStatus(of session: HostedSession, snapshot: SessionSnapshot?, connected: Bool) -> SessionStatus {
        if session.permissionPrompt != nil { return .permission }
        if session.inputBlock != nil { return .waiting }
        if connected, let snapshot { return snapshot.status }
        return Self.status(from: session.localStatus)
    }

    private static func keys(_ all: [Room]) -> [RoomKey] {
        all.map { room in
            RoomKey(id: room.id.string, name: room.name, status: room.status, activityAt: room.activityAt,
                    searchText: [room.branch, room.snapshot?.title, room.line, room.cwd].compactMap { $0 }.joined(separator: " "))
        }
    }

    private func listItems(_ all: [Room], keys: [RoomKey]) -> [RoomListItem] {
        let byKey = Dictionary(all.map { ($0.id.string, $0) }, uniquingKeysWith: { a, _ in a })
        return RoomGrouping.entries(RoomGrouping.group(keys, query: query)).compactMap { entry -> RoomListItem? in
            switch entry {
            case .header(let phase, let count): return RoomListItem(id: entry.id, kind: .phase(phase, count: count))
            case .row(let key): return byKey[key].map { RoomListItem(id: entry.id, kind: .row($0)) }
            }
        }
    }

    private static func directories(_ all: [Room], keys: [RoomKey]) -> [ProjectDirectory] {
        ProjectDirectories.directories(projects: SettingsStore.shared.projects,
                                       rooms: zip(keys, all).map { ProjectRoomKey(key: $0, cwd: $1.cwd) })
    }

    /// 「ディレクトリ」の一覧に描く段（検索語で絞る）。
    var directoryEntries: [ProjectDirectoryEntry] {
        ProjectDirectories.entries(ProjectDirectories.filter(directories, query: query))
    }

    /// 「ルーム」の一覧で見えている最初の行。
    var firstVisibleRoom: Room? {
        for item in listItems { if case .row(let room) = item.kind { return room } }
        return nil
    }

    /// 「ルーム」アイコンのバッジ。
    var attentionCount: Int { RoomListMode.attentionCount(rooms.map(\.status)) }

    var selectedRoom: Room? {
        guard let selection else { return nil }
        return rooms.first { $0.id == selection }
    }

    func select(_ id: RoomID) {
        selection = id
        center = .room
        markSelectedSeen()
    }

    func selectDirectory(_ id: UUID) {
        center = .directory(id)
    }

    /// 横断のリンク一覧を中央に出す（選択中のルームは残す）。
    func selectLinks() {
        center = .links
    }

    /// 詳細を出している中央のディレクトリ。設定から外された時は project が nil。
    var selectedDirectory: (id: UUID, directory: ProjectDirectory?)? {
        guard case .directory(let id) = center else { return nil }
        return (id, directories.first { $0.id == id })
    }

    /// 選択中のルームを既読にする（新着を受けるたびにも呼ぶ）。会話を出していない間は読んでいないので数えない。
    func markSelectedSeen() {
        guard center == .room, let sessionId = selectedRoom?.sessionId else { return }
        lastSeen[sessionId] = Date().timeIntervalSince1970 * 1000
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

    /// 同じプロジェクトで動いているホスト中のセッション（二重に起動しないため）。
    func runningSession(for project: ManagedProject) -> HostedSession? {
        hosted.first { $0.project.path == project.path && $0.end == nil }
    }

    func launch(_ project: ManagedProject) {
        if let running = runningSession(for: project) {
            select(.hosted(running.id))
            return
        }
        let session = host(project)
        select(.hosted(session.id))
        restorer.saveNow()
    }

    func close(_ session: HostedSession) {
        session.terminate()
        hosted.removeAll { $0.id == session.id }
        if selection == .hosted(session.id) { selection = nil }
        outbox.forgetRoom(.hosted(session.id))
        restorer.saveNow()
    }

    /// 引き継ぎで外部の claude を止められた。同じ会話を `--resume` で起動し、外部ルームの書きかけと添付を引き取る。
    private func resume(project: ManagedProject, sessionId: String, from roomId: RoomID) {
        let session = host(project, resuming: sessionId)
        outbox.move(from: roomId, to: .hosted(session.id))
        select(.hosted(session.id))
        restorer.saveNow()
    }

    /// 前回アプリが止まった時に動いていたセッションを同じ cwd で `--resume` する。書きかけも戻す。選択は未選択の時だけ移す。
    func resumeRestored(_ record: HostedSessionRecord) -> HostedSession {
        let session = host(SettingsStore.shared.project(atPath: record.cwd, orNamed: record.name), resuming: record.sessionId)
        if let draft = record.draft { outbox.drafts[.hosted(session.id)] = draft }
        if selection == nil { select(.hosted(session.id)) }
        return session
    }

    /// claude を起動して一覧に加える（上限で止まった時の知らせも受ける）。
    private func host(_ project: ManagedProject, resuming sessionId: String? = nil) -> HostedSession {
        let session = HostedSession(project: project, resumeSessionId: sessionId)
        session.onLimitReached = { [weak self] session in self?.limitReached(session) }
        hosted.append(session)
        session.start()
        return session
    }

    /// 終了の確認に使う、動いているホスト中のルーム。
    var runningHostedRooms: [QuitConfirmation.Room] {
        hosted.compactMap { session in
            guard session.end == nil else { return nil }
            return QuitConfirmation.Room(name: session.project.name, status: liveStatus(of: session))
        }
    }

    /// 上限で止めたセッション。記録は見送りに移し、続けて止まった分は 1 回の知らせにまとめる。
    private func limitReached(_ session: HostedSession) {
        restorer.deferLimited(session)
        pendingLimitNames.append(session.project.name)
        guard !limitAlertScheduled else { return }
        limitAlertScheduled = true
        // 全端末を止める通知は 1 つずつ届くので、少し待って集めてから出す。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showLimitAlert() }
    }

    private func showLimitAlert() {
        let names = pendingLimitNames
        pendingLimitNames = []
        guard !names.isEmpty else {
            limitAlertScheduled = false
            return
        }
        let alert = NSAlert()
        alert.messageText = "Max 枠の上限に達しました"
        alert.informativeText = LimitAlertText.message(names: names)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        limitAlertScheduled = false
        // 表示中に止まった分は、閉じた後に 1 回だけまとめて出す。
        if !pendingLimitNames.isEmpty {
            limitAlertScheduled = true
            DispatchQueue.main.async { [weak self] in self?.showLimitAlert() }
        }
    }
}
