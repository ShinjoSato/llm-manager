import DeckCore
import SwiftUI

/// 会話: 見出し・吹き出し・要対応のカード・入力欄。
struct ConversationScreen: View {
    @Bindable var model: AppModel
    let roomId: String

    var body: some View {
        Group {
            if let room = model.room(roomId) {
                content(room)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "questionmark.bubble").font(.system(size: 28)).foregroundStyle(DeckTheme.tertiary)
                    Text("このルームはもう一覧にありません。").font(DeckTheme.body).foregroundStyle(DeckTheme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DeckTheme.background.ignoresSafeArea())
        .toolbarBackground(DeckTheme.background, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        // 吹き出しの本文は外部由来なので、http / https 以外のリンクは開かない。
        .environment(\.openURL, OpenURLAction { url in
            ChatMarkdown.isOpenableLink(url) ? .systemAction : .discarded
        })
    }

    private func content(_ room: RemoteRoom) -> some View {
        VStack(spacing: 0) {
            ConnectionBanner(model: model)
            if room.kind == .external { ExternalBanner() }
            MessageList(model: model, room: room)
            ComposerBar(model: model, room: room)
        }
        .toolbar {
            ToolbarItem(placement: .principal) { ConversationTitle(room: room) }
        }
        .onAppear { model.open(sessionId: room.sessionId) }
        .onChange(of: room.sessionId) { _, sid in model.open(sessionId: sid) }
        .onDisappear { model.close(sessionId: room.sessionId) }
    }
}

private struct ConversationTitle: View {
    let room: RemoteRoom

    var body: some View {
        HStack(spacing: 8) {
            PixelAvatar(status: room.status, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(room.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DeckTheme.heading)
                        .lineLimit(1)
                    StatusBadge(status: room.status)
                }
                Group {
                    if let branch = room.branch, !branch.isEmpty {
                        Label(branch, systemImage: "arrow.triangle.branch").labelStyle(CompactLabelStyle())
                    } else {
                        Text(room.cwd).truncationMode(.middle)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DeckTheme.secondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9))
            configuration.title
        }
    }
}

/// 外部セッションでできることの説明。
private struct ExternalBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "terminal").font(.system(size: 13)).foregroundStyle(DeckTheme.waiting)
            Text("Mac アプリの外（ターミナル・VS Code 等）で動いているセッションです。ここから送れるのは『伝言』と権限の許可・拒否だけです。")
                .font(DeckTheme.caption)
                .foregroundStyle(DeckTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeckTheme.waiting.opacity(0.07))
        .overlay(alignment: .bottom) { Rectangle().fill(DeckTheme.border).frame(height: 1) }
    }
}

private struct MessageList: View {
    @Bindable var model: AppModel
    let room: RemoteRoom

    var body: some View {
        let items = model.items(for: room.sessionId)
        let entries = model.entries(for: room)
        let runningId = ChatTimeline.runningToolId(items: items, status: room.status)
        let cards = RoomCard.cards(for: room)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if entries.isEmpty { emptyState }
                    ForEach(entries) { entry in
                        EntryView(model: model, entry: entry, sessionId: room.sessionId, runningToolId: runningId)
                    }
                    ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                        CardView(model: model, room: room, card: card)
                    }
                    if let notice = model.notices[room.id] {
                        NoticeLine(notice: notice) { model.clearNotice(room.id) }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomId)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scrollKey(entries: entries, cards: cards.count)) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            }
        }
    }

    private static let bottomId = "chat-bottom"

    private func scrollKey(entries: [ChatEntry], cards: Int) -> String {
        let last = entries.last
        return "\(entries.count):\(last?.id ?? ""):\(last?.tools.count ?? 0):\(last?.text.count ?? 0):\(cards):\(model.notices[room.id]?.text ?? "")"
    }

    @ViewBuilder
    private var emptyState: some View {
        let (icon, text) = emptyMessage
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(DeckTheme.tertiary)
            Text(text).font(DeckTheme.body).foregroundStyle(DeckTheme.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    private var emptyMessage: (String, String) {
        guard let sessionId = room.sessionId else {
            switch room.ended {
            case "launchFailed": return ("exclamationmark.triangle", "claude を起動できませんでした。")
            case .some: return ("stop.circle", "会話を取得する前に claude が終了しました。")
            case nil: return ("hourglass", "セッションの開始を待っています…")
            }
        }
        if model.loadingTranscripts.contains(sessionId) { return ("arrow.triangle.2.circlepath", "会話を読み込んでいます…") }
        if !model.connection.isConnected { return ("wifi.slash", "Mac につながると会話が出ます。") }
        return ("bubble.left.and.bubble.right", room.kind == .hosted ? "下の入力欄から指示を送れます。" : "まだ会話がありません。下の入力欄から伝言を送れます。")
    }
}

private struct NoticeLine: View {
    let notice: AppModel.Notice
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.isError ? "exclamationmark.circle.fill" : "checkmark.circle")
            Text(notice.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                .buttonStyle(.plain)
                .accessibilityLabel("閉じる")
        }
        .font(DeckTheme.caption)
        .foregroundStyle(notice.isError ? DeckTheme.error : DeckTheme.working)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill((notice.isError ? DeckTheme.error : DeckTheme.working).opacity(0.08)))
        .accessibilityIdentifier("action-notice")
    }
}

// MARK: - 吹き出し

private struct EntryView: View {
    let model: AppModel
    let entry: ChatEntry
    let sessionId: String?
    let runningToolId: String?

    var body: some View {
        let trailing = entry.role == .user || entry.role == .relay || entry.role == .outgoing
        VStack(alignment: trailing ? .trailing : .leading, spacing: 6) {
            switch entry.role {
            case .user, .outgoing:
                HStack {
                    Spacer(minLength: 44)
                    UserBubble(text: entry.text, images: images)
                }
            case .assistant:
                HStack {
                    ClaudeBubble(text: entry.text, images: images)
                    Spacer(minLength: 24)
                }
            case .relay:
                HStack {
                    Spacer(minLength: 44)
                    RelayBubble(text: entry.text, state: entry.relay?.state ?? .sent)
                }
            case .toolsOnly:
                EmptyView()
            }
            if !entry.tools.isEmpty {
                ToolsRow(tools: entry.tools, runningToolId: runningToolId)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }

    private var images: [RemoteImageRef] {
        guard let sessionId else { return [] }
        return entry.images.compactMap { image in
            if case .transcript(let itemId, let index) = image { return RemoteImageRef(sessionId: sessionId, itemId: itemId, index: index) }
            return nil
        }
    }
}

/// 吹き出しの形（送った側は右下、Claude は左下の角を小さくする）。
private enum BubbleShape {
    static var outgoing: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16)
    }

    static var incoming: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 4, bottomTrailingRadius: 16, topTrailingRadius: 16)
    }
}

private struct UserBubble: View {
    let text: String
    let images: [RemoteImageRef]

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty { RemoteImageGrid(images: images) }
            if !text.isEmpty {
                Text(ChatMarkdown.inline(text))
                    .font(DeckTheme.body)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(BubbleShape.outgoing.fill(DeckTheme.userBubble))
            }
        }
    }
}

private struct ClaudeBubble: View {
    let text: String
    let images: [RemoteImageRef]

    var body: some View {
        let shape = BubbleShape.incoming
        VStack(alignment: .leading, spacing: 6) {
            if !images.isEmpty { RemoteImageGrid(images: images) }
            if !text.isEmpty {
                MarkdownView(text: text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(shape.fill(DeckTheme.claudeBubble))
                    .overlay(shape.stroke(DeckTheme.claudeBubbleBorder))
            }
        }
    }
}

/// iPhone から送った伝言。本人の発話（青）と区別するため点線の枠で描く。
private struct RelayBubble: View {
    let text: String
    let state: RelayNote.State

    var body: some View {
        let shape = BubbleShape.outgoing
        VStack(alignment: .trailing, spacing: 4) {
            Label("伝言", systemImage: "envelope")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DeckTheme.permission)
            Text(ChatMarkdown.inline(text))
                .font(DeckTheme.body)
                .foregroundStyle(DeckTheme.text)
                .textSelection(.enabled)
                .lineSpacing(3)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(shape.fill(DeckTheme.permission.opacity(0.06)))
                .overlay(shape.stroke(DeckTheme.permission.opacity(0.8), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            switch state {
            case .sending:
                Text("送信中…").font(.system(size: 11)).foregroundStyle(DeckTheme.tertiary)
            case .sent:
                Text("別セッションからのメッセージとして送りました").font(.system(size: 11)).foregroundStyle(DeckTheme.tertiary)
            case .failed(let reason):
                Label("送れませんでした: \(reason)", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(DeckTheme.error)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

/// 直前の発話の下に畳むツール群。「ツール N件 ▸」を開くと名前と対象を並べる。
private struct ToolsRow: View {
    let tools: [TranscriptItem]
    let runningToolId: String?
    @State private var expanded = false

    var body: some View {
        let running = tools.first { $0.id == runningToolId }
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver").font(.system(size: 11))
                    Text("ツール \(tools.count)件")
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    if let running {
                        ProgressView().controlSize(.mini).tint(DeckTheme.working)
                        Text("実行中: \(running.tool?.name ?? "")").font(DeckTheme.mono).lineLimit(1)
                    }
                }
                .font(DeckTheme.caption)
                .foregroundStyle(running != nil ? DeckTheme.working : DeckTheme.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(running != nil ? DeckTheme.working.opacity(0.1) : DeckTheme.inputSurface))
                .overlay(Capsule().stroke(running != nil ? DeckTheme.working.opacity(0.4) : DeckTheme.border))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tools) { tool in
                        let isRunning = tool.id == runningToolId
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(tool.tool?.name ?? "?")
                                .foregroundStyle(isRunning ? DeckTheme.working : DeckTheme.text)
                                .fontWeight(.semibold)
                            Text(tool.tool?.target ?? tool.tool?.description ?? "")
                                .foregroundStyle(isRunning ? DeckTheme.working : DeckTheme.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        .font(DeckTheme.mono)
                    }
                }
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(DeckTheme.codeSurface))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(DeckTheme.border))
            }
        }
    }
}
