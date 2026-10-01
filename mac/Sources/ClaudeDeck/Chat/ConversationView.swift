import SwiftUI
import MonitorKit

/// 中央カラム: 見出し + （チャット / ターミナル / GitHub）。
struct ConversationView: View {
    @Bindable var model: ChatModel
    let room: Room

    var body: some View {
        let mode = model.mode(for: room.id)
        VStack(spacing: 0) {
            ConversationHeader(model: model, room: room, mode: mode)
            switch mode {
            case .chat:
                ChatPane(model: model, room: room)
            case .terminal:
                if let session = room.hosted {
                    TerminalHost(terminal: session.terminal)
                        .padding(8)
                        .background(Color.black)
                } else {
                    placeholder("外部セッションの端末はここでは開けません。")
                }
            case .github:
                if let mapping = model.boardMapping(for: room) {
                    ViewHost(view: model.boardView(for: mapping))
                } else {
                    placeholder("このプロジェクトには GitHub Project の紐づけがありません。")
                }
            case .appstore:
                if model.hasAppStore(room) {
                    ViewHost(view: model.appStoreView(for: room))
                } else {
                    placeholder("このプロジェクトは appstore.tsv に登録がありません。")
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(ChatTheme.body)
            .foregroundStyle(ChatTheme.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConversationHeader: View {
    let model: ChatModel
    let room: Room
    let mode: RoomMode

    var body: some View {
        HStack(spacing: 12) {
            RoomAvatar(name: room.name, status: nil, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(room.name)
                        .font(ChatTheme.headline)
                        .foregroundStyle(ChatTheme.heading)
                        .lineLimit(1)
                    StatusBadge(status: room.status)
                    if room.isExternal { ExternalTag() }
                }
                HStack(spacing: 4) {
                    if let branch = room.branch, !branch.isEmpty {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                        Text(branch)
                    } else {
                        Text(room.cwd).truncationMode(.middle)
                    }
                }
                .font(ChatTheme.mono)
                .foregroundStyle(ChatTheme.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            HeaderIconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "VS Code で開く") {
                model.openInVSCode(room)
            }
            if model.xcodeProject(for: room) != nil {
                HeaderIconButton(symbol: "hammer", help: "Xcode で開く") { model.openInXcode(room) }
            }
            // App Store は登録のあるプロジェクトだけ出す（他は無効表示で並べる）。
            ModeSegment(selected: mode,
                        modes: RoomMode.allCases.filter { $0 != .appstore || model.hasAppStore(room) },
                        isEnabled: { m in
                switch m {
                case .chat, .appstore: return true
                case .terminal: return room.hosted != nil
                case .github: return model.boardMapping(for: room) != nil
                }
            }) { model.setMode($0, for: room.id) }
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        .background(ChatTheme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(ChatTheme.border).frame(height: 1) }
    }
}

struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        let color = ChatTheme.color(for: status)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(ChatTheme.label(for: status))
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct HeaderIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ChatTheme.secondary)
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? ChatTheme.selectedRow : ChatTheme.inputSurface))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.inputBorder))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct ModeSegment: View {
    let selected: RoomMode
    let modes: [RoomMode]
    let isEnabled: (RoomMode) -> Bool
    let onSelect: (RoomMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes, id: \.self) { mode in
                let enabled = isEnabled(mode)
                Button { onSelect(mode) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.symbol).font(.system(size: 11))
                        Text(mode.title)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(mode == selected ? ChatTheme.heading : enabled ? ChatTheme.secondary : ChatTheme.tertiary.opacity(0.5))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(mode == selected ? ChatTheme.selectedRow : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(ChatTheme.inputSurface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.inputBorder))
    }
}

// MARK: - チャット

struct ChatPane: View {
    @Bindable var model: ChatModel
    let room: Room

    var body: some View {
        let items = model.transcript(for: room.sessionId)
        VStack(spacing: 0) {
            MessageList(model: model, room: room, items: items)
            Composer(text: Binding(get: { model.drafts[room.id] ?? "" }, set: { model.drafts[room.id] = $0 }),
                     disabledReason: ChatModel.inputDisabledReason(for: room)) { text in
                model.send(text, to: room)
            }
        }
        .background(ChatTheme.background)
    }
}

struct MessageList: View {
    let model: ChatModel
    let room: Room
    let items: [TranscriptItem]
    @State private var pinnedToBottom = true

    var body: some View {
        let entries = ChatTimeline.entries(from: items)
        let runningId = ChatTimeline.runningToolId(items: items, status: room.status)
        let permissions = model.monitorPermissions(for: room)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if entries.isEmpty { emptyState }
                    ForEach(entries) { entry in
                        EntryView(entry: entry, runningToolId: runningId)
                    }
                    ForEach(permissions) { permission in
                        PermissionCard(toolName: permission.toolName,
                                       description: permission.description,
                                       lines: permission.inputPreview.isEmpty ? [] : [permission.inputPreview],
                                       busy: model.busyPermissionKeys.contains(permission.key)) { allow in
                            model.decide(permission, allow ? .allow : .deny)
                        }
                    }
                    if permissions.isEmpty, let session = room.hosted, let prompt = session.permissionPrompt {
                        PermissionCard(toolName: room.snapshot?.currentTool ?? prompt.title,
                                       description: prompt.title,
                                       lines: prompt.lines,
                                       busy: model.busyPermissionKeys.contains(ChatModel.ptyPermissionKey(session))) { allow in
                            model.answerOnTerminal(session, prompt: prompt, allow: allow)
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
        let prompt = room.hosted?.permissionPrompt != nil
        return "\(entries.count):\(last?.tools.count ?? 0):\(last?.text.count ?? 0):\(permissions):\(prompt)"
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
            return ("bolt.horizontal.circle", "monitor に未接続のため会話を表示できません。\nターミナルに切り替えると操作できます。")
        }
        guard let sessionId = room.sessionId else {
            if room.hosted?.end == .launchFailed {
                return ("exclamationmark.triangle", "claude を起動できませんでした。\nログインシェルの PATH に claude があるか確かめてください。")
            }
            if room.hosted?.end != nil { return ("stop.circle", "会話を取得する前に claude が終了しました。") }
            return ("hourglass", "セッションの開始を待っています…")
        }
        if model.loadingTranscripts.contains(sessionId) { return ("arrow.triangle.2.circlepath", "会話を読み込んでいます…") }
        if let error = model.transcriptErrors[sessionId] { return ("exclamationmark.triangle", error) }
        return ("bubble.left.and.bubble.right", room.hosted != nil ? "下の入力欄から指示を送れます。" : "まだ会話がありません。")
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

struct EntryView: View {
    let entry: ChatEntry
    let runningToolId: String?

    var body: some View {
        VStack(alignment: entry.role == .user ? .trailing : .leading, spacing: 6) {
            switch entry.role {
            case .user:
                HStack {
                    Spacer(minLength: 96)
                    UserBubble(text: entry.text)
                }
            case .assistant:
                HStack {
                    ClaudeBubble(text: entry.text)
                    Spacer(minLength: 96)
                }
            case .toolsOnly:
                EmptyView()
            }
            if !entry.tools.isEmpty {
                ToolsRow(tools: entry.tools, runningToolId: runningToolId)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: entry.role == .user ? .trailing : .leading)
    }
}

struct UserBubble: View {
    let text: String

    var body: some View {
        Text(ChatMarkdown.inline(text))
            .font(ChatTheme.body)
            .foregroundStyle(.white)
            .textSelection(.enabled)
            .lineSpacing(3)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16,
                                               bottomTrailingRadius: 4, topTrailingRadius: 16)
                .fill(ChatTheme.userBubble))
    }
}

struct ClaudeBubble: View {
    let text: String

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 4,
                                           bottomTrailingRadius: 16, topTrailingRadius: 16)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ChatMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let paragraph):
                    Text(ChatMarkdown.inline(paragraph))
                        .font(ChatTheme.body)
                        .foregroundStyle(ChatTheme.text)
                        .lineSpacing(3)
                case .code(_, let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(ChatTheme.mono)
                            .foregroundStyle(ChatTheme.text)
                            .padding(10)
                    }
                    .background(RoundedRectangle(cornerRadius: 9).fill(ChatTheme.codeSurface))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.border))
                }
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(shape.fill(ChatTheme.claudeBubble))
        .overlay(shape.stroke(ChatTheme.claudeBubbleBorder))
    }
}

/// 直前の発話の下に畳むツール群。「ツール N件 ▸」を開くと名前と対象を並べる。
struct ToolsRow: View {
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
                        ProgressView().controlSize(.mini).tint(ChatTheme.working)
                        Text("実行中: \(running.tool?.name ?? "")")
                            .font(ChatTheme.mono)
                            .foregroundStyle(ChatTheme.working)
                    }
                }
                .font(ChatTheme.caption)
                .foregroundStyle(running != nil ? ChatTheme.working : ChatTheme.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(running != nil ? ChatTheme.working.opacity(0.1) : ChatTheme.inputSurface))
                .overlay(Capsule().stroke(running != nil ? ChatTheme.working.opacity(0.4) : ChatTheme.border))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tools) { tool in
                        let isRunning = tool.id == runningToolId
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(tool.tool?.name ?? "?")
                                .foregroundStyle(isRunning ? ChatTheme.working : ChatTheme.text)
                                .fontWeight(.semibold)
                            Text(tool.tool?.target ?? tool.tool?.description ?? "")
                                .foregroundStyle(isRunning ? ChatTheme.working : ChatTheme.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(ChatTheme.mono)
                    }
                }
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: 640, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(ChatTheme.codeSurface))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.border))
            }
        }
    }
}

/// 権限待ちのカード（会話の末尾）。
struct PermissionCard: View {
    let toolName: String
    let description: String
    let lines: [String]
    let busy: Bool
    let onDecide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(ChatTheme.permission)
                Text("権限の確認").font(.system(size: 13, weight: .bold)).foregroundStyle(ChatTheme.heading)
                Text(toolName)
                    .font(ChatTheme.mono.weight(.semibold))
                    .foregroundStyle(ChatTheme.permission)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(ChatTheme.permission.opacity(0.14)))
            }
            if !description.isEmpty, description != toolName {
                Text(description).font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
            }
            if !lines.isEmpty {
                Text(lines.prefix(10).joined(separator: "\n"))
                    .font(ChatTheme.mono)
                    .foregroundStyle(ChatTheme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(ChatTheme.codeSurface))
            }
            HStack(spacing: 8) {
                Button { onDecide(true) } label: {
                    Text("許可")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ChatTheme.onAccent)
                        .frame(width: 84, height: 30)
                        .background(RoundedRectangle(cornerRadius: 9).fill(ChatTheme.accent))
                }
                .buttonStyle(.plain)
                Button { onDecide(false) } label: {
                    Text("拒否")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ChatTheme.text)
                        .frame(width: 84, height: 30)
                        .background(RoundedRectangle(cornerRadius: 9).fill(ChatTheme.inputSurface))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.inputBorder))
                }
                .buttonStyle(.plain)
                if busy {
                    ProgressView().controlSize(.small)
                    Text("送信中…").font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
                }
            }
            .disabled(busy)
            .opacity(busy ? 0.6 : 1)
        }
        .padding(14)
        .frame(maxWidth: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(ChatTheme.permission.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ChatTheme.permission, lineWidth: 1.5))
    }
}
