import AppKit
import MonitorKit
import SwiftUI

/// ディレクトリの詳細の「画像」: プロジェクト配下の画像をフォルダごとにサムネイルで並べる。クリックで拡大、右クリックで Finder とパスのコピー。
struct ProjectImagesSection: View {
    let project: ManagedProject
    /// 詳細が持つストア（タブを行き来しても走査の結果と件数を保つ）。
    let store: ProjectImageStore

    @State private var previewing: ProjectImage?
    @State private var collapsedGroups: Set<String> = []

    private static let columns = [GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 10, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            content
        }
        .detailCard()
        // タブを離れれば画面ごと消えて走査中のものは取りやめる。
        .task(id: scanKey) { await store.scanIfNeeded(scanKey) }
        .sheet(item: $previewing) { image in
            ProjectImagePreview(image: image, store: store)
        }
    }

    private var scanKey: DetailScanKey { DetailScanKey(path: project.path, token: store.reloadToken) }

    private var toolbar: some View {
        HStack(spacing: 8) {
            SectionTitle(name: "画像", count: store.scan?.count)
            Spacer(minLength: 8)
            HeaderButton(symbol: "arrow.clockwise", name: "再読み込み", detail: "プロジェクト配下を走査し直す",
                         busyStatus: store.scanning ? "走査中" : nil) {
                store.reloadToken += 1
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let scan = store.scan {
            if scan.groups.isEmpty {
                SectionNote("画像なし")
            }
            ForEach(scan.groups) { group in
                groupView(group)
            }
            if scan.truncated {
                SectionNote("画像が \(ProjectImages.maxCount) 件かフォルダが \(ProjectImages.maxDirectories) 個を超えたため、浅いフォルダから \(scan.count) 件までを出しています（深さ \(ProjectImages.maxDepth) まで）")
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
                    DisclosureChevron(collapsed: isCollapsed)
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
            Button("Finder で表示") { SystemActions.revealInFinder(path: image.path) }
            Button("パスをコピー") { SystemActions.copy(image.path) }
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
        GridTile { ThumbnailContent(image: shown?.image, failed: failed) }
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
                Button("Finder で表示") { SystemActions.revealInFinder(path: image.path) }
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ImagePreviewContent(image: full?.image, failed: failed)
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
}
