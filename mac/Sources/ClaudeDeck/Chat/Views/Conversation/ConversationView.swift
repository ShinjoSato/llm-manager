import SwiftUI
import MonitorKit

/// 中央カラム（と別ウィンドウ）: 見出し + 「Claude」「ターミナル」のタブ + チャットかターミナル。
struct ConversationView: View {
    @Bindable var model: ChatModel
    let room: Room
    /// 別ウィンドウの印（nil はメイン）。見出しに「別ウィンドウで開く」を出さず、タブと確認はウィンドウごとに持つ。
    var window: UUID? = nil
    @State private var terminalSession: HostedSession?

    var body: some View {
        let shells = model.shells
        let tab = shells.tab(for: room.id, window: window)
        VStack(spacing: 0) {
            // ボタンの吹き出しを下の会話の上に重ねるため、見出しを前に出す。
            ConversationHeader(model: model, room: room, window: window).zIndex(1)
            RoomTabBar(selection: tab, shellRunning: shells.shell(for: room.id)?.isRunning == true) {
                shells.select($0, for: room.id, window: window)
                // 会話に戻ったら、そこまでを読んだことにする。
                model.markShownSeen()
            }
            switch tab {
            case .claude:
                if room.isExternal {
                    ExternalBanner(model: model, room: room)
                } else if let duplicate = room.hosted?.externalDuplicate {
                    ExternalDuplicateBanner(duplicate: duplicate)
                }
                ChatPane(model: model, room: room)
            case .terminal:
                ShellPane(model: model, room: room, window: window)
            }
        }
        .onAppear { shells.beginShowing(room.id, window: window) }
        .alert("実行コマンドを送りますか？", isPresented: Binding(get: { pendingConfirmation != nil },
                                                        set: { if !$0 { shells.confirmation = nil } }),
               presenting: pendingConfirmation) { confirmation in
            Button("送る") { model.confirmCommand(confirmation) }
            Button("やめる", role: .cancel) { shells.confirmation = nil }
        } message: { confirmation in
            Text(Self.confirmationText(confirmation))
        }
        // 吹き出しの本文は外部由来なので、http / https 以外のリンクは開かない。
        .environment(\.openURL, OpenURLAction { url in
            ChatMarkdown.isOpenableLink(url) ? .systemAction : .discarded
        })
        .environment(\.openTerminalScreen, OpenTerminalScreenAction { terminalSession = $0 })
        // 警告の「端末の画面を開く」は、警告が出ていたウィンドウで開く。
        .onChange(of: model.outbox.terminalScreenRequest, initial: true) { _, request in
            guard let request, request.room == room.id, request.window == window else { return }
            model.outbox.terminalScreenRequest = nil
            terminalSession = room.hosted
        }
        .sheet(item: $terminalSession) { session in
            TerminalScreenSheet(session: session, roomName: room.name) { [prompts = model.prompts] key in
                prompts.sendTerminalKey(session, key)
            }
        }
    }

    /// このウィンドウで答える確認（押したウィンドウが閉じられていればメインで答える）。
    private var pendingConfirmation: ShellConfirmation? {
        guard let confirmation = model.shells.confirmation, confirmation.room == room.id else { return nil }
        if confirmation.window == window { return confirmation }
        let orphaned = confirmation.window.map { model.detached.room(for: $0) == nil } ?? false
        return window == nil && orphaned ? confirmation : nil
    }

    static func confirmationText(_ confirmation: ShellConfirmation) -> String {
        let reasons = confirmation.reasons.map(\.message).joined(separator: "\n")
        return "「\(confirmation.command.name)」\n\n\(confirmation.command.command)\n\n\(reasons)"
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
            if let session = room.hosted, let escape = session.leftover, session.inputBlock == nil {
                LeftoverBanner(escape: escape, roomId: room.id, session: session, outbox: outbox)
            }
            Composer(text: Binding(get: { outbox.drafts[room.id] ?? "" }, set: { outbox.drafts[room.id] = $0 }),
                     disabledReason: outbox.inputDisabledReason(for: room),
                     sendBlockedReason: outbox.sendBlockedReason(for: room),
                     relay: room.isExternal,
                     attachments: outbox.pendingAttachments(for: room.id),
                     importingCount: outbox.importingCount(for: room.id),
                     thumbnail: { outbox.thumbnails[$0.id] },
                     onAttach: { outbox.attach($0, to: room.id) },
                     onRemoveAttachment: { outbox.removeAttachment($0, from: room.id) },
                     recaller: ComposerRecaller(scope: room.id, move: { [transcripts = model.transcripts, relay = model.relay] direction, current in
                         outbox.recall(direction, current: current, in: room.id, items: transcripts.items(for: room.sessionId),
                                       notes: relay.notes(for: room.sessionId))
                     }, rewind: { outbox.rewindRecall(in: room.id) }, reset: { outbox.resetRecall(in: room.id) })) { text in
                room.isExternal ? model.relay.send(text, to: room) : outbox.send(text, to: room)
            }
        }
        .background(ChatTheme.background)
    }
}
