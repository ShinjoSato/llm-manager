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

struct ConversationHeader: View {
    let model: ChatModel
    let room: Room

    var body: some View {
        HStack(spacing: 12) {
            PixelAvatar(status: room.status, size: 38, hidesFromAccessibility: true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(room.name)
                        .font(ChatTheme.headline)
                        .foregroundStyle(ChatTheme.heading)
                        .lineLimit(1)
                    StatusBadge(status: room.status)
                    if room.isExternal { ExternalTag(label: "外部セッション") }
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
            EditorButtons(model: model, room: room)
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

/// 見出しの「VS Code」「Xcode」「閉じる」と、押した結果の短い一言。
struct EditorButtons: View {
    let model: ChatModel
    let room: Room
    @State private var confirmingClose = false

    var body: some View {
        let xcodeProject = model.xcodeProject(for: room)
        let closing = model.closingXcode.contains(room.id)
        HStack(spacing: 6) {
            if let note = model.editorNotes[room.id] {
                Text(note.outcome.message)
                    .font(ChatTheme.caption)
                    .foregroundStyle(note.outcome.isFailure ? ChatTheme.error : ChatTheme.working)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 200, alignment: .trailing)
                    .help(note.outcome.message)
            }
            HeaderButton(symbol: "chevron.left.forwardslash.chevron.right", title: "VS Code",
                         help: "VS Code で開く: \(room.cwd)") { model.openInVSCode(room) }
            if let xcodeProject {
                HeaderButton(symbol: "hammer", title: "Xcode",
                             help: "Xcode で開く: \(xcodeProject.path)") { model.openInXcode(room) }
                HeaderButton(symbol: "xmark", title: closing ? "閉じています…" : "閉じる",
                             help: "Xcode からこのワークスペースだけを閉じる（Xcode は終了しません）",
                             disabled: closing) { confirmingClose = true }
                    .confirmationDialog("Xcode から閉じますか？", isPresented: $confirmingClose) {
                        Button("閉じる", role: .destructive) { model.closeInXcode(room) }
                        Button("やめる", role: .cancel) {}
                    } message: {
                        Text("\(xcodeProject.lastPathComponent) を Xcode から閉じます。Xcode は終了せず、起動していなければ何もしません。未保存の変更があれば Xcode が確認を出します。")
                    }
            }
        }
        .fixedSize()
    }
}

struct HeaderButton: View {
    let symbol: String
    let title: String
    let help: String
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(disabled ? ChatTheme.tertiary : ChatTheme.text)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(hovering && !disabled ? ChatTheme.selectedRow : ChatTheme.inputSurface))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.inputBorder))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .onHover { hovering = $0 }
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
                     disabledReason: model.inputDisabledReason(for: room),
                     relay: room.isExternal) { text in
                room.isExternal ? model.sendRelay(text, to: room) : model.send(text, to: room)
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
        let entries = ChatTimeline.entries(from: items, notes: model.notes(for: room.sessionId))
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
                    if permissions.isEmpty, room.isExternal, room.status == .permission {
                        ChannelsMissingCard(toolName: room.snapshot?.currentTool)
                    }
                    if permissions.isEmpty, let session = room.hosted, let prompt = session.permissionPrompt {
                        PermissionCard(toolName: room.snapshot?.currentTool ?? prompt.title,
                                       description: prompt.title,
                                       lines: prompt.lines,
                                       busy: model.busyPermissionKeys.contains(ChatModel.ptyPermissionKey(session))) { allow in
                            model.answerOnTerminal(session, prompt: prompt, allow: allow)
                        }
                    }
                    if permissions.isEmpty, let session = room.hosted, session.permissionPrompt == nil, session.inputBlock == .menu {
                        let key = ChatModel.ptyMenuKey(session)
                        let busy = model.busyPermissionKeys.contains(key)
                        if let menu = session.menuPrompt {
                            MenuCard(menu: menu, busy: busy, notice: model.menuNotices[key]) { choice in
                                model.answerMenu(session, menu: menu, choice: choice)
                            }
                        } else if let unreadable = session.unreadableMenu {
                            UnreadableMenuCard(menu: unreadable, busy: busy) { model.cancelUnreadableMenu(session, menu: unreadable) }
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
        return "\(entries.count):\(last?.tools.count ?? 0):\(last?.text.count ?? 0):\(permissions):\(prompt):\(menu)"
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
            return ("bolt.horizontal.circle", "monitor に未接続のため会話を表示できません。"
                    + (room.hosted?.isRunning == true ? "\n下の入力欄からの送信はできます。" : ""))
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

struct EntryView: View {
    let entry: ChatEntry
    let runningToolId: String?

    var body: some View {
        let trailing = entry.role == .user || entry.role == .relay
        VStack(alignment: trailing ? .trailing : .leading, spacing: 6) {
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
            case .relay:
                HStack {
                    Spacer(minLength: 96)
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
        MarkdownView(text: text)
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

/// 端末に出ている選択メニュー（plan の承認・選択式の質問・trust 確認など）のカード。権限カードと同じ位置に出す。
struct MenuCard: View {
    let menu: MenuPrompt
    let busy: Bool
    /// 直前の操作の結果（複数選択でチェックを切り替えた等）。
    let notice: String?
    /// 選択肢の位置。nil は取り消し（Esc）。
    let onChoose: (Int?) -> Void
    @State private var confirmingExit = false

    /// 今の ❯ から自由入力の行をまたがないと届かない選択肢があるか。
    private var crossesFreeText: Bool {
        menu.options.indices.contains { index in
            guard !menu.options[index].isFreeText else { return false }
            let range = index > menu.cursor ? (menu.cursor + 1)..<index : (index + 1)..<max(index + 1, menu.cursor)
            return range.contains { menu.options[$0].isFreeText }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.circle.fill").foregroundStyle(ChatTheme.permission)
                Text("選択肢").font(.system(size: 13, weight: .bold)).foregroundStyle(ChatTheme.heading)
            }
            if !menu.context.isEmpty {
                Text(menu.context.joined(separator: "\n"))
                    .font(ChatTheme.mono)
                    .foregroundStyle(ChatTheme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(ChatTheme.codeSurface))
            }
            if !menu.question.isEmpty {
                Text(menu.question).font(ChatTheme.body.weight(.semibold)).foregroundStyle(ChatTheme.heading)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(menu.options.enumerated()), id: \.offset) { index, option in
                    MenuOptionRow(option: option, isCursor: index == menu.cursor) { onChoose(index) }
                }
            }
            if menu.isMultiSelect {
                Text("複数選択: 押すとチェックを切り替えます。")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.secondary)
            }
            if menu.options.contains(where: \.isFreeText) {
                Text("文字を入力する選択肢はここからは選べません。「キャンセル」で閉じてから、下の入力欄で伝えてください。"
                     + (crossesFreeText ? "その行をまたぐ選択肢は、通り抜ける途中で端末の表示が読めなくなると Enter を押さずに止まります。" : ""))
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.secondary)
            }
            if let notice {
                Text(notice).font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
            }
            HStack(spacing: 8) {
                Button {
                    if menu.cancelExits { confirmingExit = true } else { onChoose(nil) }
                } label: {
                    Text(menu.cancelExits ? "終了（Esc）" : "キャンセル（Esc）")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ChatTheme.text)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 9).fill(ChatTheme.inputSurface))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.inputBorder))
                }
                .buttonStyle(.plain)
                if busy {
                    ProgressView().controlSize(.small)
                    Text("送信中…").font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
                }
            }
        }
        .disabled(busy)
        .opacity(busy ? 0.6 : 1)
        .padding(14)
        .frame(maxWidth: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(ChatTheme.permission.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ChatTheme.permission, lineWidth: 1.5))
        .exitConfirmation(isPresented: $confirmingExit) { onChoose(nil) }
    }
}

private extension View {
    /// Esc が claude の終了になるメニューで、送る前に確かめる。
    func exitConfirmation(isPresented: Binding<Bool>, onExit: @escaping () -> Void) -> some View {
        confirmationDialog("claude を終了しますか？", isPresented: isPresented) {
            Button("終了する（Esc）", role: .destructive, action: onExit)
            Button("やめる", role: .cancel) {}
        } message: {
            Text("このメニューで Esc を押すと、取り消しではなく Claude Code の終了になります。")
        }
    }
}

private struct MenuOptionRow: View {
    let option: MenuPrompt.Option
    /// 端末で今 ❯ が付いている行（Enter だけで決まる行）。
    let isCursor: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let disabled = option.isFreeText
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(option.number.map { "\($0)." } ?? "•")
                    .font(ChatTheme.mono.weight(.semibold))
                    .foregroundStyle(ChatTheme.permission)
                if let checked = option.checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? ChatTheme.permission : ChatTheme.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(disabled ? ChatTheme.tertiary : ChatTheme.text)
                    ForEach(Array(option.detail.enumerated()), id: \.offset) { _, line in
                        Text(line).font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
                    }
                }
                Spacer(minLength: 8)
                if disabled {
                    Text("入力は対象外").font(ChatTheme.caption).foregroundStyle(ChatTheme.tertiary)
                } else if isCursor {
                    Text("選択中").font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(hovering && !disabled ? ChatTheme.selectedRow : ChatTheme.inputSurface))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(isCursor && !disabled ? ChatTheme.permission.opacity(0.6) : ChatTheme.inputBorder))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(disabled ? "文字の入力に移る選択肢はカードからは選べません" : option.label)
        .onHover { hovering = $0 }
    }
}

/// 選択メニューは出ているが中身を読み取れない時のカード。閉じる（Esc）ことだけはできる。
struct UnreadableMenuCard: View {
    let menu: UnreadableMenu
    let busy: Bool
    let onCancel: () -> Void
    @State private var confirmingExit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.circle.fill").foregroundStyle(ChatTheme.permission)
                Text("選択肢").font(.system(size: 13, weight: .bold)).foregroundStyle(ChatTheme.heading)
            }
            Text(menu.cancelExits
                 ? "端末に選択肢が出ていますが、内容を読み取れませんでした。このメニューで Esc を押すと Claude Code が終了します。"
                 : "端末に選択肢が出ていますが、内容を読み取れませんでした。閉じると Claude Code は取り消しとして扱います。")
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.secondary)
            HStack(spacing: 8) {
                Button {
                    if menu.cancelExits { confirmingExit = true } else { onCancel() }
                } label: {
                    Text(menu.cancelExits ? "終了（Esc）" : "キャンセル（Esc）")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ChatTheme.text)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 9).fill(ChatTheme.inputSurface))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.inputBorder))
                }
                .buttonStyle(.plain)
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)
        }
        .padding(14)
        .frame(maxWidth: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(ChatTheme.permission.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ChatTheme.permission, lineWidth: 1.5))
        .exitConfirmation(isPresented: $confirmingExit, onExit: onCancel)
    }
}
