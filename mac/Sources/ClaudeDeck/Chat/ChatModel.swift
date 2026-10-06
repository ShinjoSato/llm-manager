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

/// 画面に 1 つだけ出す警告。どの部品からでも出せるよう ChatModel と分けて持つ。
@MainActor
@Observable
final class ChatAlerts {
    var message: String?
}

/// チャット画面の状態。監視のストアとアプリがホストするセッションからルーム一覧を組み立て、
/// 送信・伝言・引き継ぎ・権限の回答・会話・エディタの部品を束ねる（それぞれの状態と処理は部品が持つ）。
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

    private(set) var hosted: [HostedSession] = []
    var selection: RoomID?
    var query = ""

    /// ルーム一覧。feed・セッション・ホスト中のセッションが変わった時だけ作り直す（描画のたびに feed を走査しない）。
    private(set) var rooms: [Room] = []
    private(set) var groupedRooms: [RoomGroup] = []
    /// 一覧に描く順の見出しと行。
    private(set) var listItems: [RoomListItem] = []

    /// sessionId → 最後に開いた時刻（epoch ミリ秒）。未読数の起点。
    private var lastSeen: [String: Double] = [:]
    @ObservationIgnored private let launchedAt = Date().timeIntervalSince1970 * 1000

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
        // 部品から ChatModel へは弱い参照のクロージャだけで戻る（循環参照を作らない）。
        outbox.hostedRoomExists = { [weak self] roomId in self?.hosted.contains { RoomID.hosted($0.id) == roomId } ?? false }
        outbox.roomIds = { [weak self] sessionId in self?.rooms.filter { $0.sessionId == sessionId }.map(\.id) ?? [] }
        outbox.isHandingOver = { handover.inProgress.contains($0) }
        handover.onResume = { [weak self] project, sessionId, roomId in self?.resume(project: project, sessionId: sessionId, from: roomId) }
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
        discardVanishedExternalRooms(all)
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
        let byKey = Dictionary(all.map { ($0.id.string, $0) }, uniquingKeysWith: { a, _ in a })
        let keys = all.map { room in
            RoomKey(id: room.id.string, name: room.name, status: room.status, activityAt: room.activityAt,
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

    /// 選択中のルームを既読にする（新着を受けるたびにも呼ぶ）。
    func markSelectedSeen() {
        guard let sessionId = selectedRoom?.sessionId else { return }
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
        outbox.forgetRoom(.hosted(session.id))
    }

    /// 引き継ぎで外部の claude を止められた。同じ会話を `--resume` で起動し、外部ルームの書きかけと添付を引き取る。
    private func resume(project: ManagedProject, sessionId: String, from roomId: RoomID) {
        let session = HostedSession(project: project, resumeSessionId: sessionId)
        session.onLimitReached = { [weak self] session in self?.showLimitAlert(for: session) }
        hosted.append(session)
        session.start()
        outbox.move(from: roomId, to: .hosted(session.id))
        select(.hosted(session.id))
    }

    private func showLimitAlert(for session: HostedSession) {
        let alert = NSAlert()
        alert.messageText = "Max 枠の上限に達しました"
        alert.informativeText = "「\(session.project.name)」のセッションを強制終了しました。枠がリセットされるまでお待ちください。（API 課金は発生しません）"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
