import AppKit
import Observation
import MonitorKit

enum RoomID: Hashable {
    case hosted(UUID)
    case external(String)
}

enum RoomMode: Hashable, CaseIterable {
    case chat, terminal, github

    var title: String {
        switch self {
        case .chat: return "チャット"
        case .terminal: return "ターミナル"
        case .github: return "GitHub"
        }
    }

    var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .terminal: return "terminal"
        case .github: return "checklist"
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

    /// sessionId → 最後に開いた時刻（epoch ミリ秒）。未読数の起点。
    private var lastSeen: [String: Double] = [:]
    @ObservationIgnored private let launchedAt = Date().timeIntervalSince1970 * 1000

    /// 送信中の権限確認（monitor の key か "pty:<ルーム>"）。二度押しさせない。
    private(set) var busyPermissionKeys: Set<String> = []
    var alertMessage: String?

    @ObservationIgnored private var boards: [String: GitHubBoardView] = [:]
    @ObservationIgnored private var xcodeProjects: [String: URL?] = [:]
    @ObservationIgnored private var boardMappings: [String: BoardMapping?] = [:]

    init(store: MonitorStore) {
        self.store = store
        store.onTranscript = { [weak self] event in self?.receive(event) }
    }

    // MARK: - ルーム

    var rooms: [Room] {
        let connected = store.connection.isConnected
        var latestLine: [String: String] = [:]
        for item in store.feed where !item.text.isEmpty { latestLine[item.sessionId] = item.text }

        var result: [Room] = hosted.map { session in
            let sessionId = session.pid.flatMap { store.sessionId(forHostedPid: $0) }
            let snapshot = sessionId.flatMap { store.session(id: $0) }
            let status: SessionStatus
            if session.end != nil {
                status = .stopped
            } else if session.permissionPrompt != nil {
                status = .permission
            } else if connected, let snapshot {
                status = snapshot.status
            } else {
                status = Self.status(from: session.localStatus)
            }
            let line: String
            switch session.end {
            case .limitReached: line = "上限に達したため終了しました"
            case .exited: line = "claude は終了しました"
            case nil:
                line = sessionId.flatMap { latestLine[$0] } ?? snapshot.flatMap(Self.line(of:))
                    ?? (session.pid == nil ? "起動中…" : "セッション開始")
            }
            let activity = snapshot?.lastActivityAt ?? session.lastChangeAt.timeIntervalSince1970 * 1000
            return Room(id: .hosted(session.id), name: session.project.name, branch: snapshot?.branch, status: status,
                        line: line, activityAt: activity, sessionId: sessionId, cwd: session.project.path,
                        hosted: session, snapshot: snapshot, unread: unread(sessionId))
        }

        let hostedIds = Set(result.compactMap(\.sessionId))
        let hostedPids = Set(hosted.compactMap(\.pid))
        for snapshot in store.sessions where !hostedIds.contains(snapshot.sessionId) && !hostedPids.contains(snapshot.pid) {
            result.append(Room(id: .external(snapshot.sessionId), name: snapshot.name, branch: snapshot.branch,
                               status: snapshot.status,
                               line: latestLine[snapshot.sessionId] ?? Self.line(of: snapshot) ?? "",
                               activityAt: snapshot.lastActivityAt ?? snapshot.startedAt, sessionId: snapshot.sessionId,
                               cwd: snapshot.cwd, hosted: nil, snapshot: snapshot, unread: unread(snapshot.sessionId)))
        }
        return result
    }

    var groupedRooms: [RoomGroup] {
        let all = rooms
        let byKey = Dictionary(all.map { (key(of: $0.id), $0) }, uniquingKeysWith: { a, _ in a })
        let keys = all.map { room in
            RoomKey(id: key(of: room.id), name: room.name, status: room.status, activityAt: room.activityAt,
                    searchText: [room.branch, room.snapshot?.title, room.line, room.cwd].compactMap { $0 }.joined(separator: " "))
        }
        return RoomGrouping.group(keys, query: query).map { group in
            RoomGroup(phase: group.phase, rooms: group.ids.compactMap { byKey[$0] })
        }
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

    private func unread(_ sessionId: String?) -> Int {
        guard let sessionId else { return 0 }
        return RoomGrouping.unreadCount(feed: store.feed, sessionId: sessionId, since: lastSeen[sessionId] ?? launchedAt)
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
        // ローカル判定の「入力待ち」は権限プロンプトの文言で決めている。
        case .waitingInput: return .permission
        case .idle: return .idle
        }
    }

    private static func line(of snapshot: SessionSnapshot) -> String? {
        [snapshot.currentAction, snapshot.title, snapshot.lastPrompt].compactMap { $0 }.first { !$0.isEmpty }
    }

    // MARK: - ホストするセッション

    func launch(_ project: ManagedProject) {
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
        let result = session.send(text) { [weak self] in
            self?.drafts[room.id] = text
            self?.alertMessage = "送信の途中で権限の確認が出たため、送信を取りやめました。確認に答えてから送り直してください。"
        }
        switch result {
        case .sent: return true
        case .blockedByPermissionPrompt:
            alertMessage = "権限の確認に答えてから送ってください（今 Enter を送ると確認への「Yes」になります）。"
            return false
        case .empty, nil: return false
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

    func answerOnTerminal(_ session: HostedSession, allow: Bool) {
        let key = Self.ptyPermissionKey(session)
        guard !busyPermissionKeys.contains(key) else { return }
        busyPermissionKeys.insert(key)
        if !session.answerPermission(allow: allow) {
            alertMessage = "端末に権限確認が見当たりません。ターミナルで確認してください。"
        }
        // キーを送ってからプロンプトが消えるまで少し掛かるので、その間は押せないままにする。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.busyPermissionKeys.remove(key) }
    }

    // MARK: - 会話履歴

    func transcript(for sessionId: String?) -> [TranscriptItem] {
        guard let sessionId else { return [] }
        return transcripts[sessionId]?.items ?? []
    }

    /// 選択中のルームの履歴を揃える。未取得・再接続後なら GET する（SSE は `*` で常に張っている）。
    func ensureTranscript(for sessionId: String?) {
        guard let sessionId, store.connection.isConnected, !loadingTranscripts.contains(sessionId) else { return }
        guard transcripts[sessionId] == nil || staleTranscripts.contains(sessionId) else { return }
        var buffer = transcripts[sessionId] ?? TranscriptBuffer()
        let full = buffer.isEmpty
        let after = full ? nil : buffer.lastId
        buffer.beginFetch()
        transcripts[sessionId] = buffer
        staleTranscripts.remove(sessionId)
        loadingTranscripts.insert(sessionId)
        Task {
            defer { loadingTranscripts.remove(sessionId) }
            do {
                let response = try await store.client.fetchTranscript(sessionId: sessionId, after: after)
                transcripts[sessionId]?.apply(response, fullReplace: full)
                transcriptErrors[sessionId] = nil
            } catch MonitorError.http(status: 404, _, _) {
                // 最初の発話前はログが無い。以降は SSE で届くので空のまま待つ。
                transcriptErrors[sessionId] = nil
            } catch {
                transcriptErrors[sessionId] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                staleTranscripts.insert(sessionId)
            }
        }
    }

    /// monitor に繋ぎ直した。切れていた間の分を取り直す。
    func reconnected() {
        staleTranscripts = Set(transcripts.keys)
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
        if let session = room.hosted {
            mapping = GitHubBoard.mapping(forProject: session.project)
        } else if let project = ProjectStore.load().first(where: { $0.path == room.cwd }) {
            mapping = GitHubBoard.mapping(forProject: project)
        } else {
            mapping = GitHubBoard.mapping(forProjectNamed: room.name)
        }
        boardMappings[key] = mapping
        return mapping
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
