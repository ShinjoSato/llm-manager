import AppKit
import MonitorKit
import SwiftUI

/// 右パネルの見せ方（ステージ / プレビュー）。
enum StagePanelView: String, CaseIterable, Identifiable {
    case stage, preview

    static let defaultsKey = "stagePanel.view"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stage: return "ステージ"
        case .preview: return "プレビュー"
        }
    }

    var symbol: String {
        switch self {
        case .stage: return "sparkles.tv"
        case .preview: return "globe"
        }
    }

    var detail: String {
        switch self {
        case .stage: return "選択中のセッションの 3D ステージと動き"
        case .preview: return "選択中のルームのプロジェクトの LP（開発サーバー、無ければ書き出し）"
        }
    }
}

/// 右パネルのプレビュー: 選択中のルームのプロジェクトの LP を、会話の横で見る。
struct StagePreviewPanel: View {
    let model: ChatModel

    private var project: ManagedProject? {
        model.selectedRoom.flatMap { ProjectMatcher.project(for: $0.cwd, in: SettingsStore.shared.projects) }
    }

    var body: some View {
        if let project {
            // 別のプロジェクトへ移ったら表示中のページを持ち越さない。
            StageSitePreview(model: model, project: project).id(project.id)
        } else {
            placeholder(model.selectedRoom == nil
                        ? "ルームを選ぶと、そのプロジェクトの LP をここで見られます"
                        : "このルームのフォルダは設定のプロジェクトに入っていません")
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 22))
                .foregroundStyle(ChatTheme.tertiary)
                .accessibilityHidden(true)
            Text(text)
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 1 つのプロジェクトのプレビュー。開発サーバーが動いていればそれ、無ければ書き出し、どちらも無ければ案内。
private struct StageSitePreview: View {
    let model: ChatModel
    let project: ManagedProject

    @State private var snapshot: SiteSnapshot?
    @State private var reloadToken = 0
    @State private var preview = SitePreviewState()
    @AppStorage(SitePreviewDefaults.viewportKey) private var viewportRaw = SiteViewport.desktop.rawValue

    private var viewport: SiteViewport { SiteViewport(rawValue: viewportRaw) ?? .desktop }
    private var location: SiteLocation? { snapshot?.location }
    private var devServer: DevServer? { location.flatMap { DevServerStore.shared.server(for: $0.root) } }

    /// 開発サーバーが映せればそれ、無ければ書き出し。
    private var target: (url: URL, label: String, origin: URL?)? {
        if let url = devServer?.url { return (url, "開発サーバー", url) }
        if let url = snapshot?.exportURL { return (url, "書き出し", nil) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if let location {
                DevServerControls(server: devServer, readiness: snapshot?.readiness,
                                  onStart: { DevServerStore.shared.start(project: project, location: location) },
                                  onStop: { DevServerStore.shared.stop(root: location.root) },
                                  compact: true)
            }
            if let failure = preview.failure {
                Text(failure).font(ChatTheme.caption).foregroundStyle(ChatTheme.error).lineLimit(2)
            }
            content
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: TaskKey(path: project.path, site: project.site?.path, token: reloadToken)) {
            let loaded = await SiteSnapshot.load(project)
            if !Task.isCancelled { snapshot = loaded }
        }
    }

    private struct TaskKey: Hashable {
        let path: String
        let site: String?
        let token: Int
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ChatTheme.text)
                    .lineLimit(1)
                Text(target?.label ?? "LP")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if target != nil {
                SiteViewportPicker(raw: $viewportRaw)
                HeaderButton(symbol: "arrow.clockwise", name: "再読み込み", detail: "書き出しの場所と更新時刻も確かめ直す") {
                    reloadToken += 1
                }
                HeaderButton(symbol: "safari", name: "ブラウザで開く",
                             detail: (SiteNavigationPolicy.browserURL(preview.currentURL) ?? target?.url)?.absoluteString) {
                    if let url = SiteNavigationPolicy.browserURL(preview.currentURL) ?? target?.url { NSWorkspace.shared.open(url) }
                }
            } else if snapshot?.exportModified != nil, snapshot?.serverProblem != nil {
                HeaderButton(symbol: "arrow.clockwise", name: "再読み込み", detail: "書き出しの配信を開き直す") {
                    reloadToken += 1
                }
            }
        }
        .zIndex(1)
    }

    @ViewBuilder
    private var content: some View {
        if snapshot == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
        } else if let target {
            GeometryReader { proxy in
                SitePreviewFrame(url: target.url, origin: target.origin, viewport: viewport, reloadToken: reloadToken, state: preview,
                                 height: .fixed(max(proxy.size.height, 120)))
            }
        } else {
            guidance
        }
    }

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(guidanceText)
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let location, devServer?.canStart ?? true, snapshot?.readiness?.problem == nil {
                    Button { DevServerStore.shared.start(project: project, location: location) } label: {
                        Label("開発サーバーを起動", systemImage: "play.fill")
                            .font(ChatTheme.caption)
                            .foregroundStyle(ChatTheme.onAccent)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(ChatTheme.accent))
                    }
                    .buttonStyle(.plain)
                    .headerButtonHelp(name: "開発サーバーを起動", detail: "\(location.root) で npm run dev", busyStatus: nil)
                }
                Button { model.selectDirectory(project.id) } label: {
                    Text("サイトの欄を開く")
                        .font(ChatTheme.caption)
                        .foregroundStyle(ChatTheme.text)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .inputFieldSurface(7)
                }
                .buttonStyle(.plain)
                .headerButtonHelp(name: "サイトの欄を開く", detail: "\(project.name) の詳細の「サイト」", busyStatus: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private var guidanceText: String {
        if let problem = snapshot?.lookup.problem { return "設定のサイトの場所が使えません: \(problem)" }
        guard location != nil else { return "このプロジェクトに LP が見つかりません。設定のプロジェクトタブの「サイト」で場所を指定できます。" }
        if devServer?.isActive == true { return "開発サーバーがアドレス（http://localhost:…）を出すとここに映ります。" }
        if snapshot?.exportModified != nil {
            let reason = snapshot?.serverProblem.map { "（\($0)）" } ?? ""
            return "書き出しはありますが、配信を開けませんでした\(reason)。「再読み込み」で開き直せます。"
        }
        if let problem = snapshot?.readiness?.problem { return "開発サーバーを起動できず、書き出し（out/）もありません。\(problem)" }
        return "開発サーバーが動いておらず、書き出し（out/）もありません。開発サーバーを起動すると、変更がここにすぐ映ります。"
    }
}
