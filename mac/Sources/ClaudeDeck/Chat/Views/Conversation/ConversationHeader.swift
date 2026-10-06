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

/// 見出しの「VS Code」「GitHub」「Xcode」「閉じる」と、押した結果の短い一言。
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
            HeaderButton(symbol: "chevron.left.forwardslash.chevron.right", title: "VS Code",
                         help: "VS Code で開く: \(room.cwd)") { editors.openInVSCode(room) }
            GitHubButton(editors: editors, room: room, destinations: editors.githubDestinations(for: room),
                         opening: editors.openingGitHub.contains(room.id))
            if let xcodeProject {
                HeaderButton(symbol: "hammer", title: "Xcode",
                             help: "Xcode で開く: \(xcodeProject.path)") { editors.openInXcode(room) }
                HeaderButton(symbol: "xmark", title: closing ? "閉じています…" : "閉じる",
                             help: "Xcode からこのワークスペースだけを閉じる（Xcode は終了しません）",
                             disabled: closing) { confirmingClose = true }
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

    var body: some View {
        if destinations.count == 1, let only = destinations.first {
            HeaderButton(symbol: Self.symbol, title: opening ? "開いています…" : "GitHub", help: only.help, disabled: opening) { editors.openOnGitHub(only, for: room) }
        } else if destinations.count > 1 {
            Menu {
                ForEach(Array(destinations.enumerated()), id: \.offset) { _, destination in
                    Button(destination.menuTitle) { editors.openOnGitHub(destination, for: room) }
                }
            } label: {
                HeaderButtonLabel(symbol: Self.symbol, title: opening ? "開いています…" : "GitHub", disabled: opening, hovering: hovering, showsMenu: true)
            }
            .disabled(opening)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(destinations.map(\.help).joined(separator: "\n"))
            .onHover { hovering = $0 }
        }
    }
}

struct HeaderButtonLabel: View {
    let symbol: String
    let title: String
    let disabled: Bool
    let hovering: Bool
    var showsMenu = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            Text(title)
            if showsMenu { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(disabled ? ChatTheme.tertiary : ChatTheme.text)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9).fill(hovering && !disabled ? ChatTheme.selectedRow : ChatTheme.inputSurface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.inputBorder))
        .contentShape(Rectangle())
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
            HeaderButtonLabel(symbol: symbol, title: title, disabled: disabled, hovering: hovering)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .onHover { hovering = $0 }
    }
}
