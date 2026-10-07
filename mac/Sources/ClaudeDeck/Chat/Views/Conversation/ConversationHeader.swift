import SwiftUI
import MonitorKit

struct ConversationHeader: View {
    let model: ChatModel
    let room: Room

    var body: some View {
        HStack(spacing: 12) {
            PixelAvatar(status: room.status, size: 38)
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
            .frame(minWidth: HeaderLayout.titleMinWidth, alignment: .leading)
            Spacer(minLength: 12)
            // 名前を最小幅まで縮めてからボタンを「…」に回す。
            EditorButtons(model: model, room: room).layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        // 下線は背景側に置き、ボタンの吹き出しが線の下に潜らないようにする。
        .background {
            ChatTheme.background.overlay(alignment: .bottom) { Rectangle().fill(ChatTheme.border).frame(height: 1) }
        }
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

/// 見出しの「VS Code」「GitHub」「リンク」「Xcode」「閉じる」と、押した結果の短い一言。
struct EditorButtons: View {
    let model: ChatModel
    let room: Room
    @State private var confirmingClose = false

    var body: some View {
        let editors = model.editors
        let target = room.editorTarget
        let xcodeProject = editors.xcodeProject(for: target)
        let closing = editors.closingXcode.contains(target.key)
        var actions: [HeaderAction] = [
            .button(id: "vscode", priority: 5, symbol: VSCodeButton.symbol, name: VSCodeButton.name,
                    detail: VSCodeButton.detail(target)) { editors.openInVSCode(target) },
        ]
        if let github = HeaderAction.github(priority: 3, editors: editors, target: target) { actions.append(github) }
        actions += HeaderAction.pins(priority: 2, editors: editors, target: target)
        if let links = HeaderAction.links(priority: 2, editors: editors, target: target) { actions.append(links) }
        if let xcodeProject {
            actions.append(.button(id: "xcode", priority: 4, symbol: "hammer", name: "Xcode",
                                   detail: "Xcode で開く: \(xcodeProject.path)") { editors.openInXcode(target) })
            actions.append(.button(id: "xcode-close", priority: 1, symbol: "xmark.rectangle", name: "閉じる",
                                   detail: "Xcode からこのワークスペースだけを閉じる（Xcode は終了しません）",
                                   busyStatus: closing ? "閉じています…" : nil) { confirmingClose = true })
        }
        return HStack(spacing: 6) {
            EditorNoteText(note: editors.notes[target.key])
            HeaderActionRow(actions: actions).layoutPriority(1)
        }
        // メニューから押しても確認を出せるよう、ボタンではなく列に付ける。
        .confirmationDialog("Xcode から閉じますか？", isPresented: $confirmingClose) {
            Button("閉じる", role: .destructive) { editors.closeInXcode(target) }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("\(xcodeProject?.lastPathComponent ?? "ワークスペース") を Xcode から閉じます。Xcode は終了せず、起動していなければ何もしません。未保存の変更があれば Xcode が確認を出します。")
        }
    }
}

/// 押した結果の短い一言（無ければ何も出さない）。
struct EditorNoteText: View {
    let note: EditorNote?

    var body: some View {
        if let note {
            Text(note.outcome.message)
                .font(ChatTheme.caption)
                .foregroundStyle(note.outcome.isFailure ? ChatTheme.error : ChatTheme.working)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 200, alignment: .trailing)
                .help(note.outcome.message)
        }
    }
}

struct VSCodeButton: View {
    let editors: EditorLauncher
    let target: EditorTarget

    static let symbol = "chevron.left.forwardslash.chevron.right"
    static let name = "VS Code"
    static func detail(_ target: EditorTarget) -> String { "VS Code で開く: \(target.cwd)" }

    var body: some View {
        HeaderButton(symbol: Self.symbol, name: Self.name, detail: Self.detail(target)) { editors.openInVSCode(target) }
    }
}

/// 開く先が 1 つならそのまま開き、ボードとリポジトリの両方ならメニューで選ぶ。
struct GitHubButton: View {
    let editors: EditorLauncher
    let target: EditorTarget
    let destinations: [GitHubDestination]
    let opening: Bool
    @State private var hovering = false

    static let symbol = "rectangle.3.group"
    static let name = "GitHub"

    private var busyStatus: String? { opening ? "開いています…" : nil }

    var body: some View {
        if destinations.count == 1, let only = destinations.first {
            HeaderButton(symbol: Self.symbol, name: Self.name, detail: only.help, busyStatus: busyStatus) { editors.openOnGitHub(only, for: target) }
        } else if destinations.count > 1 {
            Menu {
                ForEach(Array(destinations.enumerated()), id: \.offset) { _, destination in
                    Button(destination.menuTitle) { editors.openOnGitHub(destination, for: target) }
                }
            } label: {
                HeaderButtonLabel(symbol: Self.symbol, busy: opening, hovering: hovering, showsMenu: true)
            }
            .disabled(opening)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .headerButtonHelp(name: Self.name, detail: destinations.map(\.help).joined(separator: "\n"), busyStatus: busyStatus)
            .trackHover($hovering)
        }
    }
}

/// 設定のリンク（LP 等）。1 つならそのまま開き、複数なら名前のメニューで選ぶ。無ければ出さない。
struct ProjectLinkButton: View {
    let editors: EditorLauncher
    let target: EditorTarget
    let links: [ProjectLink]
    @State private var hovering = false

    static let symbol = "link"
    static let name = "リンク"

    var body: some View {
        if links.count == 1, let only = links.first {
            HeaderButton(symbol: Self.symbol, name: Self.name, detail: ProjectLinks.help(for: only)) { editors.openLink(only, for: target) }
        } else if links.count > 1 {
            Menu {
                ProjectLinkMenuItems(links: links) { editors.openLink($0, for: target) }
            } label: {
                HeaderButtonLabel(symbol: Self.symbol, busy: false, hovering: hovering, showsMenu: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .headerButtonHelp(name: Self.name, detail: links.map(ProjectLinks.help(for:)).joined(separator: "\n"), busyStatus: nil)
            .trackHover($hovering)
        }
    }
}

/// 「リンク」のメニューの項目。種類のアイコンを添え、種類が 2 つ以上あれば種類ごとに区切る。
struct ProjectLinkMenuItems: View {
    let links: [ProjectLink]
    let open: (ProjectLink) -> Void

    var body: some View {
        let groups = ProjectLinks.grouped(links)
        if groups.count <= 1 {
            items(links)
        } else {
            ForEach(groups, id: \.kind) { group in
                Section(group.kind.label) { items(group.links) }
            }
        }
    }

    private func items(_ links: [ProjectLink]) -> some View {
        ForEach(Array(links.enumerated()), id: \.offset) { _, link in
            Button { open(link) } label: { Label(link.name, systemImage: link.resolvedKind.symbol) }
        }
    }
}

/// 見出しのアイコンボタンの見た目。名前は出さずホバーの吹き出しと VoiceOver に回す。
struct HeaderButtonLabel: View {
    let symbol: String
    /// 処理中は回転の印にして押せない色にする。
    let busy: Bool
    let hovering: Bool
    var showsMenu = false
    /// 右上に小さな黄色の点（確認が必要なピン）。
    var dot = false

    private static let side: CGFloat = 30

    var body: some View {
        HStack(spacing: 2) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 14, height: 14)
            if showsMenu { Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)) }
        }
        .foregroundStyle(busy ? ChatTheme.tertiary : ChatTheme.text)
        .frame(minWidth: Self.side, minHeight: Self.side, maxHeight: Self.side)
        .padding(.horizontal, showsMenu ? 4 : 0)
        .background(RoundedRectangle(cornerRadius: 9).fill(hovering && !busy ? ChatTheme.selectedRow : ChatTheme.inputSurface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.inputBorder))
        .overlay(alignment: .topTrailing) {
            if dot {
                Circle()
                    .fill(ChatTheme.permission)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(ChatTheme.background, lineWidth: 1.5))
                    .offset(x: 2, y: -2)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

extension View {
    /// ホバーを持ち、画面から外れたら落とす（ViewThatFits の外れた候補は状態が残り、強調が付いたまま戻るため）。
    func trackHover(_ hovering: Binding<Bool>) -> some View {
        onHover { hovering.wrappedValue = $0 }
            .onDisappear { hovering.wrappedValue = false }
    }

    /// 名前と開く先（処理中は状態）を自前のツールチップで出し、VoiceOver には名前と状態を渡す。
    func headerButtonHelp(name: String, detail: String?, busyStatus: String?) -> some View {
        let details = HeaderTooltip.details(detail: detail, busyStatus: busyStatus)
        return modifier(HeaderTooltipModifier(name: name, details: details))
            .accessibilityLabel(name)
            .accessibilityValue(busyStatus ?? "")
            .accessibilityHint(busyStatus == nil ? details.joined(separator: "\n") : "")
    }
}

/// ホバーが少し続いたらボタンの下に出す吹き出し。
struct HeaderTooltip: View {
    let name: String
    let details: [String]

    static let delay: Duration = .milliseconds(400)
    static let maxWidth: CGFloat = 340

    /// 処理中は状態、そうでなければ開く先を、空行を除いて 1 行ずつ。
    static func details(detail: String?, busyStatus: String?) -> [String] {
        (busyStatus ?? detail ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ChatTheme.heading)
            ForEach(Array(details.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(ChatTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8).fill(ChatTheme.claudeBubble))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ChatTheme.claudeBubbleBorder))
    }
}

/// AppKit のツールチップは頻繁な再描画で待ち時間がやり直しになるため、ホバーとタイマーをここで持って自前で出す。
struct HeaderTooltipModifier: ViewModifier {
    let name: String
    let details: [String]
    /// nil ならボタンの下（右端そろえ）、値があればボタンの左端からその距離だけ右に出す。
    var leadingOffset: CGFloat? = nil
    @State private var hovering = false
    @State private var shown = false
    /// クリックした後はカーソルが一度離れるまで出さない（開いたメニューに重ねない）。
    @State private var suppressed = false
    @State private var timer: Task<Void, Never>?
    @State private var clickMonitor: Any?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { schedule() } else { reset() }
            }
            .overlay(alignment: leadingOffset == nil ? .bottomTrailing : .leading) {
                if shown {
                    // overlay はボタンの幅を提案するので、幅の枠を与えてから端をそろえる。
                    if let leadingOffset {
                        HeaderTooltip(name: name, details: details)
                            .frame(width: HeaderTooltip.maxWidth, alignment: .leading)
                            .alignmentGuide(.leading) { $0[.leading] - leadingOffset }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .transition(.opacity)
                    } else {
                        HeaderTooltip(name: name, details: details)
                            .frame(width: HeaderTooltip.maxWidth, alignment: .trailing)
                            .alignmentGuide(.bottom) { $0[.top] - 6 }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .transition(.opacity)
                    }
                }
            }
            .onDisappear {
                // ViewThatFits の外れた候補は状態が残るため、ホバー中のまま戻ってきて次の入りを取りこぼさないよう落とす。
                hovering = false
                reset()
            }
    }

    private func schedule() {
        timer?.cancel()
        installClickMonitor()
        guard !suppressed else { return }
        timer = Task { @MainActor in
            try? await Task.sleep(for: HeaderTooltip.delay)
            guard !Task.isCancelled, hovering, !suppressed else { return }
            withAnimation(.easeOut(duration: 0.12)) { shown = true }
        }
    }

    private func reset() {
        timer?.cancel()
        timer = nil
        shown = false
        suppressed = false
        removeClickMonitor()
    }

    /// ホバー中のクリックはこのボタンへのものなので、メニューや確認が開く前に吹き出しを消す。
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            timer?.cancel()
            shown = false
            suppressed = true
            return event
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}

struct HeaderButton: View {
    let symbol: String
    let name: String
    var detail: String? = nil
    var busyStatus: String? = nil
    var dot = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let busy = busyStatus != nil
        Button(action: action) {
            HeaderButtonLabel(symbol: symbol, busy: busy, hovering: hovering, dot: dot)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .headerButtonHelp(name: name, detail: detail, busyStatus: busyStatus)
        .trackHover($hovering)
    }
}
