import AppKit
import MonitorKit
import SwiftUI

/// ディレクトリの詳細の「画像」: プロジェクト配下の画像をフォルダごとにサムネイルで並べる。クリックで拡大、右クリックで Finder とパスのコピー。
struct ProjectImagesSection: View {
    let project: ManagedProject

    @State private var store = ProjectImageStore()
    @State private var previewing: ProjectImage?
    @State private var collapsedGroups: Set<String> = []
    @State private var reloadToken = 0
    @State private var scannedToken: Int?
    @AppStorage("directory.images.collapsed") private var collapsed = false

    private static let columns = [GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 10, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if !collapsed { content }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(ChatTheme.claudeBubble))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ChatTheme.claudeBubbleBorder))
        // 畳んでいる間は走査せず、開いた時に初めて走査する（畳めば走査中のものは取りやめる）。
        .task(id: ScanKey(path: project.path, open: !collapsed, token: reloadToken)) {
            guard !collapsed, store.scan == nil || scannedToken != reloadToken else { return }
            scannedToken = reloadToken
            await store.reload(projectPath: project.path)
        }
        .sheet(item: $previewing) { image in
            ProjectImagePreview(image: image, store: store)
        }
    }

    private struct ScanKey: Hashable {
        let path: String
        let open: Bool
        let token: Int
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { collapsed.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ChatTheme.tertiary)
                        .frame(width: 10)
                    Text(store.scan.map { "画像  \($0.count)" } ?? "画像")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ChatTheme.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "画像の節を開く" : "画像の節を畳む")
            Spacer(minLength: 8)
            HeaderButton(symbol: "arrow.clockwise", name: "再読み込み", detail: "プロジェクト配下を走査し直す",
                         busyStatus: store.scanning ? "走査中" : nil) {
                collapsed = false
                reloadToken += 1
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let scan = store.scan {
            if scan.groups.isEmpty {
                emptyText("画像なし")
            }
            ForEach(scan.groups) { group in
                groupView(group)
            }
            if scan.truncated {
                emptyText("画像が \(ProjectImages.maxCount) 件かフォルダが \(ProjectImages.maxDirectories) 個を超えたため、浅いフォルダから \(scan.count) 件までを出しています（深さ \(ProjectImages.maxDepth) まで）")
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 40)
        }
    }

    private func groupView(_ group: ProjectImageGroup) -> some View {
        let isCollapsed = collapsedGroups.contains(group.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if isCollapsed { collapsedGroups.remove(group.id) } else { collapsedGroups.insert(group.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ChatTheme.tertiary)
                        .frame(width: 10)
                    Text(group.relativePath == "." ? "プロジェクト直下" : group.relativePath)
                        .font(ChatTheme.mono)
                        .foregroundStyle(ChatTheme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(group.images.count)")
                        .font(ChatTheme.caption)
                        .foregroundStyle(ChatTheme.tertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(SiteLocator.absolute(group.relativePath, in: project.path))
            if !isCollapsed {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                    ForEach(group.images) { image in
                        ProjectImageCell(image: image, store: store) { previewing = image }
                    }
                }
            }
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(ChatTheme.caption)
            .foregroundStyle(ChatTheme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// グリッドの 1 枠: サムネイル・ファイル名・寸法とファイルサイズ。読んだ絵と寸法は枠ごとに持つ（他の枠の読み込みで描き直さない）。
private struct ProjectImageCell: View {
    let image: ProjectImage
    let store: ProjectImageStore
    let open: () -> Void

    @State private var loaded: ProjectImageStore.LoadedImage?
    @State private var failed = false

    var body: some View {
        let shown = loaded ?? store.cachedThumbnail(image)
        VStack(alignment: .leading, spacing: 4) {
            Button(action: open) {
                thumbnail(shown)
            }
            .buttonStyle(.plain)
            .help("クリックで拡大: \(image.relativePath)")
            Text(image.name)
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(ProjectImageCaption.text(dimensions: shown?.pixelSize, fileSize: image.fileSize))
                .font(.system(size: 10))
                .foregroundStyle(ChatTheme.tertiary)
                .lineLimit(1)
        }
        .contextMenu {
            Button("Finder で表示") { ProjectImageActions.revealInFinder(image) }
            Button("パスをコピー") { ProjectImageActions.copyPath(image) }
        }
        .task(id: "\(store.key(image))|\(ProjectImageStore.thumbnailPixels)") {
            // 別の画像に替わったら前の絵を出し続けない（読み直しは NSCache に当たる）。
            loaded = nil
            failed = false
            let result = await store.thumbnail(image)
            guard !Task.isCancelled else { return }
            loaded = result
            failed = result == nil
        }
    }

    private func thumbnail(_ shown: ProjectImageStore.LoadedImage?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        return Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(shape.fill(ChatTheme.inputSurface))
            .overlay {
                if let shown {
                    Image(nsImage: shown.image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else if failed {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(ChatTheme.tertiary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipShape(shape)
            .overlay(shape.stroke(ChatTheme.border))
            .contentShape(shape)
    }
}

/// 枠の下の「W×H・サイズ」。
enum ProjectImageCaption {
    static func text(dimensions: ProjectImageStore.PixelSize?, fileSize: Int) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
        guard let dimensions else { return size }
        return "\(dimensions.width)×\(dimensions.height)・\(size)"
    }
}

enum ProjectImageActions {
    static func revealInFinder(_ image: ProjectImage) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: image.path)])
    }

    static func copyPath(_ image: ProjectImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(image.path, forType: .string)
    }
}

/// 画像の拡大表示。Esc か「閉じる」で閉じる。
private struct ProjectImagePreview: View {
    let image: ProjectImage
    let store: ProjectImageStore
    @Environment(\.dismiss) private var dismiss
    @State private var full: ProjectImageStore.LoadedImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(image.name)
                        .font(ChatTheme.body)
                        .foregroundStyle(ChatTheme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(ProjectImageCaption.text(dimensions: full?.pixelSize, fileSize: image.fileSize))
                        .font(ChatTheme.caption)
                        .foregroundStyle(ChatTheme.tertiary)
                }
                Spacer(minLength: 12)
                Button("Finder で表示") { ProjectImageActions.revealInFinder(image) }
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            content
        }
        .padding(16)
        .background(ChatTheme.background)
        .task {
            let result = await store.preview(image)
            guard !Task.isCancelled else { return }
            full = result
            failed = result == nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if let full {
            let size = ChatImagePreview.fitted(full.image.size)
            Image(nsImage: full.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if failed {
            Label("画像を読み込めませんでした", systemImage: "exclamationmark.triangle")
                .foregroundStyle(ChatTheme.secondary)
                .frame(width: 480, height: 320)
        } else {
            ProgressView().frame(width: 480, height: 320)
        }
    }
}
