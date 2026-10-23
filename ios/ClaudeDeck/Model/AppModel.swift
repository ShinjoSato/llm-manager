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
    /// mac に終了の確認を求められた操作（ルームごと）。終了の印を付けない古い mac には断られてから確かめる。
    private(set) var exitConfirmations: [String: PendingExitConfirmation] = [:]
    /// 求められた確認を出しておく長さ。過ぎてから急に出さない。
    static let exitConfirmationLifetime: TimeInterval = 60

    struct PendingExitConfirmation: Equatable {
        var confirmation: ExitConfirmation
        var askedAt: Date
    }
    var drafts: [String: String] = [:]
    /// ルームごとの送る前の画像（送れる形に整えたもの）。
    private(set) var composerImages: [String: [ComposerImage]] = [:]
    /// ルーム → 選んだ回 → 整えている最中の枚数。捨てた回の写真は整え終わっても足さない。
    private var preparingBatches: [String: [UUID: Int]] = [:]
    /// ルームごとの、写真を読み込んで整えている最中の枚数。
    var preparingImages: [String: Int] {
        preparingBatches.compactMapValues { batches in
            let count = batches.values.reduce(0, +)
            return count > 0 ? count : nil
        }
    }
    /// 確認待ちのペアリング（読み取った・開かれたリンク）。確認するまで使わない。
    var pendingOffer: PairingOffer?
    private(set) var pairingInProgress = false
    var pairingError: PairingError?
    /// 今開いている会話（未読を数えない・取り直す対象）。
    private(set) var openSessionId: String?
    private var openViewer: UUID?
    /// 端末全体の経路が Wi-Fi（有線）か。最初の判定が届くまでは nil。
    private(set) var onWiFi: Bool?
    /// 起動直後に開くルーム（画面確認用）。
    var launchRoomId: String?
    /// 通知から開くルーム（一覧の画面が受け取って会話へ進む）。
    var requestedRoomId: String?
    /// 開いた通知のうち、まだルームが見つかっていないもの（つながって一覧が届いたら開く）。
    private(set) var pendingNotice: AttentionNoticeRoute?
    private var pendingNoticeAt: Date?
    /// 預かった通知の行き先を開く期限。過ぎてからつながっても、もう関係の無いルームへ急に移らないようにする。
    static let pendingNoticeLifetime: TimeInterval = 30 * 60
    /// 時刻（試験で差し替える）。
    var clock: () -> Date = Date.init
    /// 通知から開けなかった時の案内。
    var noticeHint: String?
    /// 要対応の通知（iCloud の購読）の入り切り。
    let notifications: AttentionNotifications
    /// 開いている「端末の画面」（同時に 1 つだけ）。
    private(set) var terminalWatch: TerminalWatch?
    private var terminalTask: Task<Void, Never>?
    /// 端末の表示を取り直す間隔（試験で縮める）。
    var terminalRefreshInterval: Duration = .milliseconds(700)
    /// つながっていない間は取りに行かず、この倍の間隔で待つ。
    static let terminalIdleFactor = 4
    /// 重なった取り直しの遅れた応答で新しい表示を上書きしないための番号。
    @ObservationIgnored private var terminalOrder = RemoteResponseOrder()
    /// 端末の画面を開いている間に閉じられた会話の画面（シートを閉じた時に閉じる）。
    @ObservationIgnored private var deferredCloseViewer: UUID?

    /// ペアリングの失敗。設定へ導くかを決めるため、接続の失敗なら理由も持つ。
    struct PairingError: Equatable {
        var text: String
        var issue: RemoteIssue?

        init(_ text: String) { self.text = text }
        init(issue: RemoteIssue) {
            text = issue.title + "\n" + issue.detail
            self.issue = issue
        }

        var needsSettings: Bool { issue?.needsSettings == true }
    }

    struct Notice: Equatable {
        var text: String
        var isError: Bool
    }

    /// 「端末の画面」のシートの様子。
    struct TerminalWatch: Equatable {
        let roomId: String
        /// シートごとの印（開き直しで新旧の開く・閉じるが前後しても、最後に開いたシートだけが止められる）。
        let viewer: UUID
        var screen: RemoteTerminalScreen?
        /// 表示を取れなかった理由（取れたら消す）。
        var problem: String?
        /// 直前に押したキーの結果。
        var notice: Notice?
        var sending = false
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

    init(keychain: PairingKeychain = PairingKeychain(), startMonitoring: Bool = true,
         notifications: AttentionNotifications? = nil) {
        self.keychain = keychain
        self.notifications = notifications ?? .live()
        pairing = keychain.load()
        connection = pairing == nil ? .unpaired : .paused
        if startMonitoring { monitorNetwork() }
    }

    #if DEBUG
    /// 画面の確認用（通信しない）。
    init(demo state: RemoteState, pairing: RemotePairing, transcripts: [String: [TranscriptItem]], open: String?,
         notifications: AttentionNotifications? = nil) {
        keychain = PairingKeychain(service: "demo")
        self.notifications = notifications ?? .live()
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

    /// 試験用: 切れた・つながって一覧が届いた、を起こす。
    func simulateDisconnected() { connection = .paused }
    func simulateReceived(_ state: RemoteState) { handle(.state(state)) }
    func simulateReceived(_ transcript: TranscriptEvent) { handle(.transcript(transcript)) }
    /// 試験用: 会話を全件取りに行った回数（接続していなくても数える）。
    private(set) var transcriptFetchCount = 0
    /// 試験用: 端末の表示を取りに行った回数（接続していなくても数える）。
    private(set) var terminalFetchCount = 0
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
                issue = await diagnose(error, host: host, port: pairing.port)
                guard isCurrent(generation) else { return }
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
            dropImagesOfVanishedRooms()
            dropStaleExitConfirmations()
            if firstAfterConnect {
                connection = .connected
                backoff.reset()
                // 張り直した後は取りこぼしがあり得るので、持っている会話は全件を取り直す。
                for sid in recentSessions { fetchTranscript(sid) }
            }
            resolvePendingNotice()
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

    /// 許可と Wi-Fi のどちらか分からないエラーの時だけ、接続先への経路を確かめて言い分ける。
    private func diagnose(_ error: Error, host: String, port: Int) async -> RemoteIssue {
        guard RemoteIssue.needsPathCheck(error) else { return RemoteIssue.from(error) }
        let path = await PathProbe.check(host: host, port: port)
        return RemoteIssue.diagnose(error, path: path, onWiFi: onWiFi)
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

    // MARK: - 通知から開く

    /// 通知を開いた時。一覧にルームがあればそこへ進み、無ければつながって一覧が届くまで預かる。
    func openFromNotice(_ route: AttentionNoticeRoute) {
        noticeHint = nil
        if let room = route.resolve(in: rooms) {
            pendingNotice = nil
            requestedRoomId = room.id
            return
        }
        pendingNotice = route
        pendingNoticeAt = clock()
        if pairing == nil {
            noticeHint = "通知のルームを開くには、Mac の claude-deck とペアリングしてください。"
        } else if !connection.isConnected {
            noticeHint = "Mac につながったら通知のルームを開きます。Mac と同じ Wi-Fi にいるか確かめてください。"
        } else {
            resolvePendingNotice()
        }
    }

    /// 開いている会話のルーム（その会話の知らせはアプリの中では出さない）。
    var openRoomId: String? {
        guard let openSessionId else { return nil }
        return rooms.first { $0.sessionId == openSessionId }?.id
    }

    private func resolvePendingNotice() {
        guard let route = pendingNotice, connection.isConnected else { return }
        pendingNotice = nil
        if let at = pendingNoticeAt, clock().timeIntervalSince(at) > Self.pendingNoticeLifetime {
            noticeHint = nil
            return
        }
        if let room = route.resolve(in: rooms) {
            noticeHint = nil
            requestedRoomId = room.id
        } else {
            noticeHint = "通知のルームが見つかりません。もう解消したか、閉じられた可能性があります。"
        }
    }

    // MARK: - ペアリング

    func offer(_ offer: PairingOffer) {
        pairingError = nil
        pendingOffer = offer
    }

    func offerLink(_ text: String, source: PairingOffer.Source) {
        switch PairingOffer.parse(text, source: source) {
        case .success(let offer): self.offer(offer)
        case .failure(let error): pairingError = PairingError(error.message)
        }
    }

    /// 確認画面で「ペアリングする」を押した時だけ呼ぶ。
    func confirmPairing(_ offer: PairingOffer) async {
        let payload = offer.payload
        if let problem = offer.problem() {
            pairingError = PairingError(problem)
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
            pairingError = PairingError("キーチェーンに保存できませんでした（\(error)）。")
        } catch {
            pairingError = PairingError(issue: await diagnose(error, host: payload.host, port: payload.port))
        }
    }

    private func adopt(_ pairing: RemotePairing) {
        stopStream()
        self.pairing = pairing
        clearRoomData()
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
        clearRoomData()
        connection = .unpaired
    }

    /// 前の Mac の一覧と会話・送る前の画像を捨てる。
    private func clearRoomData() {
        terminalTask?.cancel()
        terminalTask = nil
        terminalWatch = nil
        finishDeferredClose()
        state = nil
        stateUpdatedAt = nil
        transcripts = [:]
        recentSessions = []
        composerImages = [:]
        preparingBatches = [:]
        exitConfirmations = [:]
    }

    /// 一覧から消えたルームの送る前の画像を捨てる（整えている途中の分は終わった時に足さない）。
    private func dropImagesOfVanishedRooms() {
        let alive = Set(rooms.map(\.id))
        composerImages = composerImages.filter { alive.contains($0.key) }
        preparingBatches = preparingBatches.filter { alive.contains($0.key) }
    }

    /// 確認を求められた時のメニューがもう出ていなければ、確認も出さない。
    private func dropStaleExitConfirmations() {
        let menus = Dictionary(rooms.map { ($0.id, $0.menu?.menuId) }, uniquingKeysWith: { first, _ in first })
        let now = clock()
        exitConfirmations = exitConfirmations.filter {
            menus[$0.key] == $0.value.confirmation.menuId && now.timeIntervalSince($0.value.askedAt) <= Self.exitConfirmationLifetime
        }
    }

    // MARK: - 会話

    /// `viewer` は会話の画面ごとの印。幅が変わって画面が作り直されると新旧の開く・閉じるが前後するので、最後に開いた画面だけが閉じられる。
    func open(sessionId: String?, viewer: UUID) {
        deferredCloseViewer = nil
        let reopened = sessionId != nil && openSessionId == sessionId
        openSessionId = sessionId
        openViewer = viewer
        guard let sessionId else { return }
        unread[sessionId] = nil
        recentSessions.removeAll { $0 == sessionId }
        recentSessions.insert(sessionId, at: 0)
        for dropped in recentSessions.dropFirst(Self.keptTranscripts) { transcripts[dropped] = nil }
        recentSessions = Array(recentSessions.prefix(Self.keptTranscripts))
        // 開いたままの会話には追記がストリームで届いているので、同じ会話の開き直しでは取り直さない。
        guard !reopened, !loadingTranscripts.contains(sessionId) else { return }
        fetchTranscript(sessionId)
    }

    func close(viewer: UUID) {
        guard openViewer == viewer else { return }
        // 端末の画面を重ねている間は下の会話を見ているのと同じなので、閉じるのはシートを閉じた時まで待つ。
        if let watched = terminalWatch?.roomId, let sid = openSessionId, room(watched)?.sessionId == sid {
            deferredCloseViewer = viewer
            return
        }
        openViewer = nil
        openSessionId = nil
    }

    /// ストリームを張った後に全件を取り、届いていた追記と id で重ねる。
    private func fetchTranscript(_ sessionId: String) {
        #if DEBUG
        transcriptFetchCount += 1
        #endif
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
        let body = RemoteMenuAnswerRequest(menuId: menu.menuId, choice: choice, cancel: choice == nil ? true : nil,
                                           confirmExit: confirmExit ? true : nil)
        exitConfirmations[room.id] = nil
        let sentTo = pairing
        perform(room, .menu, { client in try await client.answerMenu(roomId: room.id, body) }) { [weak self] result in
            self?.menuAnswered(result, roomId: room.id, menu: menu, choice: choice, confirmedExit: confirmExit, sentTo: sentTo)
        }
    }

    /// 終了になると断られたら、同じ確認を出す（了承すれば `confirmExit` を付けて送り直す）。
    /// 送った後にペアリングが替わった・その会話を閉じていた時は出さない（断られた文だけ残す）。
    func menuAnswered(_ result: RemoteActionResult?, roomId: String, menu: RemoteMenu, choice: Int?, confirmedExit: Bool,
                      sentTo: RemotePairing?) {
        guard let result, !result.ok, result.code == "confirm_required", !confirmedExit else { return }
        guard sentTo != nil, sentTo == pairing, openRoomId == roomId else { return }
        let confirmation = choice.map { ExitConfirmation.choice($0, in: menu) } ?? .cancel(menu.menuId)
        exitConfirmations[roomId] = PendingExitConfirmation(confirmation: confirmation, askedAt: clock())
        notices[roomId] = nil
    }

    /// このメニューに出す終了の確認（求められた時のメニューのままで、期限内の時だけ）。
    func exitConfirmation(_ room: RemoteRoom, _ menu: RemoteMenu) -> ExitConfirmation? {
        guard let pending = exitConfirmations[room.id], pending.confirmation.menuId == menu.menuId,
              clock().timeIntervalSince(pending.askedAt) <= Self.exitConfirmationLifetime else { return nil }
        return pending.confirmation
    }

    func dismissExitConfirmation(_ roomId: String) {
        exitConfirmations[roomId] = nil
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

    /// 送る本文（入力欄の前後の空白を除いたもの）。
    func draftText(_ roomId: String) -> String {
        (drafts[roomId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 画像

    func images(_ roomId: String) -> [ComposerImage] { composerImages[roomId] ?? [] }

    /// 画像を付けて送れるルームか（mac が受けると言っているホスト中のセッションだけ。伝言は文字だけ）。
    func canAttachImages(_ room: RemoteRoom) -> Bool {
        room.send.mode == .input && room.send.acceptsImages == true
    }

    /// 画像を付けて送れない理由（伝言だから・この Mac が画像を受けないから）。送れるなら nil。
    func imageRefusal(_ room: RemoteRoom) -> String? {
        if canAttachImages(room) { return nil }
        if room.send.mode == .relay { return "伝言（外部セッション）には画像を付けられません。画像を外してから送ってください。" }
        return "この Mac の claude-deck は画像を受け取れません（古い版の可能性があります）。Mac を更新するか、画像を外してから送ってください。"
    }

    /// あと何枚添えられるか（整えている最中の分も数える）。
    func remainingImageSlots(_ roomId: String) -> Int {
        max(0, RemoteImageLimits.maxCount - images(roomId).count - (preparingImages[roomId] ?? 0))
    }

    /// 選んだ写真を `load` で読み、送れる形（PNG / JPEG・上限内）に整えて並べる。上限を超えた分・整えられなかった分は理由を出す。
    func attachImages<Item>(_ items: [Item], to roomId: String, load: @escaping (Item) async -> Data?) {
        let accepted = Array(items.prefix(remainingImageSlots(roomId)))
        let overflow = items.count - accepted.count
        if overflow > 0 {
            notices[roomId] = Notice(text: "画像は 1 通に \(RemoteImageLimits.maxCount) 枚までです。\(overflow) 枚は添えませんでした。", isError: true)
        }
        guard !accepted.isEmpty else { return }
        let batch = UUID()
        preparingBatches[roomId, default: [:]][batch] = accepted.count
        Task {
            var failed = 0
            for item in accepted {
                let data = await load(item)
                let prepared = await Task.detached(priority: .userInitiated) { data.flatMap { ComposerImagePreparer.prepare($0) } }.value
                // ペアリングが替わったか、ルームが一覧から消えていれば足さない（数も捨て済み）。
                guard let count = preparingBatches[roomId]?[batch] else { return }
                preparingBatches[roomId]?[batch] = count > 1 ? count - 1 : nil
                if preparingBatches[roomId]?.isEmpty == true { preparingBatches[roomId] = nil }
                if let prepared, let thumbnail = UIImage(data: prepared.thumbnail) {
                    composerImages[roomId, default: []].append(ComposerImage(payload: prepared.payload, thumbnail: thumbnail))
                } else {
                    failed += 1
                }
            }
            if failed > 0 {
                notices[roomId] = Notice(text: "読み込めなかった写真が \(failed) 枚あります（送れる大きさに縮められないか、画像として読めません）。",
                                         isError: true)
            }
        }
    }

    func removeImage(_ image: ComposerImage, from roomId: String) {
        composerImages[roomId]?.removeAll { $0.id == image.id }
        if composerImages[roomId]?.isEmpty == true { composerImages[roomId] = nil }
    }

    /// 送れる中身があるか（本文か画像。写真を整えている間は待つ）。
    func hasSomethingToSend(_ roomId: String) -> Bool {
        (preparingImages[roomId] ?? 0) == 0 && (!draftText(roomId).isEmpty || !images(roomId).isEmpty)
    }

    /// 送れたら（mac が受け付けたら）入力欄と送った画像を空にする。
    func send(_ room: RemoteRoom) {
        let text = draftText(room.id)
        let images = images(room.id)
        // 送っている最中は送らない（メモだけ残って送信中のままにならないよう、メモを作る前に確かめる）。
        guard hasSomethingToSend(room.id), !inFlight.contains(room.id) else { return }
        if !images.isEmpty, let reason = imageRefusal(room) {
            notices[room.id] = Notice(text: reason, isError: true)
            return
        }
        let relay = room.send.mode == .relay
        let note = RelayNote(text: text, sentAt: Date().timeIntervalSince1970 * 1000)
        if relay, let sid = room.sessionId { relayNotes[sid, default: []].append(note) }
        let payloads = images.map(\.payload)
        let sentIds = Set(images.map(\.id))
        perform(room, relay ? .relay : .message) { client in
            try await client.sendMessage(roomId: room.id, text: text, images: payloads)
        } completion: { [weak self] result in
            guard let self else { return }
            if result?.ok == true, self.draftText(room.id) == text {
                self.drafts[room.id] = ""
            }
            if result?.ok == true {
                self.composerImages[room.id]?.removeAll { sentIds.contains($0.id) }
                if self.composerImages[room.id]?.isEmpty == true { self.composerImages[room.id] = nil }
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
            notices[room.id] = Notice(text: "Mac につながっていないので送れません。", isError: true)
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
                    notices[room.id] = Notice(text: text, isError: !result.ok)
                }
                completion?(result)
            } catch {
                let issue = RemoteIssue.from(error)
                notices[room.id] = Notice(text: "\(issue.title)。届いたかどうか分からないので、画面の様子を確かめてください。", isError: true)
                completion?(nil)
            }
        }
    }

    func clearNotice(_ roomId: String) {
        notices[roomId] = nil
    }

    // MARK: - 端末の画面

    /// シートを開いた時。閉じるまで表示を取り直し続ける（前に開いていたものは止める）。
    func watchTerminal(roomId: String, viewer: UUID) {
        terminalTask?.cancel()
        terminalWatch = TerminalWatch(roomId: roomId, viewer: viewer)
        terminalOrder = RemoteResponseOrder()
        let interval = terminalRefreshInterval
        terminalTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let fetched = await self.refreshTerminal(viewer: viewer)
                try? await Task.sleep(for: fetched ? interval : interval * Self.terminalIdleFactor)
            }
        }
    }

    /// シートを閉じた時。取り直しをやめる。
    func stopWatchingTerminal(viewer: UUID) {
        guard terminalWatch?.viewer == viewer else { return }
        terminalTask?.cancel()
        terminalTask = nil
        terminalWatch = nil
        finishDeferredClose()
    }

    private func finishDeferredClose() {
        guard let deferred = deferredCloseViewer else { return }
        deferredCloseViewer = nil
        close(viewer: deferred)
    }

    var isWatchingTerminal: Bool { terminalTask != nil }

    static let terminalDisconnectedProblem = "Mac につながっていないので、端末の画面を取れません。"

    /// 表示を 1 回取り直す。つながっていなくて取りに行かなかった時は false。値が変わった時だけ書く（見ている画面を毎回描き直さない）。
    @discardableResult
    private func refreshTerminal(viewer: UUID) async -> Bool {
        guard let roomId = terminalWatch?.roomId, terminalWatch?.viewer == viewer else { return false }
        #if DEBUG
        terminalFetchCount += 1
        #endif
        guard let client, connection == .connected else {
            setTerminalProblem(Self.terminalDisconnectedProblem)
            return false
        }
        let number = terminalOrder.issue()
        do {
            let screen = try await client.terminalScreen(roomId: roomId)
            guard terminalWatch?.viewer == viewer, terminalOrder.accept(number) else { return true }
            if terminalWatch?.screen.map({ $0.sameContent(as: screen) }) != true { terminalWatch?.screen = screen }
            setTerminalProblem(nil)
        } catch {
            guard terminalWatch?.viewer == viewer, !(error is CancellationError), terminalOrder.accept(number) else { return true }
            setTerminalProblem(RemoteResultText.terminalScreenProblem(error))
        }
        return true
    }

    private func setTerminalProblem(_ problem: String?) {
        if terminalWatch != nil, terminalWatch?.problem != problem { terminalWatch?.problem = problem }
    }

    /// キーを 1 回送り、すぐ表示を取り直す。送っている間は重ねて送らない。
    func sendTerminalKey(_ key: RemoteTerminalKey, confirmExit: Bool = false) {
        guard let watch = terminalWatch, !watch.sending else { return }
        guard let client, connection == .connected else {
            terminalWatch?.notice = Notice(text: "Mac につながっていないので送れません。", isError: true)
            return
        }
        terminalWatch?.sending = true
        terminalWatch?.notice = nil
        Task {
            let notice: Notice
            do {
                let result = try await client.sendTerminalKey(roomId: watch.roomId, key: key, confirmExit: confirmExit)
                notice = result.ok
                    ? Notice(text: "\(key.label) を送りました。", isError: false)
                    : Notice(text: RemoteResultText.text(for: result, operation: .terminalKey) ?? "送れませんでした。", isError: true)
            } catch {
                notice = Notice(text: RemoteResultText.terminalKeyProblem(error), isError: true)
            }
            guard terminalWatch?.viewer == watch.viewer else { return }
            // 送る前に出した取り直しの応答は古い画面なので使わない。
            terminalOrder.invalidateIssued()
            terminalWatch?.sending = false
            terminalWatch?.notice = notice
            await refreshTerminal(viewer: watch.viewer)
        }
    }
}
