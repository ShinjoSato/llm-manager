import DeckCore
import Foundation
import Network
import Observation
import UIKit

/// 接続・一覧・会話・操作をまとめて持つ（画面はこれを読むだけ）。
@MainActor
@Observable
final class AppModel {
    enum Connection: Equatable {
        case unpaired
        case connecting
        case connected
        /// 切れていて、`retryAt` につなぎ直す。
        case waiting(RemoteIssue, retryAt: Date)
        /// 再ペアリングしないと直らない（指紋違い・取り消し）。
        case failed(RemoteIssue)
        /// アプリが裏に回っている間は張らない。
        case paused

        var isConnected: Bool { self == .connected }
    }

    private(set) var pairing: RemotePairing?
    private(set) var connection: Connection = .unpaired
    private(set) var state: RemoteState?
    /// 最後に一覧が届いた時刻（切れている間は古い一覧を出すので併記する）。
    private(set) var stateUpdatedAt: Date?
    private(set) var transcripts: [String: TranscriptBuffer] = [:]
    private(set) var loadingTranscripts: Set<String> = []
    private(set) var unread: [String: Int] = [:]
    /// 送った伝言（外部セッションは transcript に載らないので手元で差し込む）。
    private(set) var relayNotes: [String: [RelayNote]] = [:]
    /// 直前の操作の結果（ルームごと）。
    private(set) var notices: [String: Notice] = [:]
    /// 送っている最中の操作（二度押しさせない）。
    private(set) var inFlight: Set<String> = []
    var drafts: [String: String] = [:]
    /// 確認待ちのペアリング（読み取った・開かれたリンク）。確認するまで使わない。
    var pendingOffer: PairingOffer?
    private(set) var pairingInProgress = false
    var pairingError: String?
    /// 今開いている会話（未読を数えない・取り直す対象）。
    private(set) var openSessionId: String?
    private(set) var onWiFi = true
    /// 起動直後に開くルーム（画面確認用）。
    var launchRoomId: String?

    struct Notice: Equatable {
        var text: String
        var isError: Bool
        var at: Date
    }

    private let keychain: PairingKeychain
    private var client: RemoteClient?
    private var streamTask: Task<Void, Never>?
    /// 今の接続の世代。止めた・張り直した後に古い接続が状態を書き換えないよう、自分の世代の時だけ書く。
    private var runGeneration = 0
    private var backoff = RemoteBackoff()
    private var hostIndex = 0
    /// 会話を持つのは直近に開いたルームだけ（他は開き直した時に取り直す）。
    private var recentSessions: [String] = []
    private static let keptTranscripts = 4
    private let pathMonitor = NWPathMonitor()
    /// 画面確認用のデータで動いている（通信しない）。
    private var isDemo = false

    init(keychain: PairingKeychain = PairingKeychain(), startMonitoring: Bool = true) {
        self.keychain = keychain
        pairing = keychain.load()
        connection = pairing == nil ? .unpaired : .paused
        if startMonitoring { monitorNetwork() }
    }

    #if DEBUG
    /// 画面の確認用（通信しない）。
    init(demo state: RemoteState, pairing: RemotePairing, transcripts: [String: [TranscriptItem]], open: String?) {
        keychain = PairingKeychain(service: "demo")
        self.pairing = pairing
        self.state = state
        stateUpdatedAt = Date()
        connection = .connected
        for (sid, items) in transcripts {
            var buffer = TranscriptBuffer()
            buffer.apply(TranscriptResponse(sessionId: sid, items: items, reset: false), fullReplace: true)
            self.transcripts[sid] = buffer
        }
        openSessionId = open
        unread = ["s-sandora": 2]
        isDemo = true
    }
    #endif

    var serverName: String { pairing?.serverName ?? "Mac" }
    var rooms: [RemoteRoom] { state?.rooms ?? [] }

    func room(_ id: String) -> RemoteRoom? { rooms.first { $0.id == id } }

    // MARK: - 接続

    /// 前に出す・ペアリングした・再接続を押した時。
    func connect() {
        guard !isDemo else { return }
        guard let pairing else {
            connection = .unpaired
            return
        }
        stopStream()
        backoff.reset()
        let generation = runGeneration
        streamTask = Task { [weak self] in await self?.run(pairing, generation: generation) }
    }

    private func stopStream() {
        streamTask?.cancel()
        streamTask = nil
        runGeneration += 1
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == runGeneration && !Task.isCancelled
    }

    /// 裏に回った時。iOS は裏で接続を保てないので閉じ、前に出たら張り直す。
    func pause() {
        guard !isDemo else { return }
        stopStream()
        if pairing != nil, case .failed = connection { return }
        if pairing != nil { connection = .paused }
    }

    private func run(_ pairing: RemotePairing, generation: Int) async {
        while isCurrent(generation) {
            let hosts = pairing.hosts
            let host = hosts[hostIndex % hosts.count]
            let client = RemoteClient(pairing: pairing, host: host)
            self.client?.invalidate()
            self.client = client
            if connection != .connected { connection = .connecting }
            var issue: RemoteIssue
            do {
                for try await event in client.events(transcripts: ["*"]) {
                    guard isCurrent(generation) else { return }
                    handle(event)
                }
                // 止めた時もストリームは何事もなく終わるので、閉じられたとみなす前に確かめる。
                guard isCurrent(generation) else { return }
                // 相手が閉じた（mac が口を閉じた・同じ端末の新しいストリームに替わった・取り消し）。次の接続で理由が分かる。
                issue = RemoteIssue(kind: .unreachable, title: "Mac が接続を閉じました", detail: RemoteIssue.unreachableHelp)
            } catch {
                guard isCurrent(generation), !(error is CancellationError) else { return }
                issue = RemoteIssue.from(error)
                if issue.needsPairing {
                    connection = .failed(issue)
                    return
                }
                // 予備の名前（mDNS）があれば、届かない時は次はそちらで試す。
                if issue.kind == .unreachable, hosts.count > 1 { hostIndex += 1 }
            }
            let delay = issue.kind == .throttled ? RemoteBackoff.throttledDelay() : backoff.next()
            connection = .waiting(issue, retryAt: Date().addingTimeInterval(delay))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func handle(_ event: RemoteStreamEvent) {
        switch event {
        case .state(let newState):
            let firstAfterConnect = connection != .connected
            state = newState
            stateUpdatedAt = Date()
            if firstAfterConnect {
                connection = .connected
                backoff.reset()
                // 張り直した後は取りこぼしがあり得るので、持っている会話は全件を取り直す。
                for sid in recentSessions { fetchTranscript(sid) }
            }
        case .transcript(let event):
            if transcripts[event.sessionId] != nil {
                transcripts[event.sessionId]?.append(event.items)
            }
            if event.sessionId != openSessionId {
                let replies = event.items.filter { $0.kind == .assistant }.count
                if replies > 0 { unread[event.sessionId, default: 0] += replies }
            }
        case .ping:
            break
        }
    }

    private func monitorNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = self.onWiFi != wifi
                self.onWiFi = wifi
                // Wi-Fi に戻ったら待たずにつなぎ直す。
                if changed, wifi, case .waiting = self.connection { self.connect() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "claude-deck.path"))
    }

    // MARK: - ペアリング

    func offer(_ offer: PairingOffer) {
        pairingError = nil
        pendingOffer = offer
    }

    func offerLink(_ text: String, source: PairingOffer.Source) {
        switch PairingOffer.parse(text, source: source) {
        case .success(let offer): self.offer(offer)
        case .failure(let error): pairingError = error.message
        }
    }

    /// 確認画面で「ペアリングする」を押した時だけ呼ぶ。
    func confirmPairing(_ offer: PairingOffer) async {
        let payload = offer.payload
        if let problem = payload.addressProblem ?? payload.problem(now: Date().timeIntervalSince1970 * 1000) {
            pairingError = problem
            return
        }
        pairingInProgress = true
        defer { pairingInProgress = false }
        let client = RemoteClient(host: payload.host, port: payload.port, pin: payload.fingerprint, token: nil)
        defer { client.invalidate() }
        do {
            let response = try await client.pair(token: payload.token, deviceName: UIDevice.current.name)
            let pairing = RemotePairing(payload: payload, response: response, pairedAt: Date().timeIntervalSince1970 * 1000)
            try keychain.save(pairing)
            pendingOffer = nil
            pairingError = nil
            adopt(pairing)
        } catch let error as PairingKeychain.Failure {
            pairingError = "キーチェーンに保存できませんでした（\(error)）。"
        } catch {
            let issue = RemoteIssue.from(error)
            pairingError = issue.title + "\n" + issue.detail
        }
    }

    private func adopt(_ pairing: RemotePairing) {
        stopStream()
        self.pairing = pairing
        state = nil
        stateUpdatedAt = nil
        transcripts = [:]
        recentSessions = []
        unread = [:]
        relayNotes = [:]
        notices = [:]
        hostIndex = 0
        connect()
    }

    static let unpairNotDeliveredNote = "Mac で取り消せたか確かめられなかったため、Mac の「iPhone 連携」の端末一覧からも取り消してください。"

    /// この iPhone の登録を mac から取り消し、手元の鍵も消す（mac で取り消せなかった時は案内を返す。手元は必ず消す）。
    func unpair() async -> String? {
        var revoked = false
        if let client {
            let result = try? await client.unpair()
            revoked = result?.ok == true
        }
        forget()
        return revoked ? nil : Self.unpairNotDeliveredNote
    }

    /// 手元の鍵だけ消す（指紋違い・取り消し済みの時）。
    func forget() {
        stopStream()
        client?.invalidate()
        client = nil
        keychain.delete()
        pairing = nil
        state = nil
        stateUpdatedAt = nil
        transcripts = [:]
        recentSessions = []
        connection = .unpaired
    }

    // MARK: - 会話

    func open(sessionId: String?) {
        openSessionId = sessionId
        guard let sessionId else { return }
        unread[sessionId] = nil
        recentSessions.removeAll { $0 == sessionId }
        recentSessions.insert(sessionId, at: 0)
        for dropped in recentSessions.dropFirst(Self.keptTranscripts) { transcripts[dropped] = nil }
        recentSessions = Array(recentSessions.prefix(Self.keptTranscripts))
        fetchTranscript(sessionId)
    }

    func close(sessionId: String?) {
        if openSessionId == sessionId { openSessionId = nil }
    }

    /// ストリームを張った後に全件を取り、届いていた追記と id で重ねる。
    private func fetchTranscript(_ sessionId: String) {
        guard let client, connection == .connected else { return }
        var buffer = transcripts[sessionId] ?? TranscriptBuffer()
        buffer.beginFetch()
        transcripts[sessionId] = buffer
        loadingTranscripts.insert(sessionId)
        Task {
            defer { loadingTranscripts.remove(sessionId) }
            guard let response = try? await client.transcript(sessionId: sessionId) else { return }
            guard transcripts[sessionId] != nil else { return }
            transcripts[sessionId]?.apply(response, fullReplace: true)
        }
    }

    func items(for sessionId: String?) -> [TranscriptItem] {
        sessionId.flatMap { transcripts[$0]?.items } ?? []
    }

    func entries(for room: RemoteRoom) -> [ChatEntry] {
        let items = items(for: room.sessionId)
        let notes = room.sessionId.flatMap { relayNotes[$0] } ?? []
        return ChatTimeline.entries(from: items, notes: notes)
    }

    func imageData(sessionId: String, itemId: String, index: Int) async -> Data? {
        try? await client?.image(sessionId: sessionId, itemId: itemId, index: index)
    }

    // MARK: - 操作

    func isBusy(_ room: RemoteRoom) -> Bool {
        room.busy || inFlight.contains(room.id)
    }

    func decide(_ room: RemoteRoom, _ permission: PendingPermission, allow: Bool) {
        perform(room, .permission) { client in
            try await client.decide(key: permission.key, decision: allow ? .allow : .deny)
        }
    }

    func answerTerminal(_ room: RemoteRoom, _ prompt: RemoteTerminalPermission, allow: Bool) {
        perform(room, .permission) { client in
            try await client.answerTerminalPermission(roomId: room.id, promptId: prompt.promptId, decision: allow ? .allow : .deny)
        }
    }

    /// `choice` が nil なら取り消し（Esc）。押した時の `menuId` で送る（替わっていれば mac が断る）。
    func answerMenu(_ room: RemoteRoom, _ menu: RemoteMenu, choice: Int?, confirmExit: Bool = false) {
        let body = choice.map { RemoteMenuAnswerRequest(menuId: menu.menuId, choice: $0) }
            ?? RemoteMenuAnswerRequest(menuId: menu.menuId, cancel: true, confirmExit: confirmExit ? true : nil)
        perform(room, .menu) { client in try await client.answerMenu(roomId: room.id, body) }
    }

    func moveTab(_ room: RemoteRoom, _ menu: RemoteMenu, _ direction: RemoteTabDirection) {
        perform(room, .menuTab) { client in
            try await client.moveMenuTab(roomId: room.id, RemoteMenuTabRequest(menuId: menu.menuId, direction: direction))
        }
    }

    func dismiss(_ room: RemoteRoom, _ menu: RemoteUnreadableMenu, confirmExit: Bool) {
        perform(room, .menuDismiss) { client in
            try await client.dismissMenu(roomId: room.id, RemoteMenuDismissRequest(menuId: menu.menuId, confirmExit: confirmExit ? true : nil))
        }
    }

    /// 送れたら（mac が受け付けたら）入力欄を空にする。
    func send(_ room: RemoteRoom) {
        let text = (drafts[room.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 送っている最中は送らない（メモだけ残って送信中のままにならないよう、メモを作る前に確かめる）。
        guard !text.isEmpty, !inFlight.contains(room.id) else { return }
        let relay = room.send.mode == .relay
        let note = RelayNote(text: text, sentAt: Date().timeIntervalSince1970 * 1000)
        if relay, let sid = room.sessionId { relayNotes[sid, default: []].append(note) }
        perform(room, relay ? .relay : .message) { client in
            try await client.sendMessage(roomId: room.id, text: text)
        } completion: { [weak self] result in
            guard let self else { return }
            if result?.ok == true, self.drafts[room.id]?.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                self.drafts[room.id] = ""
            }
            guard relay, let sid = room.sessionId, let index = self.relayNotes[sid]?.firstIndex(where: { $0.id == note.id }) else { return }
            if result?.ok == true {
                self.relayNotes[sid]?[index].state = .sent
            } else {
                let reason = result.flatMap { RemoteResultText.text(for: $0, operation: .relay) } ?? "Mac に届きませんでした"
                self.relayNotes[sid]?[index].state = .failed(reason)
            }
        }
    }

    private func perform(_ room: RemoteRoom, _ operation: RemoteOperationKind,
                         _ call: @escaping @Sendable (RemoteClient) async throws -> RemoteActionResult,
                         completion: ((RemoteActionResult?) -> Void)? = nil) {
        guard !inFlight.contains(room.id) else { return }
        guard let client, connection == .connected else {
            notices[room.id] = Notice(text: "Mac につながっていないので送れません。", isError: true, at: Date())
            completion?(nil)
            return
        }
        inFlight.insert(room.id)
        notices[room.id] = nil
        Task {
            defer { inFlight.remove(room.id) }
            do {
                let result = try await call(client)
                if let text = RemoteResultText.text(for: result, operation: operation) {
                    notices[room.id] = Notice(text: text, isError: !result.ok, at: Date())
                }
                completion?(result)
            } catch {
                let issue = RemoteIssue.from(error)
                notices[room.id] = Notice(text: "\(issue.title)。届いたかどうか分からないので、画面の様子を確かめてください。", isError: true, at: Date())
                completion?(nil)
            }
        }
    }

    func clearNotice(_ roomId: String) {
        notices[roomId] = nil
    }
}
