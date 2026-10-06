import SwiftUI
import MonitorKit

/// 中央カラム: 見出し + チャット。
struct ConversationView: View {
    @Bindable var model: ChatModel
    let room: Room

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeader(model: model, room: room)
            if room.isExternal { ExternalBanner(model: model, room: room) }
            ChatPane(model: model, room: room)
        }
        // 吹き出しの本文は外部由来なので、http / https 以外のリンクは開かない。
        .environment(\.openURL, OpenURLAction { url in
            ChatMarkdown.isOpenableLink(url) ? .systemAction : .discarded
        })
    }
}

// MARK: - チャット

struct ChatPane: View {
    @Bindable var model: ChatModel
    let room: Room

    var body: some View {
        let items = model.transcripts.items(for: room.sessionId)
        let outbox = model.outbox
        VStack(spacing: 0) {
            MessageList(model: model, room: room, items: items)
            Composer(text: Binding(get: { outbox.drafts[room.id] ?? "" }, set: { outbox.drafts[room.id] = $0 }),
                     disabledReason: outbox.inputDisabledReason(for: room),
                     sendBlockedReason: outbox.sendBlockedReason(for: room),
                     relay: room.isExternal,
                     attachments: outbox.pendingAttachments(for: room.id),
                     importingCount: outbox.importingCount(for: room.id),
                     thumbnail: { outbox.thumbnails[$0.id] },
                     onAttach: { outbox.attach($0, to: room.id) },
                     onRemoveAttachment: { outbox.removeAttachment($0, from: room.id) }) { text in
                room.isExternal ? model.relay.send(text, to: room) : outbox.send(text, to: room)
            }
        }
        .background(ChatTheme.background)
    }
}
