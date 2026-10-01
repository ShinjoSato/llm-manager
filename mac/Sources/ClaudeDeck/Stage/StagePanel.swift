import SwiftUI
import MonitorKit

/// 画面案B のステージパネルの配色（他は ChatTheme を使う）。
enum StageTheme {
    static let panelHex: UInt32 = 0x0b111d
    static let panel = Color(hex: panelHex)
    static let label = Font.system(size: 11, weight: .bold)
    static let width: CGFloat = 360
    /// monitor の埋め込み表示に塗ってもらう地色。nil は透過（drawsBackground=false なら html の color-scheme: dark でも地は付かない）。
    static let embedBackground: UInt32? = nil
}

/// 右側のステージパネル: ステージ（monitor の埋め込み表示）・いまの動き・随伴するサブエージェント・ライブフィード。
struct StagePanel: View {
    let model: ChatModel
    var launcher: MonitorLauncher = MonitorBridge.launcher
    var baseURL: URL = MonitorBridge.configuration.baseURL

    @AppStorage("stagePanel.mode") private var modeRaw = StageMode.solid.rawValue
    @AppStorage("stagePanel.open") private var preferOpen = true
    @State private var windowWidth: CGFloat?
    @State private var openedWhileNarrow = false

    private var store: MonitorStore { model.store }
    private var mode: StageMode { StageMode(rawValue: modeRaw) ?? .solid }
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
        .background(StageTheme.panel)
        .background(WindowWidthReader(width: $windowWidth))
        .onChange(of: isNarrow) { _, narrow in
            if !narrow { openedWhileNarrow = false }
        }
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
            stage(room: room, sessionId: sessionId, known: snapshot != nil)
                .frame(height: 230)
                .frame(maxWidth: .infinity)
                .background(StageTheme.panel)
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
            Picker("表示", selection: $modeRaw) {
                ForEach(StageMode.allCases, id: \.rawValue) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("ステージを 2D / 3D で表示")
            .accessibilityIdentifier("stage-mode")
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
    private func stage(room: Room?, sessionId: String?, known: Bool) -> some View {
        let content = StageLogic.content(connected: store.connection.isConnected,
                                         launchPhase: launcher.phase,
                                         hasRoom: room != nil,
                                         sessionId: sessionId,
                                         sessionKnown: known)
        switch content {
        case .stage(let id):
            StageWebView(url: StageLogic.embedURL(base: baseURL, sessionId: id, mode: mode,
                                                  background: StageTheme.embedBackground),
                         epoch: store.connectionEpoch)
        case .placeholder(let text):
            VStack(spacing: 8) {
                if launcher.phase.isBusy && !store.connection.isConnected {
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

// MARK: - 節

private struct SectionLabel: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(text)
                .font(StageTheme.label)
                .tracking(1.2)
                .foregroundStyle(ChatTheme.tertiary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(ChatTheme.tertiary)
            }
        }
    }
}

/// いまの動き: スキル > 説明 > ツールの動作 と経過時間。
private struct NowSection: View {
    let snapshot: SessionSnapshot?
    let hasRoom: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "いまの動き")
            if let s = snapshot {
                let action = StageLogic.actionLine(s)
                HStack(spacing: 8) {
                    Circle()
                        .fill(ChatTheme.color(for: s.status))
                        .frame(width: 7, height: 7)
                    Text(action ?? s.statusDetail ?? ChatTheme.label(for: s.status))
                        .font(ChatTheme.body)
                        .foregroundStyle(action != nil ? ChatTheme.working : ChatTheme.text)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("stage-now")
                Text("最終活動 \(StageLogic.ago(s.lastActivityDate, now: now)) · 稼働 \(StageLogic.duration(since: s.startedDate, now: now))")
                    .font(ChatTheme.caption.monospacedDigit())
                    .foregroundStyle(ChatTheme.secondary)
                if let title = s.title, !title.isEmpty {
                    Text(title)
                        .font(ChatTheme.caption)
                        .foregroundStyle(ChatTheme.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                Text(hasRoom ? "monitor の情報がまだありません" : "—")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 随伴するサブエージェント: 種別（職業名）と状態。
private struct AgentsSection: View {
    let agents: [AgentInfo]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "随伴するサブエージェント", trailing: agents.isEmpty ? nil : "\(agents.count)")
            if agents.isEmpty {
                Text("なし")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(agents) { agent in row(agent) }
                    }
                }
                .frame(maxHeight: 112)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ agent: AgentInfo) -> some View {
        let job = StageLogic.job(for: agent.type)
        let activity = StageLogic.activity(of: agent, now: now)
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: job.light))
                .frame(width: 8, height: 8)
            Text(job.label)
                .font(ChatTheme.caption.weight(.semibold))
                .foregroundStyle(ChatTheme.text)
            Text(agent.type ?? "種別不明")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ChatTheme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            switch activity {
            case .active:
                Text("作業中")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ChatTheme.working)
            case .quiet:
                Text(StageLogic.ago(Date(epochMillis: agent.lastActivityAt), now: now))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(ChatTheme.tertiary)
            }
        }
        .help(job.role)
    }
}

/// ライブフィード: そのセッションの直近（新しいものを上に）。
private struct FeedSection: View {
    let items: [FeedItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "ライブフィード")
                .padding(.horizontal, 14)
            if items.isEmpty {
                Text("まだ動きがありません")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.secondary)
                    .padding(.horizontal, 14)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(items) { item in
                            row(item)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .animation(.easeOut(duration: 0.2), value: items.first?.id)
                }
                .accessibilityIdentifier("stage-feed")
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) { Rectangle().fill(ChatTheme.border).frame(height: 1) }
    }

    private func row(_ item: FeedItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.clock.string(from: item.date))
                .foregroundStyle(ChatTheme.tertiary)
            Text(StageLogic.kindLabel(item.kind))
                .foregroundStyle(Self.color(item.kind))
                .frame(width: 44, alignment: .leading)
            Text(item.text)
                .foregroundStyle(ChatTheme.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// monitor UI の LiveFeed と同じ色分け。
    private static func color(_ kind: FeedKind) -> Color {
        switch kind {
        case .tool: return Color(hex: 0x7dd3fc)
        case .prompt: return Color(hex: 0xc4b5fd)
        case .message: return ChatTheme.secondary
        case .status: return Color(hex: 0xfcd34d)
        case .session: return Color(hex: 0x6ee7b7)
        case .agent: return Color(hex: 0xf0abfc)
        case .unknown: return ChatTheme.tertiary
        }
    }
}
