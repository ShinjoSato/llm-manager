import SwiftUI
import MonitorKit

struct MessageList: View {
    let model: ChatModel
    let room: Room
    let items: [TranscriptItem]
    @State private var pinnedToBottom = true

    var body: some View {
        let entries = ChatTimeline.entries(from: items, notes: model.relay.notes(for: room.sessionId),
                                           pending: model.outbox.pendingImages(for: room.id))
        let imageSource = ChatImageSource(loader: model.transcripts.imageLoader, sessionId: room.sessionId)
        let runningId = ChatTimeline.runningToolId(items: items, status: room.status)
        let prompts = model.prompts
        let permissions = prompts.monitorPermissions(for: room)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if entries.isEmpty { emptyState }
                    ForEach(entries) { entry in
                        EntryView(entry: entry, runningToolId: runningId, imageSource: imageSource,
                                  bubbleWindow: BubbleWindowOpener(model: model, sessionId: room.sessionId, roomName: room.name))
                    }
                    ForEach(permissions) { permission in
                        PermissionCard(toolName: permission.toolName,
                                       description: permission.description,
                                       lines: permission.inputPreview.isEmpty ? [] : [permission.inputPreview],
                                       busy: prompts.busyKeys.contains(permission.key)) { allow in
                            prompts.decide(permission, allow ? .allow : .deny)
                        }
                    }
                    if permissions.isEmpty, room.isExternal, room.status == .permission {
                        ChannelsMissingCard(toolName: room.snapshot?.currentTool)
                    }
                    if permissions.isEmpty, let session = room.hosted, let prompt = session.permissionPrompt {
                        PermissionCard(toolName: room.snapshot?.currentTool ?? prompt.title,
                                       description: prompt.title,
                                       lines: prompt.lines,
                                       busy: prompts.busyKeys.contains(PromptResponder.ptyPermissionKey(session))) { allow in
                            prompts.answerOnTerminal(session, prompt: prompt, allow: allow)
                        }
                    }
                    if permissions.isEmpty, let session = room.hosted, session.permissionPrompt == nil, session.inputBlock == .menu {
                        let key = PromptResponder.ptyMenuKey(session)
                        let busy = prompts.busyKeys.contains(key)
                        if let menu = session.menuPrompt {
                            MenuCard(menu: menu, busy: busy, notice: prompts.menuNotices[key]) { shown, choice in
                                prompts.answerMenu(session, menu: shown, choice: choice)
                            } onMoveTab: { shown, direction in
                                prompts.moveMenuTab(session, menu: shown, direction: direction)
                            }
                            .id(menu.identity)
                        } else if let unreadable = session.unreadableMenu {
                            UnreadableMenuCard(menu: unreadable, busy: busy) { shown in prompts.cancelUnreadableMenu(session, menu: shown) }
                                .id(unreadable)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomId)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
            .defaultScrollAnchor(.bottom)
            .modifier(BottomTracking(pinned: $pinnedToBottom))
            .onChange(of: scrollKey(entries: entries, permissions: permissions.count)) {
                guard pinnedToBottom else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            }
            .onChange(of: room.id) {
                pinnedToBottom = true
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
            }
        }
    }

    private static let bottomId = "chat-bottom"

    /// 末尾が伸びた時だけ変わる値（発話の追加・ツールの追加・権限カードの出入り）。
    private func scrollKey(entries: [ChatEntry], permissions: Int) -> String {
        let last = entries.last
        let prompt = room.hosted?.permissionPrompt != nil || room.status == .permission
        let menu = room.hosted?.inputBlock == .menu
        return "\(entries.count):\(last?.id ?? ""):\(last?.tools.count ?? 0):\(last?.text.count ?? 0):\(permissions):\(prompt):\(menu)"
    }

    @ViewBuilder
    private var emptyState: some View {
        let (icon, text) = emptyMessage
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(ChatTheme.tertiary)
            Text(text).font(ChatTheme.body).foregroundStyle(ChatTheme.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var emptyMessage: (String, String) {
        if !model.store.connection.isConnected {
            return ("bolt.horizontal.circle", "セッションの監視を始めています…"
                    + (room.hosted?.isRunning == true ? "\n下の入力欄からの送信はできます。" : ""))
        }
        guard let sessionId = room.sessionId else {
            if room.hosted?.end == .launchFailed {
                return ("exclamationmark.triangle", "claude を起動できませんでした。\nログインシェルの PATH に claude があるか確かめてください。")
            }
            if room.hosted?.end != nil { return ("stop.circle", "会話を取得する前に claude が終了しました。") }
            return ("hourglass", "セッションの開始を待っています…")
        }
        if model.transcripts.loading.contains(sessionId) { return ("arrow.triangle.2.circlepath", "会話を読み込んでいます…") }
        return ("bubble.left.and.bubble.right", room.hosted != nil ? "下の入力欄から指示を送れます。" : "まだ会話がありません。下の入力欄から伝言を送れます。")
    }
}

/// ユーザーが上に遡っている間は自動スクロールを止めるための追跡。
private struct BottomTracking: ViewModifier {
    @Binding var pinned: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 48
            } action: { _, atBottom in
                pinned = atBottom
            }
        } else {
            content
        }
    }
}
