import SwiftUI
import MonitorKit

/// 左カラム: ルーム一覧（検索・新規・接続状態・グループ）。
struct RoomListView: View {
    @Bindable var model: ChatModel
    @State private var showingLauncher = false

    var body: some View {
        VStack(spacing: 0) {
            header
            search
            if !model.store.connection.isConnected { ConnectionNotice(connection: model.store.connection) }
            if let notice = HookServerNotice.text(for: model.store.serverState) { HookServerNotice(text: notice) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let items = model.listItems
                    if items.isEmpty { emptyState }
                    ForEach(items) { item in
                        switch item.kind {
                        case .header(let phase, let count):
                            Text("\(phase.title)  \(count)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(ChatTheme.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                        case .row(let room):
                            Button { model.select(room.id) } label: {
                                RoomRow(room: room, selected: model.selection == room.id)
                                    .equatable()
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu { contextMenu(for: room) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .background(ChatTheme.sidebar)
    }

    private var header: some View {
        HStack {
            Text("ルーム")
                .font(ChatTheme.headline)
                .foregroundStyle(ChatTheme.heading)
            Spacer()
            Button { showingLauncher.toggle() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(ChatTheme.onAccent)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(ChatTheme.accent))
            }
            .buttonStyle(.plain)
            .help("プロジェクトを選んで Claude Code を起動（新しいルーム）")
            .popover(isPresented: $showingLauncher, arrowEdge: .bottom) {
                ProjectLauncher { project in
                    showingLauncher = false
                    model.launch(project)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(ChatTheme.tertiary)
            TextField("", text: $model.query, prompt: Text("ルームを検索").foregroundStyle(ChatTheme.tertiary))
                .textFieldStyle(.plain)
                .font(ChatTheme.body)
                .foregroundStyle(ChatTheme.text)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9).fill(ChatTheme.inputSurface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.inputBorder))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.query.isEmpty ? "ルームがありません" : "一致するルームがありません")
                .font(ChatTheme.body)
                .foregroundStyle(ChatTheme.secondary)
            if model.query.isEmpty {
                Text("「+」からプロジェクトを選ぶと Claude Code が起動します。")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.tertiary)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func contextMenu(for room: Room) -> some View {
        if let session = room.hosted {
            Button(session.end == nil ? "ルームを閉じる（claude を終了）" : "ルームを閉じる") { model.close(session) }
        }
        Button("Finder で表示") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: room.cwd)])
        }
    }
}

/// ルーム 1 行。描いている値だけで比べ、状態が変われば必ず描き直す。
struct RoomRow: View, Equatable {
    let room: Room
    let selected: Bool

    static func == (lhs: RoomRow, rhs: RoomRow) -> Bool {
        lhs.selected == rhs.selected && lhs.room.id == rhs.room.id && lhs.room.name == rhs.room.name
            && lhs.room.branch == rhs.room.branch && lhs.room.status == rhs.room.status && lhs.room.line == rhs.room.line
            && lhs.room.activityAt == rhs.room.activityAt && lhs.room.unread == rhs.room.unread
            && lhs.room.isExternal == rhs.room.isExternal
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PixelAvatar(status: room.status, size: 36, hidesFromAccessibility: true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(room.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ChatTheme.text)
                        .lineLimit(1)
                    if room.isExternal { ExternalTag() }
                    Spacer(minLength: 4)
                    Text(ChatTime.short(room.activityDate))
                        .font(.system(size: 11))
                        .foregroundStyle(ChatTheme.tertiary)
                }
                if let branch = room.branch, !branch.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                        Text(branch).lineLimit(1).truncationMode(.middle)
                    }
                    .font(ChatTheme.mono.weight(.regular))
                    .foregroundStyle(ChatTheme.secondary)
                }
                HStack(spacing: 4) {
                    Text(ChatTheme.label(for: room.status))
                        .foregroundStyle(ChatTheme.color(for: room.status))
                        .fixedSize()
                    if !room.line.isEmpty {
                        Text("· \(Self.oneLine(room.line))")
                            .foregroundStyle(ChatTheme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if room.unread > 0 {
                        Text("\(min(room.unread, 99))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(ChatTheme.onAccent)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(ChatTheme.accent))
                    }
                }
                .font(ChatTheme.caption)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? ChatTheme.selectedRow : .clear))
    }

    static func oneLine(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        // 一覧では装飾記号がノイズになるので落とす。
        return first.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }
}

struct ExternalTag: View {
    var label = "外部"

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ChatTheme.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).stroke(ChatTheme.inputBorder))
            .help("アプリの外（VS Code・別ターミナル等）で動いているセッション")
    }
}

/// プロジェクトの頭文字アイコン（セッションを持たないプロジェクト一覧用）。
struct RoomAvatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        let color = ChatTheme.avatarColor(for: name)
        Text(RoomGrouping.initial(of: name))
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(color.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28).stroke(color.opacity(0.28)))
    }
}

/// 監視が動いていない・受け口が開けない間だけ、検索欄の下に出す。
struct ConnectionNotice: View {
    let connection: MonitorConnectionState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.circle")
            Text(text)
        }
        .font(ChatTheme.caption)
        .foregroundStyle(ChatTheme.permission)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }

    private var text: String {
        switch connection {
        case .starting: return "セッションの監視を始めています…"
        case .idle, .connected: return "セッションを監視していません"
        }
    }
}

/// フックの受け口（:8766）を開けていない時の注意。権限待ち・入力待ちはフックでしか分からない。
struct HookServerNotice: View {
    let text: String

    static func text(for state: HTTPServerState) -> String? {
        switch state {
        case .portInUse(let port):
            return "ポート \(port) を別のプロセスが使っているため、フック（権限待ち・入力待ち）が届きません。そのプロセスを止めると自動で引き継ぎます。"
        case .failed(let reason):
            return "フックの受け口を開けません（\(reason)）。権限待ち・入力待ちが届きません。"
        case .stopped, .starting, .listening:
            return nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(ChatTheme.caption)
        .foregroundStyle(ChatTheme.permission)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .accessibilityIdentifier("hook-server-notice")
    }
}

/// 「+」の中身: 登録済みプロジェクトから選んで起動する。一覧の追加・削除もここで行う（設定画面と同じデータ）。
struct ProjectLauncher: View {
    let onPick: (ManagedProject) -> Void
    private let store = SettingsStore.shared
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("新しいルーム")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ChatTheme.heading)
            TextField("", text: $filter, prompt: Text("プロジェクトを絞り込む").foregroundStyle(ChatTheme.tertiary))
                .textFieldStyle(.plain)
                .font(ChatTheme.body)
                .foregroundStyle(ChatTheme.text)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(ChatTheme.inputSurface))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ChatTheme.inputBorder))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { project in
                        HStack(spacing: 4) {
                            Button { onPick(project) } label: {
                                HStack(spacing: 8) {
                                    RoomAvatar(name: project.name, size: 26)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(project.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(ChatTheme.text)
                                        Text(project.path).font(.system(size: 11)).foregroundStyle(ChatTheme.tertiary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                }
                                .padding(6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(project.path)
                            Menu {
                                actions(for: project)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(ChatTheme.secondary)
                                    .frame(width: 24, height: 24)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Finder で表示・一覧から削除")
                        }
                        .contextMenu { actions(for: project) }
                    }
                    if filtered.isEmpty {
                        Text("プロジェクトがありません").font(ChatTheme.caption).foregroundStyle(ChatTheme.tertiary).padding(6)
                    }
                    if let problem = store.problem {
                        Text("設定を読めないため一覧を変えられません: \(problem)")
                            .font(ChatTheme.caption).foregroundStyle(ChatTheme.permission)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(6)
                    }
                    if let message = store.notice ?? store.saveError {
                        Text(message)
                            .font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(6)
                    }
                }
            }
            .frame(height: min(CGFloat(max(filtered.count, 1)) * 44, 320))
            Divider().overlay(ChatTheme.border)
            HStack {
                Button { addFolder() } label: {
                    Label("フォルダを追加…", systemImage: "folder.badge.plus")
                }
                .help("Claude Code を起動するプロジェクトフォルダを一覧に追加")
                .disabled(!store.isEditable)
                Spacer()
                Button { SettingsWindow.show(tab: .projects) } label: {
                    Label("設定を開く…", systemImage: "gearshape")
                }
                .help("プロジェクトの名前・状態・メモ・GitHub の紐づけを編集する")
            }
            .buttonStyle(.plain)
            .font(ChatTheme.caption)
            .foregroundStyle(ChatTheme.secondary)
        }
        .padding(12)
        .frame(width: 360)
        .background(ChatTheme.sidebar)
        .onAppear { store.reloadIfChanged() }
    }

    @ViewBuilder
    private func actions(for project: ManagedProject) -> some View {
        Button("Finder で表示") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
        }
        Divider()
        Button("一覧から削除", role: .destructive) {
            store.remove(id: project.id)
        }
        .disabled(!store.isEditable)
    }

    private var filtered: [ManagedProject] {
        let terms = filter.split(whereSeparator: \.isWhitespace)
        return store.projects.filter { p in
            terms.allSatisfy { "\(p.name) \(p.path)".range(of: $0, options: [.caseInsensitive, .widthInsensitive]) != nil }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "追加"
        guard panel.runModal() == .OK else { return }
        store.add(paths: panel.urls.map(\.path))
    }
}
