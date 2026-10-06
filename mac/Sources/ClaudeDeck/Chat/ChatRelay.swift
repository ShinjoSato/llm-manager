import Foundation
import Observation
import MonitorKit

/// 外部セッションへの伝言。受け手は isMeta で記録するため transcript に出ないので、送った分を手元で持って吹き出しに出す。
@MainActor
@Observable
final class ChatRelay {
    private let store: MonitorStore
    private let alerts: ChatAlerts
    private let outbox: ChatOutbox

    /// sessionId → アプリから送った伝言。
    private(set) var notesBySession: [String: [RelayNote]] = [:]

    init(store: MonitorStore, alerts: ChatAlerts, outbox: ChatOutbox) {
        self.store = store
        self.alerts = alerts
        self.outbox = outbox
    }

    func notes(for sessionId: String?) -> [RelayNote] {
        guard let sessionId else { return [] }
        return notesBySession[sessionId] ?? []
    }

    /// 外部セッションへ伝言を送る。受け手には「別セッションからのメッセージ」として届き、本人の入力にはならない。
    func send(_ text: String, to room: Room) -> Bool {
        guard room.hosted == nil, let sessionId = room.sessionId, outbox.inputDisabledReason(for: room) == nil,
              outbox.sendBlockedReason(for: room) == nil else { return false }
        let attachments = outbox.pendingAttachments(for: room.id)
        // 受け手は伝言を本文として読むだけなので、画像もパスで添える（Read で開ける）。
        let message = AttachmentFormat.outgoing(text: text, attachments: attachments, pasteImages: false)
        let body = RelayNotes.normalized(message.body)
        guard !body.isEmpty else { return false }
        let imagePaths = attachments.filter { $0.kind == .image }.map(\.path)
        outbox.clearAttachments(of: room.id)
        // 吹き出しは送信を待たずにすぐ出す。
        let note = addNote(body, imagePaths: imagePaths, to: sessionId)
        Task {
            if let reason = await deliver(note, to: sessionId) {
                alerts.message = "伝言を送れませんでした: \(reason)"
            }
        }
        return true
    }

    /// 送る伝言を手元の吹き出しに足す。
    func addNote(_ body: String, imagePaths: [String] = [], to sessionId: String) -> RelayNote {
        let note = RelayNote(text: body, sentAt: Date().timeIntervalSince1970 * 1000, imagePaths: imagePaths)
        notesBySession[sessionId, default: []].append(note)
        return note
    }

    /// 足した伝言を送る。失敗すればその理由。
    func deliver(_ note: RelayNote, to sessionId: String) async -> String? {
        let body = note.text
        do {
            try await store.sendMessage(to: sessionId, text: body)
            updateNote(note.id, in: sessionId, state: .sent)
            return nil
        } catch {
            let reason = RelayNotes.failureReason(error)
            updateNote(note.id, in: sessionId, state: .failed(reason))
            return reason
        }
    }

    private func updateNote(_ id: String, in sessionId: String, state: RelayNote.State) {
        guard let index = notesBySession[sessionId]?.firstIndex(where: { $0.id == id }) else { return }
        notesBySession[sessionId]?[index].state = state
    }
}
