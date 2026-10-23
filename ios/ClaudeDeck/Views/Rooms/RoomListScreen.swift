import DeckCore
import SwiftUI

/// 左の一覧（ルーム / ディレクトリ / リンク）。横幅が regular なら左に一覧・右に会話か詳細の 2 列、compact なら行を押すと先へ進む。
struct RoomListScreen: View {
    @Bindable var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// 開いている画面の道のり。2 列と積み上げで共有し、幅が変わっても同じ画面を開いたままにする。
    @State private var route: [DeckRoute] = []
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var showingSettings = false
    @AppStorage("sidebar.mode") private var storedMode = SidebarMode.rooms.rawValue

    var body: some View {
        Group {
            if sizeClass == .regular { split } else { stack }
        }
        .sheet(isPresented: $showingSettings) { SettingsScreen(model: model) }
        .onAppear {
            if let mode = model.launchMode ?? SidebarMode(rawValue: storedMode) { model.sidebarMode = mode }
            model.launchMode = nil
            if let launch = model.launchRoute {
                route = launch
                model.launchRoute = nil
            }
            openRequestedRoom()
        }
        .onChange(of: model.sidebarMode) { _, mode in storedMode = mode.rawValue }
        .onChange(of: route, initial: true) { _, newRoute in model.showsProjectDetail = RoomSelection.showsProject(newRoute) }
        .onChange(of: model.requestedRoomId) { _, _ in openRequestedRoom() }
        .onChange(of: model.rooms.map(\.id)) { _, _ in dropVanished(sizeClass: sizeClass) }
        .onChange(of: model.projects?.projects.map(\.id)) { _, _ in dropVanished(sizeClass: sizeClass) }
        .onChange(of: sizeClass) { _, newClass in dropVanished(sizeClass: newClass) }
    }

    private var stack: some View {
        NavigationStack(path: $route) {
            sidebar
                .navigationDestination(for: DeckRoute.self) { step in
                    destination(step, listHidden: false, compact: true)
                }
        }
    }

    private var split: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            // 一覧を畳んでいる間は左の帯や案内が見えないので、右の側に出す。
            let listHidden = columns == .detailOnly
            if let first = route.first {
                // 詳細から開いた会話は右の列の中で積み、戻ると詳細に戻る。
                let tail = Binding(get: { Array(route.dropFirst()) }, set: { route = [first] + $0 })
                NavigationStack(path: tail) {
                    destination(first, listHidden: listHidden, compact: false)
                        .navigationDestination(for: DeckRoute.self) { step in
                            destination(step, listHidden: listHidden, compact: false)
                        }
                }
                .id(first)
            } else {
                NoRoomSelected(model: model, mode: model.sidebarMode, showsListNotices: listHidden)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func destination(_ step: DeckRoute, listHidden: Bool, compact: Bool) -> some View {
        switch step {
        case .room(let roomId):
            if compact {
                ConversationScreen(model: model, roomId: roomId)
            } else {
                ConversationScreen(model: model, roomId: roomId, showsBanner: listHidden, showsListNotices: listHidden)
            }
        case .project(let projectId):
            ProjectDetailScreen(model: model, projectId: projectId, showsBanner: compact || listHidden)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ConnectionBanner(model: model)
            ListNotices(model: model)
            SidebarModePicker(mode: $model.sidebarMode)
            switch model.sidebarMode {
            case .rooms: list
            case .directory: DirectoryList(model: model, route: $route, regular: sizeClass == .regular)
            case .links: LinkOverviewList(model: model, route: $route, regular: sizeClass == .regular)
            }
        }
        .background(DeckTheme.sidebar.ignoresSafeArea())
        .navigationTitle(model.sidebarMode.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(DeckTheme.sidebar, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("接続の設定")
            }
        }
        .refreshable {
            if model.sidebarMode.usesProjects { await model.pullToRefreshProjects() } else { model.connect() }
        }
    }

    /// 通知から開くルーム。開いている画面の上に積まず、ルームの一覧から入り直す。
    private func openRequestedRoom() {
        guard let id = model.requestedRoomId else { return }
        model.requestedRoomId = nil
        model.sidebarMode = .rooms
        route = RoomSelection.open(.room(id))
    }

    /// 積み上げの画面は消えたルームでも「もう一覧にありません」を出したままにするので、外すのは 2 列の時だけ。
    private func dropVanished(sizeClass: UserInterfaceSizeClass?) {
        guard sizeClass == .regular else { return }
        route = RoomSelection.kept(route, roomIds: model.rooms.map(\.id), projectIds: model.projects?.projects.map(\.id))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "laptopcomputer")
                    Text(model.serverName).lineLimit(1)
                    if model.connection.isConnected {
                        Circle().fill(DeckTheme.working).frame(width: 6, height: 6).accessibilityLabel("接続中")
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DeckTheme.secondary)
                .padding(.horizontal, 12)
                let groups = Self.groups(model.rooms)
                if groups.isEmpty { emptyState }
                ForEach(groups, id: \.phase) { group in
                    Text("\(group.phase.title)  \(group.rooms.count)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DeckTheme.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                    ForEach(group.rooms) { room in
                        row(room)
                            .accessibilityIdentifier("room-\(room.name)")
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private func row(_ room: RemoteRoom) -> some View {
        let label = RoomRow(room: room, unread: room.sessionId.flatMap { model.unread[$0] } ?? 0).contentShape(Rectangle())
        SidebarRowLink(step: .room(room.id), route: $route, regular: sizeClass == .regular) { label }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.state == nil {
                Text(model.connection.isConnected ? "一覧を読み込んでいます…" : "Mac につながると一覧が出ます")
                    .font(DeckTheme.body)
                    .foregroundStyle(DeckTheme.secondary)
            } else {
                Text("ルームがありません").font(DeckTheme.body).foregroundStyle(DeckTheme.secondary)
                Text("Mac の claude-deck で「+」からプロジェクトを選ぶと Claude Code が起動します。")
                    .font(DeckTheme.caption)
                    .foregroundStyle(DeckTheme.tertiary)
            }
        }
        .padding(16)
    }

    /// mac が並べた順（要対応 → 稼働中 → 待機・新しく動いた順）のままグループに分ける。
    static func groups(_ rooms: [RemoteRoom]) -> [(phase: RoomPhase, rooms: [RemoteRoom])] {
        RoomPhase.allCases.compactMap { phase in
            let members = rooms.filter { RoomPhase($0.phase) == phase }
            return members.isEmpty ? nil : (phase, members)
        }
    }
}

struct RowButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 10).fill(configuration.isPressed || selected ? DeckTheme.selectedRow : .clear))
    }
}

/// 一覧の 1 行。2 列では押すと右に開いて選んだ印を付け、積み上げでは先へ進む。
struct SidebarRowLink<Label: View>: View {
    let step: DeckRoute
    @Binding var route: [DeckRoute]
    let regular: Bool
    @ViewBuilder var label: () -> Label

    var body: some View {
        if regular {
            let selected = RoomSelection.isSelected(step, in: route)
            Button { route = RoomSelection.open(step) } label: { label() }
                .buttonStyle(RowButtonStyle(selected: selected))
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            NavigationLink(value: step) { label() }
                .buttonStyle(RowButtonStyle())
        }
    }
}

/// 左の一覧の見方の切り替え（一覧の最上段）。
private struct SidebarModePicker: View {
    @Binding var mode: SidebarMode

    var body: some View {
        Picker("一覧", selection: $mode) {
            ForEach(SidebarMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .accessibilityIdentifier("sidebar-mode")
    }
}

/// 2 列で何も選んでいない時の右側。
private struct NoRoomSelected: View {
    @Bindable var model: AppModel
    let mode: SidebarMode
    let showsListNotices: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsListNotices {
                ConnectionBanner(model: model)
                ListNotices(model: model)
            }
            VStack(spacing: 10) {
                Image(systemName: mode.symbol).font(.system(size: 28)).foregroundStyle(DeckTheme.tertiary)
                Text(Self.hint(mode))
                    .font(DeckTheme.body)
                    .foregroundStyle(DeckTheme.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DeckTheme.background.ignoresSafeArea())
        .toolbarBackground(DeckTheme.background, for: .navigationBar)
    }

    static func hint(_ mode: SidebarMode) -> String {
        switch mode {
        case .rooms: return "左の一覧からルームを選ぶと、ここに会話が出ます。"
        case .directory: return "左の一覧からプロジェクトを選ぶと、ここにリンクとスレッドが出ます。"
        case .links: return "左の一覧のリンクを押すと Safari で開きます。プロジェクト名の横の「詳細」で、ここにリンクとスレッドが出ます。"
        }
    }
}

/// 一覧の上に出す案内（監視が止まっている・通知のルームを開けなかった）。
struct ListNotices: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.state?.monitoring == false {
            InlineNotice(symbol: "bolt.horizontal.circle", text: "Mac のセッション監視が止まっています。一覧が古い可能性があります。")
        }
        if let hint = model.noticeHint {
            Button { model.noticeHint = nil } label: {
                InlineNotice(symbol: "bell.badge", text: hint)
            }
            .buttonStyle(.plain)
            .accessibilityHint("押すと閉じます")
        }
    }
}

/// ルーム 1 行（mac の一覧の行と同じ並び）。
struct RoomRow: View {
    let room: RemoteRoom
    let unread: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PixelAvatar(status: room.status, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(room.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DeckTheme.text)
                        .lineLimit(1)
                    if room.kind == .external { ExternalTag() }
                    Spacer(minLength: 4)
                    Text(DeckTime.short(room.activityAt.map(Date.init(epochMillis:))))
                        .font(.system(size: 11.5))
                        .foregroundStyle(DeckTheme.tertiary)
                }
                if let branch = room.branch, !branch.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                        Text(branch).lineLimit(1).truncationMode(.middle)
                    }
                    .font(DeckTheme.mono)
                    .foregroundStyle(DeckTheme.secondary)
                }
                HStack(spacing: 4) {
                    Text(DeckTheme.label(for: room.status))
                        .foregroundStyle(DeckTheme.color(for: room.status))
                        .fixedSize()
                    if !room.line.isEmpty {
                        Text("· \(Self.oneLine(room.line))")
                            .foregroundStyle(DeckTheme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if room.needsAnswer {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DeckTheme.permission)
                            .accessibilityLabel("回答が要ります")
                    }
                    if unread > 0 {
                        Text("\(min(unread, 99))")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(DeckTheme.onAccent)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 19, minHeight: 19)
                            .background(Capsule().fill(DeckTheme.accent))
                            .accessibilityLabel("未読 \(unread) 件")
                    }
                }
                .font(DeckTheme.caption)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }

    static func oneLine(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        // 一覧では装飾記号がノイズになるので落とす。
        return first.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }
}

struct InlineNotice: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(DeckTheme.caption)
        .foregroundStyle(DeckTheme.permission)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }
}
