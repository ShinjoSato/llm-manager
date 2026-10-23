import AppKit
import ImageIO
import Observation
import MonitorKit

/// 送る前のもの（下書き・添付）とホスト中のセッションへの送信、送った画像の仮の吹き出し。どれもルームごとに持ち、ルームを行き来しても残す。
@MainActor
@Observable
final class ChatOutbox {
    private let store: MonitorStore
    private let alerts: ChatAlerts

    /// ルームごとの書きかけ。
    var drafts: [RoomID: String] = [:]
    /// ルームごとの送る前の添付。
    private(set) var attachments: [RoomID: [Attachment]] = [:]
    /// 添付 id → チップのサムネイル（添えた時に縮小して作る）。
    @ObservationIgnored private(set) var thumbnails: [UUID: NSImage] = [:]
    /// ルーム → 取り込み中の添付（取り込み id → 元ファイルのパス）。片付けで消えたら結果は捨てる。
    private(set) var importing: [RoomID: [UUID: String?]] = [:]
    /// 引き継ぎで移った後に元のルーム宛てに届く取り込みの結果を、移し先へ届けるための表。
    @ObservationIgnored private var redirects = RoomRedirects<RoomID, UUID>()
    /// 入力欄の添付と iPhone から届いた画像の一時保存先（書く側と消す側で同じものを使う）。
    @ObservationIgnored let attachmentStore = AttachmentStore()
    /// 1 通に添えられる数。
    static let maxAttachments = 20
    /// ルーム → 画像を添えて送り、まだ transcript に載っていない発話（載るまで送った画像を吹き出しに出す）。
    private(set) var sentImages: [RoomID: [PendingImageMessage]] = [:]

    // MARK: ChatModel・引き継ぎへの問い合わせ（循環参照を避けてクロージャで受け、設定し忘れは assert で止める）
    /// ホスト中のルームがまだあるか（閉じた後に届いた送信の結末で下書きを戻さないため）。
    @ObservationIgnored var hostedRoomExists: (RoomID) -> Bool = { _ in assertionFailure("hostedRoomExists 未設定"); return false }
    /// その sessionId の会話を出しているルーム。
    @ObservationIgnored var roomIds: (_ sessionId: String) -> [RoomID] = { _ in assertionFailure("roomIds 未設定"); return [] }
    /// 引き継ぎ中の sessionId か。
    @ObservationIgnored var isHandingOver: (_ sessionId: String) -> Bool = { _ in assertionFailure("isHandingOver 未設定"); return false }
    /// 今のルーム（抜け道のボタンを押した時に引き直す）。
    @ObservationIgnored var room: (RoomID) -> Room? = { _ in assertionFailure("room 未設定"); return nil }

    /// 端末の入力欄に入らず、この入力欄に戻した送信（端末からそのまま送られたら、同じ本文と添付をここから外す）。
    private struct RestoredSend {
        let text: String
        let attachmentIds: Set<UUID>
    }
    @ObservationIgnored private var restoredLate: [RoomID: RestoredSend] = [:]
    /// 「端末の画面」を開いてほしいルームとウィンドウ（警告のボタンから。会話の画面が受け取って消す）。
    var terminalScreenRequest: TerminalScreenRequest?

    init(store: MonitorStore, alerts: ChatAlerts) {
        self.store = store
        self.alerts = alerts
        let attachmentStore = attachmentStore
        Task.detached(priority: .utility) { attachmentStore.sweep() }
    }

    // MARK: - 送信

    func send(_ text: String, to room: Room) -> Bool {
        guard let session = room.hosted, sendBlockedReason(for: room) == nil else { return false }
        // 同じ会話が外でも動いている間は、二重に書き込まないよう送らない（入力欄は無効にしてあるが、押した直後に見つかった時のため）。
        if let duplicate = session.externalDuplicate {
            alerts.message = duplicate.sendBlockedReason
            return false
        }
        let roomId = room.id
        let sending = attachments[roomId] ?? []
        let outgoingId = UUID().uuidString
        let sentAt = Date().timeIntervalSince1970 * 1000
        let result = session.send(text, attachments: sending) { [weak self, weak session] completion in
            self?.finishSend(completion, text: text, attachments: sending, outgoingId: outgoingId, in: roomId, session: session)
        }
        switch result {
        case .started(let pastedImages, let body):
            // 戻した本文を送り直したので、端末から送られた時に外す印は要らない。
            restoredLate[roomId] = nil
            // サムネイルは結末が出るまで残す（本文を貼る前にやめたら入力欄へ戻すため）。
            attachments[roomId] = nil
            if let outgoing = PendingImageMessages.outgoing(id: outgoingId, text: text, sentBody: body,
                                                            pastedImagePaths: pastedImages, sentAt: sentAt) {
                sentImages[roomId, default: []].append(outgoing)
                scheduleSentImagesExpiry()
            }
            return true
        case .leftover, .lateLeftover:
            showLeftoverRefusal(strict: result == .lateLeftover, room: roomId, session: session)
            return false
        case .blocked:
            alerts.message = result?.refusal?.message
            return false
        case .busy, .empty, nil: return false
        }
    }

    // MARK: - 残りの抜け道

    /// 端末の入力欄の残りを理由に送らなかった時の警告。選べる抜け道をボタンで添える。
    private func showLeftoverRefusal(strict: Bool, room roomId: RoomID, session: HostedSession) {
        let result: ClaudeTerminalView.SendResult = strict ? .lateLeftover : .leftover
        let escape = strict ? session.currentLeftover() : nil
        let detail = escape.map(Self.leftoverDetail).map { "\n\n" + $0 } ?? ""
        alerts.show((result.refusal?.message ?? "") + detail,
                    actions: LeftoverChoice.choices(strict: strict, escape: escape).map { leftoverAction($0, room: roomId) })
    }

    /// 今の端末の入力欄の様子の一言（警告と入力欄の上の案内で同じ文言）。
    static func leftoverDetail(_ escape: LeftoverEscape) -> String {
        switch escape.box {
        case .showsBody:
            return "端末の入力欄に、前回入らなかった本文が入っています。「そのまま送る」で送ると、この入力欄に戻した同じ本文は消します。"
        case .other:
            return "端末の入力欄に何か入っています。中身は「端末の画面」で確かめられます。"
        case .unreadable:
            return escape.canForce
                ? "端末の入力欄を 30 秒以上読めていません。確かめずに送ることもできます（入っていれば二重に送られます）。"
                : "端末の入力欄を読めません。読めない状態が 30 秒続くと、確かめずに送ることも選べます。"
        }
    }

    /// 抜け道のボタン 1 つ。
    func leftoverAction(_ choice: LeftoverChoice, room roomId: RoomID) -> ChatAlertAction {
        switch choice {
        case .openTerminal:
            return ChatAlertAction(title: "端末の画面を開く") { [weak self] window in
                self?.terminalScreenRequest = TerminalScreenRequest(room: roomId, window: window)
            }
        case .submitAsIs:
            return ChatAlertAction(title: "そのまま送る（Enter）") { [weak self] _ in self?.submitLeftover(in: roomId) }
        case .clearInput:
            return ChatAlertAction(title: "端末の入力欄を消す") { [weak self] _ in self?.clearTerminalInput(in: roomId) }
        case .forceSend:
            return ChatAlertAction(title: "確かめられないまま送る…", destructive: true) { [weak self] _ in self?.confirmForceSend(in: roomId) }
        }
    }

    /// 端末の入力欄に見えている本文をそのまま Enter で送る。
    func submitLeftover(in roomId: RoomID) {
        guard let session = room(roomId)?.hosted else { return }
        let draftBefore = drafts[roomId]
        let restored = restoredLate[roomId] != nil
        switch session.submitLeftover() {
        case .done:
            // 外すのは `onLeftoverSubmitted` で済んでいる。書き換えていた時は本文を残すので、そう伝える。
            if !restored || draftBefore == nil {
                alerts.message = "端末の入力欄の本文を送りました。"
            } else if drafts[roomId] == draftBefore {
                alerts.message = "端末の入力欄の本文を送りました。この入力欄の本文は書き換えられていたので残しています。同じ内容なら消してください。"
            } else {
                alerts.message = "端末の入力欄の本文を送りました。この入力欄に戻していた同じ本文は二重に送らないよう消しました。"
            }
        case .notShown:
            alerts.message = "端末の入力欄に前回の本文が見えなくなりました。「端末の画面」で確かめてください。"
        case .blocked:
            alerts.message = "確認や選択肢が出ているので送りませんでした（Enter がそちらに効くため）。先に答えてください。"
        case .busy:
            alerts.message = "送信か入力欄の消去の途中です。終わってからもう一度。"
        case .notNeeded:
            alerts.message = "端末の入力欄の残りはもう確かめられています。この入力欄から送れます。"
        case .tooEarly, .ended:
            alerts.message = "claude が動いていないため送れません。"
        }
    }

    /// 端末の入力欄を空にする。この入力欄の本文は残すので、消えたらここから送り直せる。
    func clearTerminalInput(in roomId: RoomID) {
        guard let session = room(roomId)?.hosted else { return }
        let started = session.clearInput { [weak self] outcome in
            guard let self, self.hostedRoomExists(roomId) else { return }
            // 端末の入力欄を片付けたので、端末から送られた時に外す印は要らない（本文はここから送り直す）。
            if outcome != .blocked { self.restoredLate[roomId] = nil }
            switch outcome {
            case .cleared:
                self.alerts.message = "端末の入力欄を消しました。この入力欄の本文から送り直せます。"
            case .unverified, .stuck:
                self.alerts.message = "消すキーを送りましたが、端末の入力欄が空になったか確かめられませんでした。「端末の画面」で確かめてください。"
                    + "このまま送ると、残っていれば一度だけ知らせます。"
            case .blocked:
                self.alerts.message = "途中で確認や選択肢が出たので、消すのをやめました。先に答えてから、もう一度消してください。"
            case .ended:
                break
            }
        }
        switch started {
        case .done: break
        case .blocked: alerts.message = "確認や選択肢が出ている間は入力欄を消しません（キーがそちらに効くため）。先に答えてください。"
        case .busy: alerts.message = "送信か入力欄の消去の途中です。終わってからもう一度。"
        case .ended, .notShown, .notNeeded, .tooEarly: alerts.message = "claude が動いていないため消せません。"
        }
    }

    /// 確かめられないまま送るかを確かめる。
    func confirmForceSend(in roomId: RoomID) {
        alerts.show("端末の入力欄を確かめられないまま送りますか？\n\n前回の本文が端末の入力欄に入っていると、この入力欄の本文とつながって二重に送られます。",
                     actions: [ChatAlertAction(title: "送る", destructive: true) { [weak self] _ in self?.forceSend(in: roomId) }])
    }

    private func forceSend(in roomId: RoomID) {
        guard let room = room(roomId), let session = room.hosted else { return }
        switch session.overrideLeftover() {
        case .done, .notNeeded:
            let text = drafts[roomId] ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (attachments[roomId] ?? []).isEmpty {
                alerts.message = "この入力欄が空なので、確かめずに送れる状態にだけしました。"
            } else if send(text, to: room) {
                drafts[roomId] = nil
            }
        case .tooEarly:
            alerts.message = "端末の入力欄が読めるようになりました。もう一度送るか、案内のボタンを使ってください。"
        case .blocked:
            alerts.message = "確認や選択肢が出ているので送りませんでした。先に答えてください。"
        case .busy, .notShown, .ended:
            alerts.message = "今は送れません。少し待ってからもう一度。"
        }
    }

    /// 端末からそのまま送られた。戻していた同じ本文と添付をこの入力欄から外す（書き換えていれば本文は残す）。
    /// 端末から送られた本文が戻したものと違えば（iPhone から送って入らなかった分など）何もしない。
    private func dropRestored(in roomId: RoomID, submitted: String) {
        guard let restored = restoredLate.removeValue(forKey: roomId),
              ComposerRestore.isSameSend(restored: restored.text, submitted: submitted) else { return }
        if let draft = drafts[roomId], let rest = ComposerRestore.draft(removing: restored.text, from: draft) {
            drafts[roomId] = rest.isEmpty ? nil : rest
        }
        let current = attachments[roomId] ?? []
        // 端末に渡った画像は受け手が後から読むので一時ファイルは残す。
        for attachment in current where restored.attachmentIds.contains(attachment.id) { forget(attachment, deletingFile: false) }
        let kept = current.filter { !restored.attachmentIds.contains($0.id) }
        attachments[roomId] = kept.isEmpty ? nil : kept
    }

    /// iPhone から届いた本文と画像を送る。mac の入力欄の書きかけ・添付には触れず、取りやめても入力欄には戻さない。
    /// 画像の一時ファイルは送り始められなかった時・claude が終わった時・ルームが無くなった時だけ消し（`RemoteImageCleanup`）、他は起動時の掃除に任せる。
    func sendFromRemote(_ text: String, images: [Attachment], to room: Room,
                        completion: @escaping (SendCompletion) -> Void) -> ClaudeTerminalView.SendResult? {
        guard let session = room.hosted else {
            discardRemoteImages(images)
            return nil
        }
        let roomId = room.id
        let outgoingId = UUID().uuidString
        let sentAt = Date().timeIntervalSince1970 * 1000
        let result = session.send(text, attachments: images) { [weak self] outcome in
            self?.finishRemoteSend(outcome, images: images, outgoingId: outgoingId, in: roomId)
            completion(outcome)
        }
        if case .started(let pastedImages, let body) = result {
            if let outgoing = PendingImageMessages.outgoing(id: outgoingId, text: text, sentBody: body,
                                                            pastedImagePaths: pastedImages, sentAt: sentAt) {
                sentImages[roomId, default: []].append(outgoing)
                scheduleSentImagesExpiry()
            }
        } else if !RemoteImageCleanup.keepsFiles(.refused) {
            discardRemoteImages(images)
        }
        return result
    }

    private func finishRemoteSend(_ completion: SendCompletion, images: [Attachment], outgoingId: String, in roomId: RoomID) {
        if completion != .submitted {
            sentImages[roomId]?.removeAll { $0.id == outgoingId }
            if sentImages[roomId]?.isEmpty == true { sentImages[roomId] = nil }
        }
        if !RemoteImageCleanup.keepsFiles(.finished(completion, roomExists: hostedRoomExists(roomId))) { discardRemoteImages(images) }
    }

    /// iPhone から届いた画像の一時ファイルを消す（一時保存先の外には触らない）。
    func discardRemoteImages(_ images: [Attachment]) {
        images.forEach(attachmentStore.discard)
    }

    private func finishSend(_ completion: SendCompletion, text: String, attachments sent: [Attachment],
                            outgoingId: String, in roomId: RoomID, session: HostedSession?) {
        let roomExists = hostedRoomExists(roomId)
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
            if case .notPasted = completion {
                // 遅れて端末に入った本文がそこから送られたら、ここに戻した同じものを外して二重送信を防ぐ。
                restoredLate[roomId] = RestoredSend(text: text, attachmentIds: Set(sent.map(\.id)))
                session?.onLeftoverSubmitted = { [weak self] body in self?.dropRestored(in: roomId, submitted: body) }
            }
        } else {
            // 端末に渡った画像は受け手が後から読むことがあるので一時ファイルは残す（起動時の掃除に任せる）。
            let keepFiles = roomExists && completion != .ended
            for attachment in sent { forget(attachment, deletingFile: !keepFiles) }
        }
        if let notice = completion.notice, roomExists { alerts.message = notice }
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
            if let sessionId = room.sessionId, isHandingOver(sessionId) { return "引き継ぎ中…" }
            if !store.connection.isConnected { return "セッションの監視を始めています…" }
            if room.snapshot?.alive == false || room.status == .stopped { return "このセッションは終了しています" }
            return nil
        }
        return Self.inputDisabledReason(for: room)
    }

    static func inputDisabledReason(for room: Room) -> String? {
        guard let session = room.hosted else { return "外部セッションにはここから送れません" }
        if let end = session.end { return end.message }
        if session.pid == nil { return "起動中…" }
        if let duplicate = session.externalDuplicate { return duplicate.sendBlockedReason }
        switch session.inputBlock {
        case .permission: return "権限の確認に答えると送れます"
        case .menu: return "上の選択肢に答えると送れます"
        case nil: return nil
        }
    }

    // MARK: - 送った画像の仮の吹き出し

    func pendingImages(for roomId: RoomID) -> [PendingImageMessage] { sentImages[roomId] ?? [] }

    /// transcript に載った分と期限切れの仮の吹き出しを片付ける（表示側でも重ねないよう除いているが、溜め込まないため）。
    func pruneSentImages(sessionId: String, items: [TranscriptItem]) {
        guard !sentImages.isEmpty else { return }
        let now = Date().timeIntervalSince1970 * 1000
        for roomId in roomIds(sessionId) {
            guard let messages = sentImages[roomId] else { continue }
            let rest = PendingImageMessages.unrecorded(messages, in: items, now: now)
            if rest.count != messages.count { sentImages[roomId] = rest.isEmpty ? nil : rest }
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

    // MARK: - 添付

    func pendingAttachments(for roomId: RoomID) -> [Attachment] { attachments[roomId] ?? [] }

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
        if overflow { alerts.message = "添付できなかったものがあります。\n1 通に添えられるのは \(Self.maxAttachments) 個までです" }
        guard !accepted.isEmpty else { return }
        let store = attachmentStore
        Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                accepted.map { id, source in ImportResult.make(id: id, source: source, store: store) }
            }.value
            self?.finishImport(results, in: roomId)
        }
    }

    private func finishImport(_ results: [ImportResult], in arrivalRoomId: RoomID) {
        var failures: [String] = []
        var touched: Set<RoomID> = []
        for result in results {
            // 待つ間に引き継ぎで移っていたら、移し先に届ける。
            let roomId = redirects.resolve(result.id, arrivedAt: arrivalRoomId)
            touched.insert(roomId)
            // 待つ間にルームが片付けられていたら、作った一時ファイルも消す。
            guard importing[roomId]?.removeValue(forKey: result.id) != nil else {
                if let attachment = result.attachment { attachmentStore.discard(attachment) }
                continue
            }
            if let attachment = result.attachment {
                if let image = result.thumbnail {
                    thumbnails[attachment.id] = NSImage(pixelSized: image)
                }
                attachments[roomId, default: []].append(attachment)
            } else if let failure = result.failure {
                failures.append(failure)
            }
        }
        for roomId in touched where importing[roomId]?.isEmpty == true { importing[roomId] = nil }
        if !failures.isEmpty { alerts.message = "添付できなかったものがあります。\n" + failures.joined(separator: "\n") }
    }

    func removeAttachment(_ attachment: Attachment, from roomId: RoomID) {
        attachments[roomId]?.removeAll { $0.id == attachment.id }
        if attachments[roomId]?.isEmpty == true { attachments[roomId] = nil }
        forget(attachment, deletingFile: true)
    }

    /// 送った後に外す。一時ファイルは受け手が後から読むことがあるので消さない（起動時の掃除に任せる）。
    func clearAttachments(of roomId: RoomID) {
        for attachment in attachments.removeValue(forKey: roomId) ?? [] { forget(attachment, deletingFile: false) }
    }

    /// ルームが無くなった時に、送る前の添付・取り込み中の分・サムネイル・一時ファイルを片付ける。
    private func discardPendingAttachments(of roomId: RoomID) {
        importing[roomId] = nil
        for attachment in attachments.removeValue(forKey: roomId) ?? [] { forget(attachment, deletingFile: true) }
    }

    /// 一覧から消えた外部ルームの添付を片付ける。引き継ぎ中は移し先へ渡すので残す。
    func discardVanishedExternalRooms(alive: Set<RoomID>) {
        let stale = Set(attachments.keys).union(importing.keys).filter { id in
            guard case .external(let sessionId) = id else { return false }
            return !alive.contains(id) && !isHandingOver(sessionId)
        }
        for id in stale { discardPendingAttachments(of: id) }
    }

    /// ルームを閉じた。下書き・仮の吹き出し・添付を片付ける。
    func forgetRoom(_ roomId: RoomID) {
        drafts[roomId] = nil
        sentImages[roomId] = nil
        discardPendingAttachments(of: roomId)
    }

    /// 引き継ぎで外部ルームからホスト中のルームへ移った。書きかけと添付（取り込み中のものも）を移し先へ渡す。
    func move(from roomId: RoomID, to newRoomId: RoomID) {
        if let draft = drafts.removeValue(forKey: roomId) { drafts[newRoomId] = draft }
        if let pending = attachments.removeValue(forKey: roomId) { attachments[newRoomId, default: []].append(contentsOf: pending) }
        if let pending = importing.removeValue(forKey: roomId) {
            importing[newRoomId, default: [:]].merge(pending) { _, moved in moved }
            redirects.redirect(pending.keys, to: newRoomId)
        }
    }

    private func forget(_ attachment: Attachment, deletingFile: Bool) {
        thumbnails[attachment.id] = nil
        if deletingFile { attachmentStore.discard(attachment) }
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

/// 警告のボタンから「端末の画面」を開いてほしい時の宛先。
struct TerminalScreenRequest: Equatable {
    let id = UUID()
    let room: RoomID
    /// 警告が出ていたウィンドウ（メインなら nil）。
    let window: UUID?
}

extension ClaudeTerminalView.SendResult {
    /// 送らなかった理由（画面の案内と iPhone への応答で同じ文言を使う）。送り始めたなら nil。
    var refusal: (code: String, message: String)? {
        switch self {
        case .started:
            return nil
        case .leftover:
            return ("leftover", "端末側の入力欄に前回の本文や画像が残っているようです。"
                + "このままもう一度送ると、残っているものの後ろにつながって送られます（「端末の入力欄を消す」で消せます）。")
        case .lateLeftover:
            return ("leftover", "前回入らなかった本文が遅れて端末側の入力欄に入ったか、入力欄を確かめられません。"
                + "二重に送らないよう、端末側の入力欄が空になるまで送りません（「端末の入力欄を消す」か、入っている本文を「そのまま送る」で片付けられます）。")
        case .blocked(.permission):
            return ("blocked_permission", "権限の確認に答えてから送ってください（今 Enter を送ると確認への「Yes」になります）。")
        case .blocked(.menu):
            return ("blocked_menu", "選択肢が出ているため送りませんでした（今 Enter を送るとその選択が確定します）。上のカードで答えてください。")
        case .busy:
            return ("busy", "前の送信が終わっていません。少し待ってから送ってください。")
        case .empty:
            return ("invalid", "本文が空です。")
        }
    }
}
