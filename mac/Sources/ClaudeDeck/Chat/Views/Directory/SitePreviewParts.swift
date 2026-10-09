import AppKit
import MonitorKit
import SwiftUI

/// サイトの欄とステージパネルのプレビューで共有する部品（幅の切り替え・枠・開発サーバーの操作と出力）。
enum SitePreviewDefaults {
    static let viewportKey = "sitePreview.viewport"
}

/// 書き出しの場所・更新時刻・配信の URL・開発サーバーを起動できるかをまとめて調べる。
struct SiteSnapshot: Equatable {
    var lookup: SiteLookup
    var exportModified: Date?
    var exportURL: URL?
    var serverProblem: String?
    var readiness: DevServerReadiness?

    var location: SiteLocation? { lookup.location }

    static func load(_ project: ManagedProject) async -> SiteSnapshot {
        let (found, modified, readiness) = await Task.detached(priority: .userInitiated) { () -> (SiteLookup, Date?, DevServerReadiness?) in
            let lookup = SiteLocator.lookup(project: project)
            let location = lookup.location
            return (lookup, location.flatMap { SiteLocator.exportModified($0) },
                    location.map { DevServerRules.readiness(siteRoot: $0.root) })
        }.value
        var snapshot = SiteSnapshot(lookup: found, exportModified: modified, readiness: readiness)
        guard let location = found.location, modified != nil else { return snapshot }
        do {
            snapshot.exportURL = try await SitePreviewServers.shared.baseURL(for: location.exportDir)
        } catch {
            if case SitePreviewServers.Failure.failed(let reason) = error {
                snapshot.serverProblem = "書き出しを配信できませんでした: \(reason)"
            } else {
                snapshot.serverProblem = "書き出しを配信できませんでした"
            }
        }
        return snapshot
    }
}

/// 調べ直す鍵（プロジェクトの場所・サイトの指定・「再読み込み」の回数）。
struct SiteTaskKey: Hashable {
    let path: String
    let site: String?
    let token: Int

    init(project: ManagedProject, token: Int) {
        path = project.path
        site = project.site?.path
        self.token = token
    }
}

/// プレビューの見出しの操作。映せる時は幅の切り替え・再読み込み・ブラウザで開く、配信を開けなかった時は再読み込みだけ。
struct SitePreviewControls: View {
    @Binding var viewportRaw: String
    let preview: SitePreviewState
    /// 今映しているページ（無ければ nil）。
    let targetURL: URL?
    /// 書き出しはあるが配信を開けなかった。
    let serverFailed: Bool
    let onReload: () -> Void

    var body: some View {
        if targetURL != nil {
            SiteViewportPicker(raw: $viewportRaw)
            HeaderButton(symbol: "arrow.clockwise", name: "再読み込み", detail: "書き出しの場所と更新時刻も確かめ直す", action: onReload)
            HeaderButton(symbol: "safari", name: "ブラウザで開く", detail: preview.browserURL(fallback: targetURL)?.absoluteString) {
                if let url = preview.browserURL(fallback: targetURL) { NSWorkspace.shared.open(url) }
            }
        } else if serverFailed {
            HeaderButton(symbol: "arrow.clockwise", name: "再読み込み", detail: "書き出しの配信を開き直す", action: onReload)
        }
    }
}

/// 表示幅の切り替え（PC / タブレット / スマホ）。
struct SiteViewportPicker: View {
    @Binding var raw: String

    var body: some View {
        let current = SiteViewport(rawValue: raw) ?? .desktop
        SegmentGroup {
            ForEach(SiteViewport.allCases) { option in
                SegmentButton(symbol: option.symbol, name: option.label, detail: "幅 \(Int(option.width))px で表示",
                              selected: option == current) { raw = option.rawValue }
            }
        }
    }
}

/// `SegmentButton` を並べる枠。
struct SegmentGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(2)
            .inputFieldSurface(9)
    }
}

/// 切り替えの 1 つ分のボタン（アイコンだけ・名前はホバーで出す）。
struct SegmentButton: View {
    let symbol: String
    let name: String
    var detail: String? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? ChatTheme.onAccent : ChatTheme.text)
                .frame(width: 30, height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? ChatTheme.accent : (hovering ? ChatTheme.selectedRow : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .headerButtonHelp(name: name, detail: detail, busyStatus: nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
    }
}

/// プレビューの高さの上限の決め方。
enum SitePreviewHeight: Equatable {
    /// 決まった高さまで（ステージパネルのように枠の高さが先に決まる時）。
    case fixed(Double)
    /// 欄の幅いっぱいに収まる高さまで。枠に使える高さが分かればそこまで。
    case fillWidth(room: Double?)
}

/// 表示幅で組ませたページを、与えられた幅と高さに縮めて収める枠。
struct SitePreviewFrame: View {
    let url: URL
    /// 開発サーバーの時はその origin（遷移をそこに限る）。
    var origin: URL? = nil
    let viewport: SiteViewport
    let reloadToken: Int
    let state: SitePreviewState
    let height: SitePreviewHeight
    @State private var availableWidth: Double = 0

    private var maxHeight: Double {
        switch height {
        case .fixed(let value): return value
        case .fillWidth(let room): return viewport.heightLimit(available: max(availableWidth, 1), room: room)
        }
    }

    var body: some View {
        let layout = viewport.layout(available: max(availableWidth, 1), maxHeight: maxHeight)
        let bezel = viewport.bezel
        let phoneRadius = 28 * layout.scale + 6
        ZStack {
            SiteWebView(url: url, origin: origin, zoom: layout.scale, reloadToken: reloadToken, state: state)
                .frame(width: layout.frameWidth, height: layout.frameHeight)
                .clipShape(RoundedRectangle(cornerRadius: viewport == .phone ? phoneRadius : 4))
                .padding(bezel)
                .background {
                    if viewport == .phone {
                        RoundedRectangle(cornerRadius: phoneRadius + bezel)
                            .fill(ChatTheme.codeSurface)
                            .overlay(RoundedRectangle(cornerRadius: phoneRadius + bezel).stroke(ChatTheme.inputBorder, lineWidth: 1.5))
                    }
                }
                .overlay {
                    if viewport != .phone {
                        RoundedRectangle(cornerRadius: 4).stroke(ChatTheme.border)
                    }
                }
            if state.loading {
                ProgressView().controlSize(.small)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(ChatTheme.claudeBubble))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(bezel + 6)
                    .allowsHitTesting(false)
            }
        }
        // minWidth を付けないと中身の幅に引きずられ、測った幅がそのまま次の幅になって欄が縮んでも戻らない。
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { availableWidth = $0 }
        .accessibilityLabel("サイトのプレビュー（\(viewport.label)）")
    }
}

/// 開発サーバーの状態・起動 / 停止・出力の末尾。
struct DevServerControls: View {
    let server: DevServer?
    let readiness: DevServerReadiness?
    let onStart: () -> Void
    let onStop: () -> Void
    var compact = false
    @State private var showsLog = false

    private var active: Bool { server?.isActive ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(statusText)
                    .font(ChatTheme.caption)
                    .foregroundStyle(server?.failure != nil || readiness?.problem != nil && !active ? ChatTheme.error : ChatTheme.secondary)
                    .lineLimit(compact ? 2 : 3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 6)
                if let lines = server?.lines, !lines.isEmpty {
                    HeaderButton(symbol: "text.alignleft", name: showsLog ? "出力を隠す" : "出力を見る",
                                 detail: "npm run dev の出力の末尾（\(DevServerRules.maxLogLines) 行まで）") {
                        showsLog.toggle()
                    }
                }
                if active {
                    HeaderButton(symbol: "stop.fill", name: "開発サーバーを停止", detail: "npm run dev をプロセスグループごと止める",
                                 busyStatus: server?.phase == .stopping ? "停止中…" : nil, action: onStop)
                } else if server?.isCleaningUp == true {
                    HeaderButton(symbol: "play.fill", name: "開発サーバーを起動", detail: "前のプロセスの残りを止めています",
                                 busyStatus: "片付け中…", action: onStart)
                } else if readiness?.problem == nil {
                    HeaderButton(symbol: "play.fill", name: "開発サーバーを起動",
                                 detail: readiness.flatMap(Self.scriptDetail) ?? "npm run dev", action: onStart)
                }
            }
            if showsLog, let lines = server?.lines, !lines.isEmpty {
                DevServerLogView(lines: lines, height: compact ? 120 : 180)
            }
        }
    }

    private static func scriptDetail(_ readiness: DevServerReadiness) -> String? {
        if case .ready(let script) = readiness { return "npm run dev（\(script)）" }
        return nil
    }

    private var statusText: String {
        if let server, server.isActive || server.failure != nil { return server.statusText }
        if let problem = readiness?.problem { return "開発サーバーを起動できません: \(problem)" }
        return server?.statusText ?? "開発サーバーは止まっています"
    }

    private var dotColor: Color {
        switch server?.phase {
        case .running: return ChatTheme.working
        case .starting, .stopping: return ChatTheme.waiting
        case .failed: return ChatTheme.error
        default: return ChatTheme.idle
        }
    }
}

/// 出力の末尾。新しい行が来たら一番下へ送る。
struct DevServerLogView: View {
    let lines: [String]
    let height: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(ChatTheme.mono)
                            .foregroundStyle(ChatTheme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .textSelection(.enabled)
                .padding(8)
            }
            .frame(height: height)
            .roundedSurface(8, fill: ChatTheme.codeSurface, stroke: ChatTheme.border)
            .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
            .onChange(of: lines) { _, new in proxy.scrollTo(new.count - 1, anchor: .bottom) }
        }
        .accessibilityLabel("開発サーバーの出力")
    }
}
