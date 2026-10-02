import AppKit
import ImageIO
import Observation
import MonitorKit

enum RoomID: Hashable {
    case hosted(UUID)
    case external(String)
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

/// チャット画面の状態。監視のストアと、アプリがホストするセッションを束ねる。
@MainActor
@Observable
final class ChatModel {
    let store: MonitorStore

    private(set) var hosted: [HostedSession] = []
    var selection: RoomID?
    var query = ""
    /// ルームごとの書きかけ。ルームを行き来しても残す。
    var drafts: [RoomID: String] = [:]
    /// ルームごとの送る前の添付。下書きと同じくルームを行き来しても残す。
    private(set) var attachments: [RoomID: [Attachment]] = [:]
    /// 添付 id → チップのサムネイル（添えた時に縮小して作る）。
    @ObservationIgnored private(set) var thumbnails: [UUID: NSImage] = [:]
    /// ルーム → 取り込み中の添付（取り込み id → 元ファイルのパス）。片付けで消えたら結果は捨てる。
    private(set) var importing: [RoomID: [UUID: String?]] = [:]
    @ObservationIgnored private let attachmentStore = AttachmentStore()
    /// 1 通に添えられる数。
    static let maxAttachments = 20
    /// ルーム → 画像を添えて送り、まだ transcript に載っていない発話（載るまで送った画像を吹き出しに出す）。
    private(set) var sentImages: [RoomID: [PendingImageMessage]] = [:]
    /// 吹き出しの画像の読み込みとキャッシュ。
    @ObservationIgnored private(set) lazy var imageLoader = ChatImageLoader(source: store.imageSource)

    private(set) var transcripts: [String: TranscriptBuffer] = [:]
    private(set) var loadingTranscripts: Set<String> = []
    @ObservationIgnored private var staleTranscripts: Set<String> = []

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

    /// 送信中の権限確認（Channels の key か "pty:<ルーム>"）。二度押しさせない。
    private(set) var busyPermissionKeys: Set<String> = []
    /// 選択肢カードに数秒だけ出す結果（"menu:<ルーム>" → 文言）。複数選択でチェックを切り替えた時など。
    private(set) var menuNotices: [String: String] = [:]
    var alertMessage: String?
    /// ルーム → 見出しの「VS Code / Xcode / 閉じる」の結果。数秒で消す。
    private(set) var editorNotes: [RoomID: EditorNote] = [:]
    /// Xcode に閉じるよう頼んでいる最中のルーム。二度押しさせない。
    private(set) var closingXcode: Set<RoomID> = []

    @ObservationIgnored private var xcodeProjects: [String: URL?] = [:]

    init(store: MonitorStore) {
        self.store = store
        store.onTranscript = { [weak self] event in self?.receive(event) }
        refreshRooms()
        let attachmentStore = attachmentStore
        Task.detached(priority: .utility) { attachmentStore.sweep() }
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

    /// 一覧から消えた外部ルームの添付を片付ける。未接続の間は一覧が古いので触らず、引き継ぎ中は移し先へ渡すので残す。
    private func discardVanishedExternalRooms(_ all: [Room]) {
        guard store.connection.isConnected else { return }
        let alive = Set(all.map(\.id))
        let stale = Set(attachments.keys).union(importing.keys).filter { id in
            guard case .external(let sessionId) = id else { return false }
            return !alive.contains(id) && !handingOver.contains(sessionId)
        }
        for id in stale { discardPendingAttachments(of: id) }
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
        drafts[.hosted(session.id)] = nil
        sentImages[.hosted(session.id)] = nil
        discardPendingAttachments(of: .hosted(session.id))
    }

    func send(_ text: String, to room: Room) -> Bool {
        guard let session = room.hosted, sendBlockedReason(for: room) == nil else { return false }
        let roomId = room.id
        let sending = attachments[roomId] ?? []
        let outgoingId = UUID().uuidString
        let sentAt = Date().timeIntervalSince1970 * 1000
        let result = session.send(text, attachments: sending) { [weak self] completion in
            self?.finishSend(completion, text: text, attachments: sending, outgoingId: outgoingId, in: roomId)
        }
        switch result {
        case .started(let pastedImages, let body):
            // サムネイルは結末が出るまで残す（本文を貼る前にやめたら入力欄へ戻すため）。
            attachments[roomId] = nil
            if let outgoing = PendingImageMessages.outgoing(id: outgoingId, text: text, sentBody: body,
                                                            pastedImagePaths: pastedImages, sentAt: sentAt) {
                sentImages[roomId, default: []].append(outgoing)
                scheduleSentImagesExpiry()
            }
            return true
        case .leftover:
            alertMessage = "端末側の入力欄に前回の本文や画像が残っているようです。"
                + "このままもう一度送ると、残っているものの後ろにつながって送られます。"
            return false
        case .blocked(.permission):
            alertMessage = "権限の確認に答えてから送ってください（今 Enter を送ると確認への「Yes」になります）。"
            return false
        case .blocked:
            alertMessage = "選択肢が出ているため送りませんでした（今 Enter を送るとその選択が確定します）。上のカードで答えてください。"
            return false
        case .busy, .empty, nil: return false
        }
    }

    private func finishSend(_ completion: SendCompletion, text: String, attachments sent: [Attachment],
                            outgoingId: String, in roomId: RoomID) {
        let roomExists = hosted.contains { RoomID.hosted($0.id) == roomId }
        // Enter まで届かなかった送信は記録されないので、仮の吹き出しを下げる。
        if completion != .submitted {
            sentImages[roomId]?.removeAll { $0.id == outgoingId }
            if sentImages[roomId]?.isEmpty == true { sentImages[roomId] = nil }
        }
        if completion.restoresDraft, roomExists {
            drafts[roomId] = ComposerRestore.draft(restoring: text, current: drafts[roomId] ?? "")
            let restored = ComposerRestore.attachments(restoring: sent, current: attachments[roomId] ?? [])
            for attachment in restored.dropped { forget(attachment, deletingFile: true) }
            attachments[roomId] = restored.merged.isEmpty ? nil : restored.merged
        } else {
            // 端末に渡った画像は受け手が後から読むことがあるので一時ファイルは残す（起動時の掃除に任せる）。
            let keepFiles = roomExists && completion != .ended
            for attachment in sent { forget(attachment, deletingFile: !keepFiles) }
        }
        if let notice = completion.notice, roomExists { alertMessage = notice }
    }

    /// 送信を一時的に止める理由（入力欄は書ける）。nil なら送れる。
    func sendBlockedReason(for room: Room) -> String? {
        if room.hosted?.isSending == true { return "送信中…" }
        if importing[room.id]?.isEmpty == false { return "添付を読み込み中…" }
        return nil
    }

    /// 入力欄を無効にする理由（送信時の判定と同じ条件）。nil なら送れる。外部ルームは伝言を送れるか。
    func inputDisabledReason(for room: Room) -> String? {
        guard room.hosted != nil else {
            if let sessionId = room.sessionId, handingOver.contains(sessionId) { return "引き継ぎ中…" }
            if !store.connection.isConnected { return "セッションの監視を始めています…" }
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
            case .menu: return "上の選択肢に答えると送れます"
            case nil: return nil
            }
        }
    }

    // MARK: - 添付

    func pendingAttachments(for roomId: RoomID) -> [Attachment] { attachments[roomId] ?? [] }

    func pendingImages(for roomId: RoomID) -> [PendingImageMessage] { sentImages[roomId] ?? [] }

    /// transcript に載った分と期限切れの仮の吹き出しを片付ける（表示側でも重ねないよう除いているが、溜め込まないため）。
    private func pruneSentImages(sessionId: String) {
        guard !sentImages.isEmpty, let items = transcripts[sessionId]?.items else { return }
        let now = Date().timeIntervalSince1970 * 1000
        for room in rooms where room.sessionId == sessionId {
            guard let messages = sentImages[room.id] else { continue }
            let rest = PendingImageMessages.unrecorded(messages, in: items, now: now)
            if rest.count != messages.count { sentImages[room.id] = rest.isEmpty ? nil : rest }
        }
    }

    /// 記録が来ないまま期限を過ぎたものを下げる（transcript の更新が止まっていても下げるため時刻で起こす）。
    private func expireSentImages() {
        let now = Date().timeIntervalSince1970 * 1000
        for (roomId, messages) in sentImages {
            let rest = messages.filter { !PendingImageMessages.isExpired($0, now: now) }
            if rest.count != messages.count { sentImages[roomId] = rest.isEmpty ? nil : rest }
        }
    }

    private func scheduleSentImagesExpiry() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(PendingImageMessages.lifetime + 1000))
            self?.expireSentImages()
        }
    }

    /// 取り込み中の数（チップの「読み込み中」に出す）。
    func importingCount(for roomId: RoomID) -> Int { importing[roomId]?.count ?? 0 }

    /// 写し・変換・サムネイル作りはバックグラウンドで行い、揃ったらメインで並べる。
    func attach(_ sources: [AttachmentSource], to roomId: RoomID) {
        let existing = attachments[roomId] ?? []
        var pending = importing[roomId] ?? [:]
        var accepted: [(UUID, AttachmentSource)] = []
        var overflow = false
        for source in sources {
            if let path = source.sourcePath,
               existing.contains(where: { $0.sourcePath == path }) || pending.values.contains(path) { continue }
            guard existing.count + pending.count < Self.maxAttachments else {
                overflow = true
                break
            }
            let id = UUID()
            pending[id] = source.sourcePath
            accepted.append((id, source))
        }
        importing[roomId] = pending.isEmpty ? nil : pending
        if overflow { alertMessage = "添付できなかったものがあります。\n1 通に添えられるのは \(Self.maxAttachments) 個までです" }
        guard !accepted.isEmpty else { return }
        let store = attachmentStore
        Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                accepted.map { id, source in ImportResult.make(id: id, source: source, store: store) }
            }.value
            self?.finishImport(results, in: roomId)
        }
    }

    private func finishImport(_ results: [ImportResult], in roomId: RoomID) {
        var failures: [String] = []
        for result in results {
            // 待つ間にルームが片付けられていたら、作った一時ファイルも消す。
            guard importing[roomId]?.removeValue(forKey: result.id) != nil else {
                if let attachment = result.attachment { attachmentStore.discard(attachment) }
                continue
            }
            if let attachment = result.attachment {
                if let image = result.thumbnail {
                    thumbnails[attachment.id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                }
                attachments[roomId, default: []].append(attachment)
            } else if let failure = result.failure {
                failures.append(failure)
            }
        }
        if importing[roomId]?.isEmpty == true { importing[roomId] = nil }
        if !failures.isEmpty { alertMessage = "添付できなかったものがあります。\n" + failures.joined(separator: "\n") }
    }

    func removeAttachment(_ attachment: Attachment, from roomId: RoomID) {
        attachments[roomId]?.removeAll { $0.id == attachment.id }
        if attachments[roomId]?.isEmpty == true { attachments[roomId] = nil }
        forget(attachment, deletingFile: true)
    }

    /// 送った後に外す。一時ファイルは受け手が後から読むことがあるので消さない（起動時の掃除に任せる）。
    private func clearAttachments(of roomId: RoomID) {
        for attachment in attachments.removeValue(forKey: roomId) ?? [] { forget(attachment, deletingFile: false) }
    }

    /// ルームが無くなった時に、送る前の添付・取り込み中の分・サムネイル・一時ファイルを片付ける。
    private func discardPendingAttachments(of roomId: RoomID) {
        importing[roomId] = nil
        for attachment in attachments.removeValue(forKey: roomId) ?? [] { forget(attachment, deletingFile: true) }
    }

    private func forget(_ attachment: Attachment, deletingFile: Bool) {
        thumbnails[attachment.id] = nil
        if deletingFile { attachmentStore.discard(attachment) }
    }

    // MARK: - 伝言（外部セッション）

    func notes(for sessionId: String?) -> [RelayNote] {
        guard let sessionId else { return [] }
        return relayNotes[sessionId] ?? []
    }

    /// 外部セッションへ伝言を送る。受け手には「別セッションからのメッセージ」として届き、本人の入力にはならない。
    func sendRelay(_ text: String, to room: Room) -> Bool {
        guard room.hosted == nil, let sessionId = room.sessionId, inputDisabledReason(for: room) == nil,
              sendBlockedReason(for: room) == nil else { return false }
        // 受け手は伝言を本文として読むだけなので、画像もパスで添える（Read で開ける）。
        let message = AttachmentFormat.outgoing(text: text, attachments: attachments[room.id] ?? [], pasteImages: false)
        let body = RelayNotes.normalized(message.body)
        guard !body.isEmpty else { return false }
        let imagePaths = (attachments[room.id] ?? []).filter { $0.kind == .image }.map(\.path)
        let note = RelayNote(text: body, sentAt: Date().timeIntervalSince1970 * 1000, imagePaths: imagePaths)
        relayNotes[sessionId, default: []].append(note)
        clearAttachments(of: room.id)
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
        if let pending = attachments.removeValue(forKey: roomId) { attachments[.hosted(session.id)] = pending }
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
            alertMessage = "端末に権限確認が見当たりません。既に答え終わっている可能性があります。"
            return
        case .changed:
            alertMessage = "権限の確認の内容が替わったため送りませんでした。カードの内容を確かめてから答えてください。"
            return
        }
        busyPermissionKeys.insert(key)
        // キーを送ってからプロンプトが消えるまで少し掛かるので、その間は押せないままにする。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.busyPermissionKeys.remove(key) }
    }

    static func ptyMenuKey(_ session: HostedSession) -> String { "menu:\(session.id.uuidString)" }

    /// `menu` はカードに出していたもの。`choice` はその選択肢の位置、nil なら取り消し（Esc）。
    /// 端末の今のメニューと違えば何も送らない（別の問いに答えないため）。
    func answerMenu(_ session: HostedSession, menu: MenuPrompt, choice: Int?) {
        let key = Self.ptyMenuKey(session)
        guard !busyPermissionKeys.contains(key) else { return }
        busyPermissionKeys.insert(key)
        session.answerMenu(menu, choice: choice) { [weak self] outcome in
            guard let self else { return }
            if outcome == .confirmed, let choice, menu.options[choice].checked != nil {
                // 複数選択では Enter はチェックの切り替えで、メニューは閉じない。
                self.showMenuNotice(key, "「\(menu.options[choice].label)」のチェックを切り替えました。")
            }
            self.finishMenuOperation(key, outcome: outcome)
        }
    }

    /// AskUserQuestion の問いのタブを 1 つ移る（→ / ←）。`menu` はカードに出していたもの。
    func moveMenuTab(_ session: HostedSession, menu: MenuPrompt, direction: MenuTabMover.Direction) {
        let key = Self.ptyMenuKey(session)
        guard !busyPermissionKeys.contains(key) else { return }
        busyPermissionKeys.insert(key)
        session.moveMenuTab(menu, direction: direction) { [weak self] outcome in
            self?.finishMenuOperation(key, outcome: outcome)
        }
    }

    private func showMenuNotice(_ key: String, _ text: String) {
        menuNotices[key] = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.menuNotices[key] == text { self?.menuNotices[key] = nil }
        }
    }

    private func finishMenuOperation(_ key: String, outcome: ClaudeTerminalView.MenuAnswerOutcome) {
        switch outcome {
        case .confirmed, .cancelled, .moved:
            break
        case .failed(.gone):
            alertMessage = "端末に選択肢が見当たりません。既に答え終わっている可能性があります。"
        case .failed(.vanished):
            alertMessage = "キーを送った後に端末の選択肢が読み取れなくなったため、Enter を押さずにやめました。端末の表示を確かめてから答えてください。"
        case .failed(.changed):
            alertMessage = "選択肢の内容が替わったため送りませんでした（矢印で ❯ を動かしていた場合は Enter を押していません）。カードの内容を確かめてから答えてください。"
        case .failed(.stuck):
            alertMessage = "選択肢の位置を合わせられなかった（またはタブが移らなかった）ため、Enter を押さずにやめました。カードの内容を確かめてからもう一度答えてください。"
        case .ended:
            alertMessage = "claude が終了した（終了・上限到達など）ため、選択肢を確定できませんでした。Enter は押していません。"
        case .unavailable:
            alertMessage = "この操作はここからはできません（文字入力の行に ❯ がある時はタブを移れません）。"
        case .settling:
            alertMessage = "直前に送った矢印キーが端末に反映されるのを待っています。少し待ってからもう一度押してください。"
        }
        // キーを送ってから画面が替わるまで・やめた移動の矢印が遅れて反映されうる間は、すぐには押せるようにしない。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.busyPermissionKeys.remove(key) }
    }

    /// 中身を読み取れない選択メニューを閉じる。`menu` はカードに出していた写し。
    func cancelUnreadableMenu(_ session: HostedSession, menu: UnreadableMenu) {
        let key = Self.ptyMenuKey(session)
        guard !busyPermissionKeys.contains(key) else { return }
        switch session.cancelUnreadableMenu(menu) {
        case .sent: break
        case .gone:
            alertMessage = "端末に読み取れない選択肢が見当たりません。既に答え終わったか、カードで答えられる形になった可能性があります。"
            return
        case .changed:
            alertMessage = "端末の選択肢が替わったため送りませんでした。カードの内容を確かめてから操作してください。"
            return
        }
        busyPermissionKeys.insert(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.busyPermissionKeys.remove(key) }
    }

    // MARK: - 会話履歴

    func transcript(for sessionId: String?) -> [TranscriptItem] {
        guard let sessionId else { return [] }
        return transcripts[sessionId]?.items ?? []
    }

    /// 選択中のルームの履歴を揃える。未取得・監視の開始し直し後なら取得する（追記は `.all` の購読で常に届く）。
    /// 取り直しも常に全件で置き換える（止まっていた間の発話は手元の末尾より前に入りうるので `after=` では埋まらない）。
    func ensureTranscript(for sessionId: String?) {
        guard let sessionId, store.connection.isConnected, !loadingTranscripts.contains(sessionId) else { return }
        guard transcripts[sessionId] == nil || staleTranscripts.contains(sessionId) else { return }
        var buffer = transcripts[sessionId] ?? TranscriptBuffer()
        buffer.beginFetch()
        transcripts[sessionId] = buffer
        staleTranscripts.remove(sessionId)
        loadingTranscripts.insert(sessionId)
        Task {
            // 最初の発話前はログが無い（nil）。以降は購読で届くので空のまま待つ。
            if let response = await store.fetchTranscript(sessionId: sessionId) {
                transcripts[sessionId]?.apply(response, fullReplace: true)
                pruneSentImages(sessionId: sessionId)
            }
            loadingTranscripts.remove(sessionId)
            // 取得中に監視を始め直した。その応答は古いかもしれないので取り直す。
            if staleTranscripts.contains(sessionId) { ensureTranscript(for: sessionId) }
        }
    }

    /// 監視を始め直した。止まっていた間の分を取り直す。
    func reconnected() {
        staleTranscripts = Set(transcripts.keys)
        ensureTranscript(for: selectedRoom?.sessionId)
    }

    private func receive(_ event: TranscriptEvent) {
        // 一度も開いていないセッションは、開いた時に GET でまとめて取る。
        guard transcripts[event.sessionId] != nil else { return }
        transcripts[event.sessionId]?.append(event.items)
        if event.items.contains(where: { !$0.images.isEmpty }) { pruneSentImages(sessionId: event.sessionId) }
    }

    // MARK: - 付随ビュー

    func xcodeProject(for room: Room) -> URL? {
        if let cached = xcodeProjects[room.cwd] { return cached }
        let found = TerminalPaneViewController.findXcodeProject(in: room.cwd)
        xcodeProjects[room.cwd] = found
        return found
    }

    func openInVSCode(_ room: Room) {
        let folder = URL(fileURLWithPath: room.cwd, isDirectory: true)
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
            showEditorNote(.failed("Visual Studio Code が見つかりません"), for: room.id)
            return
        }
        open(folder, with: app, for: room.id)
    }

    func openInXcode(_ room: Room) {
        guard let url = xcodeProject(for: room) else { return }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            showEditorNote(.failed("Xcode が見つかりません"), for: room.id)
            return
        }
        open(url, with: app, for: room.id)
    }

    /// Xcode 本体は終了させず、このルームのワークスペースだけを閉じる。
    func closeInXcode(_ room: Room) {
        guard let url = xcodeProject(for: room), !closingXcode.contains(room.id) else { return }
        let roomId = room.id
        closingXcode.insert(roomId)
        editorNotes[roomId] = nil
        Task { @MainActor [weak self] in
            let outcome = await XcodeClose.close(path: url.path)
            guard let self else { return }
            self.closingXcode.remove(roomId)
            self.showEditorNote(outcome, for: roomId)
        }
    }

    private func open(_ url: URL, with app: URL, for roomId: RoomID) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            let outcome: EditorOutcome = error.map { .failed("開けませんでした: \($0.localizedDescription)") } ?? .opened
            Task { @MainActor [weak self] in self?.showEditorNote(outcome, for: roomId) }
        }
    }

    private func showEditorNote(_ outcome: EditorOutcome, for roomId: RoomID) {
        let note = EditorNote(outcome: outcome)
        editorNotes[roomId] = note
        // 失敗は読み切れるよう長めに残す。
        let delay: Duration = outcome.isFailure ? .seconds(8) : .seconds(4)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            // 後から出した結果を古いタイマーで消さない。
            if self?.editorNotes[roomId]?.id == note.id { self?.editorNotes[roomId] = nil }
        }
    }
}

/// バックグラウンドでの添付の取り込み 1 件分の結果。CGImage は作った後に書き換えないので渡してよい。
private struct ImportResult: @unchecked Sendable {
    let id: UUID
    let attachment: Attachment?
    let thumbnail: CGImage?
    let failure: String?

    static func make(id: UUID, source: AttachmentSource, store: AttachmentStore) -> ImportResult {
        do {
            let attachment = try store.ingest(source)
            let thumbnail = attachment.kind == .image ? AttachmentStore.thumbnail(of: attachment.path) : nil
            return ImportResult(id: id, attachment: attachment, thumbnail: thumbnail, failure: nil)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return ImportResult(id: id, attachment: nil, thumbnail: nil, failure: reason)
        }
    }
}

struct EditorNote: Equatable {
    let id = UUID()
    let outcome: EditorOutcome
}
