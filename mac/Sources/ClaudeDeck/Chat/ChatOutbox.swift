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
    @ObservationIgnored private let attachmentStore = AttachmentStore()
    /// 1 通に添えられる数。
    static let maxAttachments = 20
    /// ルーム → 画像を添えて送り、まだ transcript に載っていない発話（載るまで送った画像を吹き出しに出す）。
    private(set) var sentImages: [RoomID: [PendingImageMessage]] = [:]

    // ChatModel に尋ねること。循環参照を避けるためクロージャで受ける。
    /// ホスト中のルームがまだあるか（閉じた後に届いた送信の結末で下書きを戻さないため）。
    @ObservationIgnored var hostedRoomExists: (RoomID) -> Bool = { _ in false }
    /// その sessionId の会話を出しているルーム。
    @ObservationIgnored var roomIds: (_ sessionId: String) -> [RoomID] = { _ in [] }
    /// 引き継ぎ中の sessionId か。
    @ObservationIgnored var isHandingOver: (_ sessionId: String) -> Bool = { _ in false }

    init(store: MonitorStore, alerts: ChatAlerts) {
        self.store = store
        self.alerts = alerts
        let attachmentStore = attachmentStore
        Task.detached(priority: .utility) { attachmentStore.sweep() }
    }

    // MARK: - 送信

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
        case .leftover, .blocked:
            alerts.message = result?.refusal?.message
            return false
        case .busy, .empty, nil: return false
        }
    }

    private func finishSend(_ completion: SendCompletion, text: String, attachments sent: [Attachment],
                            outgoingId: String, in roomId: RoomID) {
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

    /// 引き継ぎで外部ルームからホスト中のルームへ移った。書きかけと添付を移し先へ渡す。
    func move(from roomId: RoomID, to newRoomId: RoomID) {
        if let draft = drafts.removeValue(forKey: roomId) { drafts[newRoomId] = draft }
        if let pending = attachments.removeValue(forKey: roomId) { attachments[newRoomId] = pending }
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

extension ClaudeTerminalView.SendResult {
    /// 送らなかった理由（画面の案内と iPhone への応答で同じ文言を使う）。送り始めたなら nil。
    var refusal: (code: String, message: String)? {
        switch self {
        case .started:
            return nil
        case .leftover:
            return ("leftover", "端末側の入力欄に前回の本文や画像が残っているようです。"
                + "このままもう一度送ると、残っているものの後ろにつながって送られます。")
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
