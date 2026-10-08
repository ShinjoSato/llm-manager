import AppKit
import MonitorKit
import SwiftUI

/// ディレクトリの詳細の「iPhone のプレビュー」: `#Preview` をファイルごとに並べ、起動中の Xcode（RenderPreview）で描いた絵を出す。
struct IOSPreviewsSection: View {
    let project: ManagedProject
    /// 開く `.xcworkspace` / `.xcodeproj`。
    let xcodeProject: URL

    @State private var list = IOSPreviewList()
    @State private var opened: IOSPreviewTarget?
    @State private var reloadToken = 0
    @State private var scanned: ScanRequest?
    @State private var xcodeRunning = true
    /// 畳んだまま「すべて描く」を押した時は、節を開いてから足す（閉じた節の分は取りやめるため）。
    @State private var renderAllWhenOpened = false
    @AppStorage("directory.iosPreviews.collapsed") private var collapsed = true

    private static let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12, alignment: .top)]
    private var service: IOSPreviewService { .shared }
    private var root: String { SwiftPreviews.scanRoot(forXcodeProject: xcodeProject.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if !collapsed {
                notices
                content
            }
        }
        .detailCard()
        // 畳んでいる間は走査せず、開いた時に初めて走査する。
        .task(id: ScanKey(root: root, open: !collapsed, token: reloadToken)) {
            let request = ScanRequest(root: root, token: reloadToken)
            guard !collapsed, scanned != request else { return }
            if await list.reload(root: root) { scanned = request }
        }
        // 開いている間は mcpbridge を止めず、Xcode が動いているかを見続ける。閉じたらこのプロジェクトの待ち行列を取りやめる。
        .task(id: collapsed) {
            guard !collapsed else { return }
            service.sectionOpened(project.id)
            if renderAllWhenOpened {
                renderAllWhenOpened = false
                if list.scan != nil { service.renderAll(targets) }
            }
            while !Task.isCancelled {
                xcodeRunning = IOSPreviewService.xcodeIsRunning()
                try? await Task.sleep(for: .seconds(3))
            }
            service.sectionClosed(project.id)
        }
        .sheet(item: $opened) { target in
            IOSPreviewSheet(target: target)
        }
    }

    private struct ScanKey: Hashable {
        let root: String
        let open: Bool
        let token: Int
    }

    private struct ScanRequest: Equatable {
        let root: String
        let token: Int
    }

    private var targets: [IOSPreviewTarget] {
        (list.scan?.files ?? []).flatMap { file in
            file.previews.map { IOSPreviewTarget(projectId: project.id, projectName: project.name,
                                                 xcodeProject: xcodeProject.path, file: file, preview: $0) }
        }
    }

    private var toolbar: some View {
        let busy = service.busyProjects.contains(project.id)
        return HStack(spacing: 8) {
            Button { collapsed.toggle() } label: {
                HStack(spacing: 6) {
                    DisclosureChevron(collapsed: collapsed)
                    Text(list.scan.map { "iPhone のプレビュー  \($0.count)" } ?? "iPhone のプレビュー")
                        .sectionLabelStyle()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "iPhone のプレビューの節を開く" : "iPhone のプレビューの節を畳む")
            Spacer(minLength: 8)
            if busy {
                HeaderButton(symbol: "stop.fill", name: "取りやめる",
                             detail: "待っている分を描かずに戻す（描いている 1 件は終わるまで待つ）",
                             busyStatus: service.isCancelling(project.id) ? "取りやめ中" : nil) {
                    service.cancel(projectId: project.id)
                }
            } else {
                HeaderButton(symbol: "play.rectangle.on.rectangle", name: "すべて描く",
                             detail: "まだ描いていないプレビューを Xcode で 1 件ずつ描く（節を閉じると残りは取りやめる）") {
                    if collapsed {
                        renderAllWhenOpened = true
                        collapsed = false
                    } else {
                        service.renderAll(targets)
                    }
                }
                .disabled(list.scan == nil || targets.isEmpty)
            }
            HeaderButton(symbol: "arrow.clockwise", name: "再読み込み", detail: "ソースの #Preview を探し直す",
                         busyStatus: list.scanning ? "走査中" : nil) {
                collapsed = false
                reloadToken += 1
            }
        }
        .zIndex(1)
    }

    @ViewBuilder
    private var notices: some View {
        let relative = xcodeProject.path.hasPrefix(project.path + "/")
            ? String(xcodeProject.path.dropFirst(project.path.count + 1)) : xcodeProject.path
        Text("Xcode: \(relative)")
            .font(ChatTheme.caption)
            .foregroundStyle(ChatTheme.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        if !xcodeRunning {
            noticeRow(symbol: "hammer", text: XcodeBridgeFailure.xcodeNotRunning.message, color: ChatTheme.secondary)
        } else if let notice = service.xcodeNotice {
            noticeRow(symbol: "hammer", text: notice, color: ChatTheme.secondary)
        }
        if service.busyProjects.contains(project.id), let activity = service.activity {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(activity.text)
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let problem = service.problems[project.id] {
            HStack(alignment: .top, spacing: 8) {
                noticeRow(symbol: "exclamationmark.triangle", text: problem, color: ChatTheme.error)
                Spacer(minLength: 0)
                Button { service.clearProblem(project.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ChatTheme.tertiary)
                .help("この知らせを消す")
            }
        }
    }

    private func noticeRow(symbol: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(ChatTheme.caption)
        .foregroundStyle(color)
    }

    @ViewBuilder
    private var content: some View {
        if let scan = list.scan {
            if scan.files.isEmpty {
                emptyText("#Preview なし（\(root) の下の Swift ファイル）")
            }
            // ファイルの区切りは付けず、全部を 1 つのグリッドに並べる（ファイル名は各枠に出す）。
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                ForEach(scan.files) { file in
                    ForEach(file.previews, id: \.index) { preview in
                        let target = IOSPreviewTarget(projectId: project.id, projectName: project.name,
                                                      xcodeProject: xcodeProject.path, file: file, preview: preview)
                        IOSPreviewCell(target: target) { opened = target }
                    }
                }
            }
            if scan.truncated {
                emptyText("Swift ファイルが \(SwiftPreviews.maxFiles) 件かフォルダが \(SwiftPreviews.maxDirectories) 個を超えたため、浅いフォルダから読んだ分だけを出しています")
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 40)
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(ChatTheme.caption)
            .foregroundStyle(ChatTheme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension IOSPreviewTarget: Identifiable {
    var id: String { "\(file.relativePath)#\(preview.index)" }
}

/// グリッドの 1 枠: 描いた絵か、名前と「描く」。描いている・待っている・失敗はその場に出す。
private struct IOSPreviewCell: View {
    let target: IOSPreviewTarget
    let open: () -> Void

    @State private var stored: IOSPreviewRendered?
    @State private var image: NSImage?

    private var service: IOSPreviewService { .shared }
    private var request: PreviewRenderRequest { IOSPreviewService.defaultRequest(target) }
    private var key: IOSPreviewItemKey { IOSPreviewItemKey(projectId: target.projectId, request: request) }
    private var cacheKey: PreviewCacheKey {
        PreviewCacheKey(projectId: target.projectId, request: request, sourceModified: target.file.modified)
    }

    var body: some View {
        let shown = service.current(key, sourceModified: target.file.modified) ?? stored
        let state = service.states[key]
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if shown != nil { open() } else { service.render(target, request: request) }
            } label: {
                frame(shown: shown, state: state)
            }
            .buttonStyle(.plain)
            .help(help(shown: shown, state: state))
            Text(target.preview.name ?? shown?.info.displayName ?? target.file.name)
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(target.file.name) · \(target.preview.line) 行")
                .font(.system(size: 10))
                .foregroundStyle(ChatTheme.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(target.file.relativePath)
            if let shown, shown.info.lineMismatch(expected: target.preview.line) {
                LineMismatchLabel(info: shown.info, expected: target.preview.line)
            }
        }
        .contextMenu {
            Button(shown == nil ? "描く" : "描き直す") { service.render(target, request: request) }
            if shown != nil { Button("拡大して切り替える") { open() } }
            Divider()
            Button("ソースを Finder で表示") { SystemActions.revealInFinder(path: target.file.path) }
            if let shown { Button("画像を Finder で表示") { SystemActions.revealInFinder(path: shown.image.path) } }
            Button("ソースのパスをコピー") { SystemActions.copy(target.file.path) }
        }
        .task(id: cacheKey) {
            stored = await IOSPreviewService.cached(cacheKey)
        }
        .task(id: shown) {
            guard let shown else {
                image = nil
                return
            }
            image = IOSPreviewImages.shared.cached(shown, maxPixels: IOSPreviewImages.thumbnailPixels)
            let loaded = await IOSPreviewImages.shared.load(shown, maxPixels: IOSPreviewImages.thumbnailPixels)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }

    private func help(shown: IOSPreviewRendered?, state: IOSPreviewService.ItemState?) -> String {
        if case .failed(let message) = state { return message }
        if let shown, shown.info.lineMismatch(expected: target.preview.line) {
            return LineMismatchLabel.detail(info: shown.info, expected: target.preview.line)
        }
        if shown != nil { return "クリックで拡大: \(target.file.relativePath)（\(target.preview.line) 行）" }
        return "クリックで描く: \(target.file.relativePath)（\(target.preview.line) 行）"
    }

    private func frame(shown: IOSPreviewRendered?, state: IOSPreviewService.ItemState?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        return Color.clear
            .aspectRatio(0.5, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(shape.fill(ChatTheme.inputSurface))
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                } else if shown != nil {
                    ProgressView().controlSize(.small)
                } else {
                    placeholder(state: state)
                }
            }
            .overlay(alignment: .topTrailing) {
                // 描き直しの間も前の絵は出したまま、隅に状態を出す。
                if shown != nil, let state { badge(state).padding(6) }
            }
            .clipShape(shape)
            .overlay(shape.stroke(ChatTheme.border))
            .contentShape(shape)
    }

    @ViewBuilder
    private func placeholder(state: IOSPreviewService.ItemState?) -> some View {
        VStack(spacing: 8) {
            switch state {
            case .rendering:
                ProgressView().controlSize(.small)
                Text("描いています").foregroundStyle(ChatTheme.secondary)
            case .queued:
                Image(systemName: "clock").foregroundStyle(ChatTheme.tertiary)
                Text("待機中").foregroundStyle(ChatTheme.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(ChatTheme.error)
                Text("描けませんでした").foregroundStyle(ChatTheme.error)
                Text("クリックでもう一度").foregroundStyle(ChatTheme.tertiary)
            case nil:
                Image(systemName: "iphone").font(.system(size: 18)).foregroundStyle(ChatTheme.tertiary)
                Text(target.preview.name ?? target.file.name)
                    .foregroundStyle(ChatTheme.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                Label("描く", systemImage: "play.fill")
                    .foregroundStyle(ChatTheme.link)
            }
        }
        .font(ChatTheme.caption)
        .padding(8)
    }

    @ViewBuilder
    private func badge(_ state: IOSPreviewService.ItemState) -> some View {
        switch state {
        case .rendering, .queued:
            ProgressView().controlSize(.mini)
                .padding(4)
                .background(Circle().fill(ChatTheme.background.opacity(0.85)))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(ChatTheme.error)
                .padding(4)
                .background(Circle().fill(ChatTheme.background.opacity(0.85)))
        }
    }
}

/// 拡大のシート: 返った候補（外観・文字の大きさ・向き・言語 等）から選んで描き直す。Esc で閉じる。
private struct IOSPreviewSheet: View {
    let target: IOSPreviewTarget

    @Environment(\.dismiss) private var dismiss
    @State private var variants: [String: String] = [:]
    @State private var locale: String?
    @State private var stored: IOSPreviewRendered?
    @State private var defaultStored: IOSPreviewRendered?
    @State private var image: NSImage?
    @State private var loadedFor: IOSPreviewRendered?

    private var service: IOSPreviewService { .shared }
    private var request: PreviewRenderRequest {
        PreviewRenderRequest(relativePath: target.file.relativePath, index: target.preview.index, variants: variants, locale: locale)
    }
    private var key: IOSPreviewItemKey { IOSPreviewItemKey(projectId: target.projectId, request: request) }
    private var defaultKey: IOSPreviewItemKey {
        IOSPreviewItemKey(projectId: target.projectId, request: IOSPreviewService.defaultRequest(target))
    }
    private func cacheKey(_ request: PreviewRenderRequest) -> PreviewCacheKey {
        PreviewCacheKey(projectId: target.projectId, request: request, sourceModified: target.file.modified)
    }

    var body: some View {
        let shown = service.current(key, sourceModified: target.file.modified) ?? stored
        // 切り替えの候補は、今の絵か既定の絵の返した分から出す。
        let info = shown?.info ?? service.current(defaultKey, sourceModified: target.file.modified)?.info ?? defaultStored?.info
        let state = service.states[key]
        VStack(spacing: 12) {
            header(info: shown?.info)
            HStack(alignment: .top, spacing: 16) {
                picture(shown: shown, state: state)
                    .frame(minWidth: 320, maxWidth: .infinity)
                controls(info: info, shown: shown, state: state)
                    .frame(width: 260)
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 560)
        .background(ChatTheme.background)
        .task(id: cacheKey(request)) {
            stored = await IOSPreviewService.cached(cacheKey(request))
        }
        .task {
            defaultStored = await IOSPreviewService.cached(cacheKey(IOSPreviewService.defaultRequest(target)))
        }
        .task(id: shown) {
            guard let shown else {
                image = nil
                loadedFor = nil
                return
            }
            let loaded = await IOSPreviewImages.shared.load(shown, maxPixels: IOSPreviewImages.previewPixels)
            guard !Task.isCancelled else { return }
            image = loaded
            loadedFor = shown
        }
    }

    private func header(info: PreviewSnapshotInfo?) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.preview.name ?? info?.displayName ?? target.file.name)
                    .font(ChatTheme.body)
                    .foregroundStyle(ChatTheme.text)
                    .lineLimit(1)
                Text("\(target.file.relativePath)（\(target.preview.line) 行）")
                    .font(ChatTheme.mono)
                    .foregroundStyle(ChatTheme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button("ソースを Finder で表示") { SystemActions.revealInFinder(path: target.file.path) }
            Button("閉じる") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private func picture(shown: IOSPreviewRendered?, state: IOSPreviewService.ItemState?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        ZStack {
            shape.fill(ChatTheme.inputSurface)
            if let image, loadedFor == shown {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(10)
            } else if shown != nil {
                ProgressView()
            } else {
                VStack(spacing: 8) {
                    switch state {
                    case .rendering, .queued:
                        ProgressView()
                        Text(state == .queued ? "待機中" : "描いています").foregroundStyle(ChatTheme.secondary)
                    case .failed(let message):
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(ChatTheme.error)
                        Text(message)
                            .foregroundStyle(ChatTheme.error)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    case nil:
                        Image(systemName: "iphone").font(.system(size: 22)).foregroundStyle(ChatTheme.tertiary)
                        Text("この組み合わせはまだ描いていません。「描く」で描きます").foregroundStyle(ChatTheme.secondary)
                    }
                }
                .font(ChatTheme.caption)
                .padding(16)
            }
        }
        .frame(height: min(760, (NSScreen.main?.visibleFrame.height ?? 900) * 0.72))
    }

    private func controls(info: PreviewSnapshotInfo?, shown: IOSPreviewRendered?, state: IOSPreviewService.ItemState?) -> some View {
        let busy = state == .queued || state == .rendering
        return VStack(alignment: .leading, spacing: 12) {
            if let info, !info.supportedVariants.isEmpty || !info.supportedLocalizations.isEmpty {
                ForEach(PreviewVariantLabels.ordered(Array(info.supportedVariants.keys)), id: \.self) { group in
                    picker(label: PreviewVariantLabels.label(for: group), options: info.supportedVariants[group] ?? [],
                           selection: Binding(get: { variants[group] }, set: { variants[group] = $0 }))
                }
                if !info.supportedLocalizations.isEmpty {
                    picker(label: "言語", options: info.supportedLocalizations,
                           selection: Binding(get: { locale }, set: { locale = $0 }))
                }
            } else {
                Text("一度描くと、外観・文字の大きさ・向き・言語の候補を選べます")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                service.render(target, request: request)
            } label: {
                Label(shown == nil ? "描く" : "描き直す", systemImage: "play.fill")
            }
            .disabled(busy)
            if busy, let activity = service.activity {
                Text(activity.text)
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if shown != nil, case .failed(let message) = state {
                Text(message)
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Divider()
            if let shown {
                if shown.info.lineMismatch(expected: target.preview.line) {
                    Text(LineMismatchLabel.detail(info: shown.info, expected: target.preview.line))
                        .font(ChatTheme.caption)
                        .foregroundStyle(ChatTheme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                detail("表示名", shown.info.displayName)
                detail("端末", shown.info.destination?.label)
                detail("描いた時刻", shown.info.renderedAt.formatted(date: .abbreviated, time: .standard))
                Button("画像を Finder で表示") { SystemActions.revealInFinder(path: shown.image.path) }
            }
            Spacer(minLength: 0)
        }
    }

    private func picker(label: String, options: [String], selection: Binding<String?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.secondary)
            Picker(label, selection: selection) {
                Text("既定").tag(String?.none)
                ForEach(options, id: \.self) { option in
                    Text(option).tag(Optional(option))
                }
            }
            .labelsHidden()
        }
    }

    private func detail(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.secondary)
            Text(value ?? "不明")
                .font(ChatTheme.caption)
                .foregroundStyle(value == nil ? ChatTheme.tertiary : ChatTheme.text)
                .textSelection(.enabled)
        }
    }
}

/// Xcode が描いた定義の行が、一覧の行と違う時の印（`#if` 等で番号がずれて別のプレビューを描いた可能性）。
private struct LineMismatchLabel: View {
    let info: PreviewSnapshotInfo
    let expected: Int

    static func detail(info: PreviewSnapshotInfo, expected: Int) -> String {
        "別のプレビューの可能性: Xcode が描いたのは \(info.sourceLineNumber.map(String.init) ?? "?") 行の定義で、一覧の \(expected) 行と違います（#if などで数え方がずれた時に起きます）"
    }

    var body: some View {
        Label("別のプレビューの可能性", systemImage: "exclamationmark.triangle")
            .font(.system(size: 10))
            .foregroundStyle(ChatTheme.error)
            .lineLimit(1)
            .help(Self.detail(info: info, expected: expected))
    }
}
