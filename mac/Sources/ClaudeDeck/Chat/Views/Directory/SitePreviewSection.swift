import AppKit
import MonitorKit
import SwiftUI

/// ディレクトリの詳細の「サイト」: LP を開発サーバー・書き出し（アプリ内の静的配信）・公開 URL で、幅を切り替えて見る。
struct SitePreviewSection: View {
    let project: ManagedProject
    /// 詳細のスクロール欄の見えている高さ（プレビューを大きくしすぎないため）。
    var visibleHeight: Double? = nil

    /// 見る元。開発サーバーか、書き出しか、設定のリンク（http / https）のどれか。
    private enum Source: Hashable {
        case devServer
        case export
        case link(String)
    }

    @State private var snapshot: SiteSnapshot?
    @State private var source: Source = .export
    @State private var choseInitialSource = false
    @State private var reloadToken = 0
    @State private var preview = SitePreviewState()
    @AppStorage(SitePreviewDefaults.viewportKey) private var viewportRaw = SiteViewport.desktop.rawValue

    private var viewport: SiteViewport { SiteViewport(rawValue: viewportRaw) ?? .desktop }
    private var links: [ProjectLink] { ProjectLinks.openable(project.links) }
    private var location: SiteLocation? { snapshot?.location }
    private var hasExport: Bool { snapshot?.exportModified != nil }
    private var devServer: DevServer? { location.flatMap { DevServerStore.shared.server(for: $0.root) } }

    /// 今の見る元で開く URL（開けない時は nil）。
    private var targetURL: URL? {
        switch source {
        case .devServer: return devServer?.url
        case .export: return hasExport ? snapshot?.exportURL : nil
        case .link(let url): return ProjectLinks.url(from: url)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            info
            content
        }
        .detailCard()
        .task(id: SiteTaskKey(project: project, token: reloadToken)) { await refresh() }
    }

    // MARK: - 見出しの行

    /// 1 行に入らなければ、見出しと見る元 / 幅の切り替えと操作の 2 段に折り返す。
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                toolbarTitle(compact: false)
                Spacer(minLength: 8)
                toolbarControls
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    toolbarTitle(compact: true)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    toolbarControls
                }
            }
        }
        .zIndex(1)
    }

    private func toolbarTitle(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Text("サイト")
                .sectionLabelStyle()
                .fixedSize()
            if location != nil || !links.isEmpty {
                sourcePicker(compact: compact)
            }
        }
    }

    private var toolbarControls: some View {
        HStack(spacing: 8) {
            SitePreviewControls(viewportRaw: $viewportRaw, preview: preview, targetURL: targetURL,
                                serverFailed: source == .export && hasExport && snapshot?.serverProblem != nil) {
                reloadToken += 1
            }
        }
        .fixedSize()
    }

    /// 2 段の時は見る元の名前を省略表示にして、欄の幅を超えないようにする。
    private func sourcePicker(compact: Bool) -> some View {
        Menu {
            if location != nil {
                Button { source = .devServer } label: { sourceLabel(.devServer) }
                Button { source = .export } label: { sourceLabel(.export) }
            }
            ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                Button { source = .link(link.url) } label: { sourceLabel(.link(link.url)) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(sourceTitle(source)).font(ChatTheme.caption).foregroundStyle(ChatTheme.text).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(ChatTheme.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .inputFieldSurface(7)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !compact, vertical: true)
        .accessibilityLabel("見る元: \(sourceTitle(source))")
    }

    private func sourceLabel(_ value: Source) -> some View {
        HStack {
            if value == source { Image(systemName: "checkmark") }
            Text(sourceTitle(value))
        }
    }

    private func sourceTitle(_ value: Source) -> String {
        switch value {
        case .devServer: return devServer?.url != nil ? "開発サーバー（動作中）" : "開発サーバー"
        case .export: return "書き出し（\(location.map { "\($0.relativePath == "." ? "" : $0.relativePath + "/")\(SiteLocator.exportDirName)/" } ?? "out/")）"
        case .link(let url):
            let name = links.first { $0.url == url }?.name ?? url
            return "公開: \(name)"
        }
    }

    // MARK: - 場所と更新時刻

    @ViewBuilder
    private var info: some View {
        switch source {
        case .devServer:
            if let location {
                pathRow(location.root, note: nil)
                DevServerControls(server: devServer, readiness: snapshot?.readiness,
                                  onStart: { DevServerStore.shared.start(project: project, location: location) },
                                  onStop: { DevServerStore.shared.stop(root: location.root) })
            }
        case .export:
            if let location {
                pathRow(location.exportDir,
                        note: snapshot?.exportModified.map { "更新 \($0.formatted(date: .numeric, time: .shortened))" })
                if location.source == .detected, (snapshot?.lookup.candidates.count ?? 0) > 1 {
                    Text("ほかにも候補あり（設定で指定できます）")
                        .font(ChatTheme.caption)
                        .foregroundStyle(ChatTheme.tertiary)
                        .lineLimit(1)
                }
            }
        case .link(let url):
            Text(url)
                .font(ChatTheme.mono)
                .foregroundStyle(ChatTheme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        if let problem = snapshot?.lookup.problem {
            Text("設定のサイトの場所が使えません: \(problem)")
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.error)
        }
        if let failure = (source == .export ? snapshot?.serverProblem : nil) ?? preview.failure {
            Text(failure)
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.error)
                .lineLimit(2)
        }
    }

    private func pathRow(_ path: String, note: String?) -> some View {
        HStack(spacing: 6) {
            Text(path)
                .font(ChatTheme.mono)
                .foregroundStyle(ChatTheme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let note {
                Text(note)
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.tertiary)
                    .fixedSize()
            }
        }
    }

    // MARK: - プレビュー

    @ViewBuilder
    private var content: some View {
        if snapshot == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
        } else if let url = targetURL {
            SitePreviewFrame(url: url, origin: source == .devServer ? url : nil, viewport: viewport, reloadToken: reloadToken,
                             state: preview, height: .fillWidth(visibleHeight: visibleHeight))
        } else if source == .devServer, location != nil {
            if devServer?.isActive == true {
                hint("開発サーバーがアドレス（http://localhost:…）を出すとここに映ります。")
            } else if snapshot?.readiness?.problem == nil {
                hint("▶ で `npm run dev` を起動すると、変更がここにすぐ映ります（起動は押した時だけ。ルームを閉じても動き続け、停止ボタン・アプリの終了・プロジェクトの削除で止まります）。")
            }
        } else if source == .export, hasExport {
            if snapshot?.serverProblem != nil {
                hint("書き出しはありますが、配信を開けませんでした。「再読み込み」で開き直せます。")
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
            }
        } else if source == .export, let location {
            hint("まだ書き出していません。\(location.relativePath == "." ? "プロジェクト直下" : location.relativePath) で `npm run build` で書き出すと見られます。見る元を「開発サーバー」にすると書き出さずに見られます。")
        } else {
            hint("LP が見つかりません。設定のプロジェクトタブの「サイト」で場所を指定するか、「リンク」に公開 URL を足すと見られます。")
        }
    }

    private func hint(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "globe").foregroundStyle(ChatTheme.tertiary)
            Text(.init(text))
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    // MARK: - 処理

    /// 場所・更新時刻を確かめ直し、書き出しがあれば配信を立てる。
    private func refresh() async {
        let loaded = await SiteSnapshot.load(project)
        guard !Task.isCancelled else { return }
        snapshot = loaded
        normalizeSource()
        // 書き出しが新しくなっていればサムネイルも撮り直させる（書き出しが消えた時は片付けさせる）。
        SiteThumbnailStore.shared.request(project, force: reloadToken > 0)
    }

    /// 選んでいた見る元が無くなったら、使えるものに替える。初めは動いている開発サーバー、無ければ書き出しを選ぶ。
    private func normalizeSource() {
        if !choseInitialSource {
            choseInitialSource = true
            if location != nil {
                source = devServer?.isActive == true || !hasExport && snapshot?.readiness?.problem == nil ? .devServer : .export
            }
        }
        switch source {
        case .devServer, .export:
            if location == nil, let first = links.first { source = .link(first.url) }
        case .link(let url):
            if !links.contains(where: { $0.url == url }) {
                source = location != nil ? .export : links.first.map { .link($0.url) } ?? .export
            }
        }
    }
}
