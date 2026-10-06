import SwiftUI
import MonitorKit

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

/// 見出しの「VS Code」「GitHub」「リンク」「Xcode」「閉じる」と、押した結果の短い一言。
struct EditorButtons: View {
    let model: ChatModel
    let room: Room
    @State private var confirmingClose = false

    var body: some View {
        let editors = model.editors
        let xcodeProject = editors.xcodeProject(for: room)
        let closing = editors.closingXcode.contains(room.id)
        HStack(spacing: 6) {
            if let note = editors.notes[room.id] {
                Text(note.outcome.message)
                    .font(ChatTheme.caption)
                    .foregroundStyle(note.outcome.isFailure ? ChatTheme.error : ChatTheme.working)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 200, alignment: .trailing)
                    .help(note.outcome.message)
            }
            HeaderButton(symbol: "chevron.left.forwardslash.chevron.right", name: "VS Code",
                         detail: "VS Code で開く: \(room.cwd)") { editors.openInVSCode(room) }
            GitHubButton(editors: editors, room: room, destinations: editors.githubDestinations(for: room),
                         opening: editors.openingGitHub.contains(room.id))
            ProjectLinkButton(editors: editors, room: room, links: editors.projectLinks(for: room))
            if let xcodeProject {
                HeaderButton(symbol: "hammer", name: "Xcode",
                             detail: "Xcode で開く: \(xcodeProject.path)") { editors.openInXcode(room) }
                HeaderButton(symbol: "xmark.rectangle", name: "閉じる",
                             detail: "Xcode からこのワークスペースだけを閉じる（Xcode は終了しません）",
                             busyStatus: closing ? "閉じています…" : nil) { confirmingClose = true }
                    .confirmationDialog("Xcode から閉じますか？", isPresented: $confirmingClose) {
                        Button("閉じる", role: .destructive) { editors.closeInXcode(room) }
                        Button("やめる", role: .cancel) {}
                    } message: {
                        Text("\(xcodeProject.lastPathComponent) を Xcode から閉じます。Xcode は終了せず、起動していなければ何もしません。未保存の変更があれば Xcode が確認を出します。")
                    }
            }
        }
        .fixedSize()
    }
}

/// 開く先が 1 つならそのまま開き、ボードとリポジトリの両方ならメニューで選ぶ。
struct GitHubButton: View {
    let editors: EditorLauncher
    let room: Room
    let destinations: [GitHubDestination]
    let opening: Bool
    @State private var hovering = false

    private static let symbol = "rectangle.3.group"
    private static let name = "GitHub"

    private var busyStatus: String? { opening ? "開いています…" : nil }

    var body: some View {
        if destinations.count == 1, let only = destinations.first {
            HeaderButton(symbol: Self.symbol, name: Self.name, detail: only.help, busyStatus: busyStatus) { editors.openOnGitHub(only, for: room) }
        } else if destinations.count > 1 {
            Menu {
                ForEach(Array(destinations.enumerated()), id: \.offset) { _, destination in
                    Button(destination.menuTitle) { editors.openOnGitHub(destination, for: room) }
                }
            } label: {
                HeaderButtonLabel(symbol: Self.symbol, busy: opening, disabled: opening, hovering: hovering, showsMenu: true)
            }
            .disabled(opening)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .headerButtonHelp(name: Self.name, detail: destinations.map(\.help).joined(separator: "\n"), busyStatus: busyStatus)
            .onHover { hovering = $0 }
        }
    }
}

/// 設定のリンク（LP 等）。1 つならそのまま開き、複数なら名前のメニューで選ぶ。無ければ出さない。
struct ProjectLinkButton: View {
    let editors: EditorLauncher
    let room: Room
    let links: [ProjectLink]
    @State private var hovering = false

    private static let symbol = "link"
    private static let name = "リンク"

    var body: some View {
        if links.count == 1, let only = links.first {
            HeaderButton(symbol: Self.symbol, name: Self.name, detail: ProjectLinks.help(for: only)) { editors.openLink(only, for: room) }
        } else if links.count > 1 {
            Menu {
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    Button(link.name) { editors.openLink(link, for: room) }
                }
            } label: {
                HeaderButtonLabel(symbol: Self.symbol, busy: false, disabled: false, hovering: hovering, showsMenu: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .headerButtonHelp(name: Self.name, detail: links.map(ProjectLinks.help(for:)).joined(separator: "\n"), busyStatus: nil)
            .onHover { hovering = $0 }
        }
    }
}

/// 見出しのアイコンボタンの見た目。名前は出さずホバーの help と VoiceOver に回す。
struct HeaderButtonLabel: View {
    let symbol: String
    let busy: Bool
    let disabled: Bool
    let hovering: Bool
    var showsMenu = false

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
        .foregroundStyle(disabled ? ChatTheme.tertiary : ChatTheme.text)
        .frame(minWidth: Self.side, minHeight: Self.side, maxHeight: Self.side)
        .padding(.horizontal, showsMenu ? 4 : 0)
        .background(RoundedRectangle(cornerRadius: 9).fill(hovering && !disabled ? ChatTheme.selectedRow : ChatTheme.inputSurface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.inputBorder))
        .contentShape(Rectangle())
    }
}

extension View {
    /// ホバーの help は名前を先頭に、処理中は状態、そうでなければ開く先を続ける。
    func headerButtonHelp(name: String, detail: String?, busyStatus: String?) -> some View {
        let lines = [name, busyStatus ?? detail].compactMap { $0 }.filter { !$0.isEmpty }
        return help(lines.joined(separator: "\n"))
            .accessibilityLabel(name)
            .accessibilityValue(busyStatus ?? "")
    }
}

struct HeaderButton: View {
    let symbol: String
    let name: String
    var detail: String? = nil
    var busyStatus: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let busy = busyStatus != nil
        Button(action: action) {
            HeaderButtonLabel(symbol: symbol, busy: busy, disabled: busy, hovering: hovering)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .headerButtonHelp(name: name, detail: detail, busyStatus: busyStatus)
        .onHover { hovering = $0 }
    }
}
