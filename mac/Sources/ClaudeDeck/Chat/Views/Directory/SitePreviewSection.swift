import AppKit
import MonitorKit
import SwiftUI

/// ディレクトリの詳細の「サイト」: LP を書き出し（アプリ内の静的配信）か公開 URL で、幅を切り替えて見る。
struct SitePreviewSection: View {
    let project: ManagedProject

    /// 見る元。書き出しか、設定のリンク（http / https）のどれか。
    private enum Source: Hashable {
        case export
        case link(String)
    }

    @State private var lookup: SiteLookup?
    @State private var exportModified: Date?
    @State private var exportURL: URL?
    @State private var serverProblem: String?
    @State private var source: Source = .export
    @State private var reloadToken = 0
    @State private var availableWidth: Double = 0
    @State private var preview = SitePreviewState()
    @AppStorage("sitePreview.viewport") private var viewportRaw = SiteViewport.desktop.rawValue

    private static let maxPreviewHeight = 620.0

    private var viewport: SiteViewport { SiteViewport(rawValue: viewportRaw) ?? .desktop }
    private var links: [ProjectLink] { ProjectLinks.openable(project.links) }
    private var location: SiteLocation? { lookup?.location }
    private var hasExport: Bool { exportModified != nil }

    /// 今の見る元で開く URL（開けない時は nil）。
    private var targetURL: URL? {
        switch source {
        case .export: return hasExport ? exportURL : nil
        case .link(let url): return ProjectLinks.url(from: url)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            info
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(ChatTheme.claudeBubble))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ChatTheme.claudeBubbleBorder))
        .task(id: TaskKey(path: project.path, site: project.site?.path, token: reloadToken)) { await refresh() }
    }

    private struct TaskKey: Hashable {
        let path: String
        let site: String?
        let token: Int
    }

    // MARK: - 見出しの行

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("サイト")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ChatTheme.tertiary)
            if location != nil || !links.isEmpty {
                sourcePicker
            }
            Spacer(minLength: 8)
            if targetURL != nil {
                viewportPicker
                HeaderButton(symbol: "arrow.clockwise", name: "再読み込み", detail: "書き出しの場所と更新時刻も確かめ直す") {
                    reloadToken += 1
                }
                HeaderButton(symbol: "safari", name: "ブラウザで開く",
                             detail: (SiteNavigationPolicy.browserURL(preview.currentURL) ?? targetURL)?.absoluteString) {
                    openInBrowser()
                }
            }
        }
        .zIndex(1)
    }

    private var sourcePicker: some View {
        Menu {
            if location != nil {
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
            .background(RoundedRectangle(cornerRadius: 7).fill(ChatTheme.inputSurface))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(ChatTheme.inputBorder))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
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
        case .export: return "書き出し（\(location.map { "\($0.relativePath == "." ? "" : $0.relativePath + "/")\(SiteLocator.exportDirName)/" } ?? "out/")）"
        case .link(let url):
            let name = links.first { $0.url == url }?.name ?? url
            return "公開: \(name)"
        }
    }

    private var viewportPicker: some View {
        HStack(spacing: 2) {
            ForEach(SiteViewport.allCases) { option in
                ViewportButton(option: option, selected: option == viewport) { viewportRaw = option.rawValue }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(ChatTheme.inputSurface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.inputBorder))
    }

    // MARK: - 場所と更新時刻

    @ViewBuilder
    private var info: some View {
        switch source {
        case .export:
            if let location {
                HStack(spacing: 6) {
                    Text(location.exportDir)
                        .font(ChatTheme.mono)
                        .foregroundStyle(ChatTheme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let exportModified {
                        Text("更新 \(exportModified.formatted(date: .numeric, time: .shortened))")
                            .font(ChatTheme.caption)
                            .foregroundStyle(ChatTheme.tertiary)
                            .fixedSize()
                    }
                    if location.source == .detected, (lookup?.candidates.count ?? 0) > 1 {
                        Text("ほかにも候補あり（設定で指定できます）")
                            .font(ChatTheme.caption)
                            .foregroundStyle(ChatTheme.tertiary)
                            .lineLimit(1)
                    }
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
        if let problem = lookup?.problem {
            Text("設定のサイトの場所が使えません: \(problem)")
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.error)
        }
        if let failure = serverProblem ?? preview.failure {
            Text(failure)
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.error)
                .lineLimit(2)
        }
    }

    // MARK: - プレビュー

    @ViewBuilder
    private var content: some View {
        if lookup == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
        } else if let url = targetURL {
            previewFrame(url)
        } else if source == .export, let location {
            hint("まだ書き出していません。\(location.relativePath == "." ? "プロジェクト直下" : location.relativePath) で `npm run build` で書き出すと見られます。")
        } else {
            hint("LP が見つかりません。設定のプロジェクトタブの「サイト」で場所を指定するか、「リンク」に公開 URL を足すと見られます。")
        }
    }

    private func previewFrame(_ url: URL) -> some View {
        let layout = viewport.layout(available: max(availableWidth, 1), maxHeight: Self.maxPreviewHeight)
        let bezel = viewport.bezel
        return ZStack {
            SiteWebView(url: url, zoom: layout.scale, reloadToken: reloadToken, state: preview)
                .frame(width: layout.frameWidth, height: layout.frameHeight)
                .clipShape(RoundedRectangle(cornerRadius: viewport == .phone ? 28 * layout.scale + 6 : 4))
                .padding(bezel)
                .background {
                    if viewport == .phone {
                        RoundedRectangle(cornerRadius: 28 * layout.scale + 6 + bezel)
                            .fill(ChatTheme.codeSurface)
                            .overlay(RoundedRectangle(cornerRadius: 28 * layout.scale + 6 + bezel).stroke(ChatTheme.inputBorder, lineWidth: 1.5))
                    }
                }
                .overlay {
                    if viewport != .phone {
                        RoundedRectangle(cornerRadius: 4).stroke(ChatTheme.border)
                    }
                }
            if preview.loading {
                ProgressView().controlSize(.small)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(ChatTheme.claudeBubble))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(bezel + 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in availableWidth = width }
            }
        }
        .accessibilityLabel("サイトのプレビュー（\(viewport.label)）")
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
        let project = project
        let (found, modified) = await Task.detached(priority: .userInitiated) { () -> (SiteLookup, Date?) in
            let lookup = SiteLocator.lookup(project: project)
            return (lookup, lookup.location.flatMap { SiteLocator.exportModified($0) })
        }.value
        guard !Task.isCancelled else { return }
        lookup = found
        exportModified = modified
        normalizeSource()
        serverProblem = nil
        guard let location = found.location, modified != nil else {
            exportURL = nil
            return
        }
        do {
            exportURL = try await SitePreviewServers.shared.baseURL(for: location.exportDir)
        } catch {
            exportURL = nil
            if case SitePreviewServers.Failure.failed(let reason) = error {
                serverProblem = "書き出しを配信できませんでした: \(reason)"
            } else {
                serverProblem = "書き出しを配信できませんでした"
            }
        }
        // 書き出しが新しくなっていればサムネイルも撮り直させる。
        SiteThumbnailStore.shared.request(project)
    }

    /// 選んでいた見る元が無くなったら、使えるものに替える。
    private func normalizeSource() {
        switch source {
        case .export:
            if location == nil, let first = links.first { source = .link(first.url) }
        case .link(let url):
            if !links.contains(where: { $0.url == url }) {
                source = location != nil ? .export : links.first.map { .link($0.url) } ?? .export
            }
        }
    }

    private func openInBrowser() {
        guard let url = SiteNavigationPolicy.browserURL(preview.currentURL) ?? targetURL else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 表示幅の切り替えボタン（PC / タブレット / スマホ）。
private struct ViewportButton: View {
    let option: SiteViewport
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: option.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? ChatTheme.onAccent : ChatTheme.text)
                .frame(width: 30, height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? ChatTheme.accent : (hovering ? ChatTheme.selectedRow : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .headerButtonHelp(name: option.label, detail: "幅 \(Int(option.width))px で表示", busyStatus: nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
    }
}
