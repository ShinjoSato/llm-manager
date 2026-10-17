import DeckCore
import SwiftUI

/// ルーム一覧（要対応 / 稼働中 / 待機）。横幅が regular なら左に一覧・右に会話の 2 列、compact なら行を押すと会話へ進む。
struct RoomListScreen: View {
    @Bindable var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// 開いている会話。2 列と積み上げで共有し、幅が変わっても同じ会話を開いたままにする。
    @State private var selection: String?
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var showingSettings = false

    var body: some View {
        Group {
            if sizeClass == .regular { split } else { stack }
        }
        .sheet(isPresented: $showingSettings) { SettingsScreen(model: model) }
        .onAppear {
            if let id = model.launchRoomId {
                selection = id
                model.launchRoomId = nil
            }
            openRequestedRoom()
        }
        .onChange(of: model.requestedRoomId) { _, _ in openRequestedRoom() }
        .onChange(of: model.rooms.map(\.id)) { _, ids in dropVanishedSelection(ids: ids, sizeClass: sizeClass) }
        .onChange(of: sizeClass) { _, newClass in dropVanishedSelection(ids: model.rooms.map(\.id), sizeClass: newClass) }
    }

    private var stack: some View {
        let path = Binding(get: { RoomSelection.path(for: selection) }, set: { selection = RoomSelection.selection(from: $0) })
        return NavigationStack(path: path) {
            sidebar
                .navigationDestination(for: String.self) { roomId in
                    ConversationScreen(model: model, roomId: roomId)
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
            if let roomId = selection {
                ConversationScreen(model: model, roomId: roomId, showsBanner: listHidden, showsListNotices: listHidden)
                    .id(roomId)
            } else {
                NoRoomSelected(model: model, showsListNotices: listHidden)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ConnectionBanner(model: model)
            ListNotices(model: model)
            list
        }
        .background(DeckTheme.sidebar.ignoresSafeArea())
        .navigationTitle("ルーム")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(DeckTheme.sidebar, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("接続の設定")
            }
        }
        .refreshable { model.connect() }
    }

    /// 通知から開くルーム。開いている会話の上に積まず、一覧から入り直す。
    private func openRequestedRoom() {
        guard let id = model.requestedRoomId else { return }
        model.requestedRoomId = nil
        selection = id
    }

    /// 積み上げの画面は消えたルームでも「もう一覧にありません」を出したままにするので、外すのは 2 列の時だけ。
    private func dropVanishedSelection(ids: [String], sizeClass: UserInterfaceSizeClass?) {
        guard sizeClass == .regular else { return }
        selection = RoomSelection.kept(selection, among: ids)
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
        if sizeClass == .regular {
            let selected = selection == room.id
            Button { selection = room.id } label: { label }
                .buttonStyle(RowButtonStyle(selected: selected))
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            NavigationLink(value: room.id) { label }
                .buttonStyle(RowButtonStyle())
        }
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

private struct RowButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 10).fill(configuration.isPressed || selected ? DeckTheme.selectedRow : .clear))
    }
}

/// 2 列で何も選んでいない時の右側。
private struct NoRoomSelected: View {
    @Bindable var model: AppModel
    let showsListNotices: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsListNotices {
                ConnectionBanner(model: model)
                ListNotices(model: model)
            }
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 28)).foregroundStyle(DeckTheme.tertiary)
                Text("左の一覧からルームを選ぶと、ここに会話が出ます。")
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
