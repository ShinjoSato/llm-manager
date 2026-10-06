import SwiftUI
import MonitorKit

/// ステージパネルの寸法と見出し。
enum StageTheme {
    static let label = Font.system(size: 11, weight: .bold)
    static let width: CGFloat = 360
}

/// 右側のステージパネル: ステージ（3D）・いまの動き・随伴するサブエージェント・ライブフィード。
struct StagePanel: View {
    let model: ChatModel

    @AppStorage("stagePanel.open") private var preferOpen = true
    @State private var windowWidth: CGFloat?
    @State private var openedWhileNarrow = false

    private var store: MonitorStore { model.store }
    private var expanded: Bool {
        StageLogic.isExpanded(preference: preferOpen, windowWidth: windowWidth, openedWhileNarrow: openedWhileNarrow)
    }
    private var isNarrow: Bool { (windowWidth ?? .infinity) < StageLogic.autoCollapseWidth }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(ChatTheme.border).frame(width: 1)
            if expanded {
                panel
                    .frame(minWidth: 240, idealWidth: StageTheme.width, maxWidth: StageTheme.width)
            } else {
                collapsed
            }
        }
        .frame(maxHeight: .infinity)
        .background(ChatTheme.stagePanel)
        .background(WindowWidthReader(width: $windowWidth))
        .onChange(of: isNarrow) { _, narrow in
            if !narrow { openedWhileNarrow = false }
        }
        // 表示は 3D 固定なので、古い 2D/3D 選択の保存値を残さない。
        .onAppear { UserDefaults.standard.removeObject(forKey: "stagePanel.mode") }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stage-panel")
    }

    private func toggle() {
        if expanded {
            preferOpen = false
            openedWhileNarrow = false
        } else {
            preferOpen = true
            openedWhileNarrow = isNarrow
        }
    }

    // MARK: - 畳んだ状態

    private var collapsed: some View {
        VStack(spacing: 10) {
            Button(action: toggle) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13))
                    .foregroundStyle(ChatTheme.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("ステージパネルを開く")
            .accessibilityLabel("ステージパネルを開く")
            Text("ステージ")
                .font(StageTheme.label)
                .tracking(1.2)
                .foregroundStyle(ChatTheme.tertiary)
                .fixedSize()
                .rotationEffect(.degrees(90))
                .frame(width: 20, height: 64)
            Spacer()
        }
        .padding(.top, 12)
        .frame(width: 36)
    }

    // MARK: - 開いた状態

    private var panel: some View {
        let room = model.selectedRoom
        let sessionId = room?.sessionId
        let snapshot = sessionId.flatMap { store.session(id: $0) }
        return VStack(alignment: .leading, spacing: 0) {
            header
            stage(room: room, sessionId: sessionId, snapshot: snapshot)
                .frame(height: 230)
                .frame(maxWidth: .infinity)
                .background(ChatTheme.stagePanel)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ChatTheme.border, lineWidth: 1))
                .padding(.horizontal, 14)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 0) {
                    NowSection(snapshot: snapshot, hasRoom: room != nil, now: context.date)
                    AgentsSection(agents: snapshot.map { StageLogic.sortedAgents($0.agents) } ?? [], now: context.date)
                }
            }
            FeedSection(items: StageLogic.feed(store.feed, sessionId: sessionId))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("ステージ")
                .font(StageTheme.label)
                .tracking(1.2)
                .foregroundStyle(ChatTheme.tertiary)
            Spacer(minLength: 8)
            Button(action: toggle) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13))
                    .foregroundStyle(ChatTheme.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("ステージパネルを畳む")
            .accessibilityLabel("ステージパネルを畳む")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    @ViewBuilder
    private func stage(room: Room?, sessionId: String?, snapshot: SessionSnapshot?) -> some View {
        let content = StageLogic.content(connected: store.connection.isConnected,
                                         hasRoom: room != nil,
                                         sessionId: sessionId,
                                         sessionKnown: snapshot != nil)
        switch (content, snapshot) {
        case (.stage, let snapshot?):
            StageSceneView(model: StageSceneModel(session: snapshot))
        case (.stage, nil):
            EmptyView()
        case (.placeholder(let text), _):
            VStack(spacing: 8) {
                if !store.connection.isConnected {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles.tv")
                        .font(.system(size: 22))
                        .foregroundStyle(ChatTheme.tertiary)
                        .accessibilityHidden(true)
                }
                Text(text)
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("stage-placeholder")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
