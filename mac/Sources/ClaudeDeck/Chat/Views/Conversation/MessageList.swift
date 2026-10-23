import SwiftUI
import MonitorKit

struct MessageList: View {
    let model: ChatModel
    let room: Room
    let items: [TranscriptItem]
    @State private var jump = LatestJump()
    @Environment(\.openTerminalScreen) private var openTerminal

    var body: some View {
        let entries = ChatTimeline.entries(from: items, notes: model.relay.notes(for: room.sessionId),
                                           pending: model.outbox.pendingImages(for: room.id))
        let imageSource = ChatImageSource(loader: model.transcripts.imageLoader, sessionId: room.sessionId)
        let runningId = ChatTimeline.runningToolId(items: items, status: room.status)
        let prompts = model.prompts
        let permissions = prompts.monitorPermissions(for: room)
        let terminal = terminalOpener
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
                                       board: prompts.board, key: permission.key, identity: permission.key, onOpenTerminal: terminal) { allow in
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
                                       board: prompts.board, key: PromptResponder.ptyPermissionKey(session),
                                       identity: PromptResponder.permissionCard(session, prompt),
                                       claudeVersion: session.claudeVersion ?? room.snapshot?.version, onOpenTerminal: terminal) { allow in
                            prompts.answerOnTerminal(session, prompt: prompt, allow: allow)
                        }
                    }
                    if permissions.isEmpty, let session = room.hosted, session.permissionPrompt == nil, session.inputBlock == .menu {
                        let key = PromptResponder.ptyMenuKey(session)
                        let version = session.claudeVersion ?? room.snapshot?.version
                        if let menu = session.menuPrompt {
                            MenuCard(menu: menu, board: prompts.board, key: key, claudeVersion: version, onOpenTerminal: terminal) { shown, choice in
                                prompts.answerMenu(session, menu: shown, choice: choice)
                            } onMoveTab: { shown, direction in
                                prompts.moveMenuTab(session, menu: shown, direction: direction)
                            }
                            .id(menu.identity)
                        } else if let unreadable = session.unreadableMenu {
                            UnreadableMenuCard(menu: unreadable, board: prompts.board, key: key, claudeVersion: version, onOpenTerminal: terminal) { shown in
                                prompts.cancelUnreadableMenu(session, menu: shown)
                            }
                                .id(unreadable)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomId)
                }
                // 広い欄では中央の列に収め、返答・ツールの行・カードの左端をそろえる。
                .frame(maxWidth: ChatTheme.columnWidth)
                // 右下の「最新へ」のボタンが狭い欄でも列に重ならないよう、右だけ余白を広げる。
                .padding(.leading, 28)
                .padding(.trailing, JumpToLatestButton.reservedGutter)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .modifier(BottomTracking { zone in
                updateJump { $0.enter(zone, entries: entries) }
            })
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    if jump.showsButton {
                        JumpToLatestButton(newCount: jump.newCount(entries: entries)) {
                            jumpToLatest(proxy: proxy, entries: entries)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .padding(.trailing, JumpToLatestButton.trailingInset)
                .padding(.bottom, 16)
                .animation(.easeOut(duration: 0.15), value: jump.showsButton)
            }
            .onChange(of: scrollKey(entries: entries, permissions: permissions.count)) {
                guard jump.followsBottom else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            }
            .onChange(of: room.id) {
                updateJump { $0.reset() }
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
            }
        }
    }

    private static let bottomId = "chat-bottom"
    /// 押してから末尾に着くまで付いていく扱いを続ける上限。
    private static let jumpTimeout: Duration = .milliseconds(500)

    /// 中身が変わった時だけ書き戻し、スクロールの段が知らされるたびに一覧を描き直さない。
    @discardableResult
    private func updateJump<T>(_ change: (inout LatestJump) -> T) -> T {
        var next = jump
        let result = change(&next)
        if next != jump { jump = next }
        return result
    }

    private func jumpToLatest(proxy: ScrollViewProxy, entries: [ChatEntry]) {
        let generation = updateJump { $0.startJump() }
        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
        Task { @MainActor in
            try? await Task.sleep(for: Self.jumpTimeout)
            updateJump { $0.finishJump(generation, entries: entries) }
        }
    }

    /// カードの「端末の画面」（ホスト中で動いているルームだけ）。
    private var terminalOpener: (() -> Void)? {
        guard let session = room.hosted, session.isRunning, let openTerminal else { return nil }
        return { openTerminal(session) }
    }

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

/// 一番下からの離れ具合の段。自動スクロールを止める判定と「最新へ」のボタンに使い、段が変わった時だけ知らせる。
private struct BottomTracking: ViewModifier {
    let onZone: (ScrollZone) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: ScrollZone.self) { geo in
                LatestJump.zone(contentHeight: geo.contentSize.height, offsetY: geo.contentOffset.y,
                                viewportHeight: geo.containerSize.height)
            } action: { _, zone in
                onZone(zone)
            }
        } else {
            content
        }
    }
}
