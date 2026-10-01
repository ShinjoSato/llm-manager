import SwiftUI
import MonitorKit

/// 左カラム: ルーム一覧（検索・新規・グループ・残量）。
struct RoomListView: View {
    @Bindable var model: ChatModel
    @State private var showingLauncher = false

    var body: some View {
        VStack(spacing: 0) {
            header
            search
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let groups = model.groupedRooms
                    if groups.isEmpty { emptyState }
                    ForEach(groups) { group in
                        Text("\(group.phase.title)  \(group.rooms.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ChatTheme.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(group.rooms) { room in
                            Button { model.select(room.id) } label: {
                                RoomRow(room: room, selected: model.selection == room.id)
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
            UsageFooter(store: model.store)
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

/// ルーム 1 行。
struct RoomRow: View {
    let room: Room
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoomAvatar(name: room.name, status: room.status, size: 36)
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
    var body: some View {
        Text("外部")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ChatTheme.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).stroke(ChatTheme.inputBorder))
            .help("アプリの外（VS Code・別ターミナル等）で動いているセッション")
    }
}

/// プロジェクトの頭文字アイコン + 状態ドット。
struct RoomAvatar: View {
    let name: String
    let status: SessionStatus?
    let size: CGFloat

    var body: some View {
        let color = ChatTheme.avatarColor(for: name)
        Text(RoomGrouping.initial(of: name))
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(color.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28).stroke(color.opacity(0.28)))
            .overlay(alignment: .bottomTrailing) {
                if let status {
                    Circle()
                        .fill(ChatTheme.color(for: status))
                        .frame(width: size * 0.3, height: size * 0.3)
                        .overlay(Circle().stroke(ChatTheme.sidebar, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            }
    }
}

/// 下部: monitor の接続状態と 5 時間 / 7 日間の残り%。
struct UsageFooter: View {
    let store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.connection.isConnected {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal.circle")
                    Text(connectionText)
                }
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.permission)
            }
            if let usage = store.usage {
                UsageBar(title: "5時間", window: usage.fiveHour)
                UsageBar(title: "7日間", window: usage.sevenDay)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("取得 \(ChatTime.elapsed(since: usage.fetchedDate, now: context.date))")
                        .font(.system(size: 11))
                        .foregroundStyle(ChatTheme.tertiary)
                }
            } else if store.connection.isConnected {
                Text("残量は未取得（statusLine 未設定）")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(ChatTheme.border).frame(height: 1) }
    }

    private var connectionText: String {
        switch store.connection {
        case .connecting: return "monitor に接続中…"
        case .disconnected: return "monitor 未接続（再接続を試みています）"
        case .idle, .connected: return "monitor 未接続"
        }
    }
}

struct UsageBar: View {
    let title: String
    let window: UsageWindow?

    var body: some View {
        let remaining = window?.remainingPercentage
        let color = remaining.map { $0 < 20 ? ChatTheme.error : $0 < 50 ? ChatTheme.permission : ChatTheme.working } ?? ChatTheme.idle
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(ChatTheme.secondary)
                Spacer()
                Text(remaining.map { "残り \(Int($0.rounded()))%" } ?? "—")
                    .foregroundStyle(remaining == nil ? ChatTheme.tertiary : ChatTheme.text)
                    .monospacedDigit()
            }
            .font(ChatTheme.caption)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ChatTheme.inputSurface)
                    Capsule().fill(color).frame(width: geo.size.width * CGFloat((remaining ?? 0) / 100))
                }
            }
            .frame(height: 5)
        }
    }
}

/// 「+」の中身: 登録済みプロジェクトから選んで起動する。
struct ProjectLauncher: View {
    let onPick: (ManagedProject) -> Void
    @State private var projects = ProjectStore.load()
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
                    ForEach(filtered, id: \.path) { project in
                        Button { onPick(project) } label: {
                            HStack(spacing: 8) {
                                RoomAvatar(name: project.name, status: nil, size: 26)
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
                    }
                    if filtered.isEmpty {
                        Text("プロジェクトがありません").font(ChatTheme.caption).foregroundStyle(ChatTheme.tertiary).padding(6)
                    }
                }
            }
            .frame(height: min(CGFloat(max(filtered.count, 1)) * 44, 320))
            Divider().overlay(ChatTheme.border)
            Button { addFolder() } label: {
                Label("フォルダを追加…", systemImage: "folder.badge.plus")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 320)
        .background(ChatTheme.sidebar)
    }

    private var filtered: [ManagedProject] {
        let terms = filter.split(whereSeparator: \.isWhitespace)
        return projects.filter { p in
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
        for url in panel.urls { projects = ProjectStore.add(path: url.path) }
    }
}
