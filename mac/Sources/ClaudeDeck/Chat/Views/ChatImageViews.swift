import SwiftUI
import AppKit
import ImageIO
import MonitorKit

/// 吹き出しの画像の読み込み。表示された時にだけ取り、縮小した絵を NSCache に持つ（長い会話でも全部は持たない）。
@MainActor
final class ChatImageLoader {
    /// 吹き出しのサムネイルの長辺（Retina で 2〜3 列に並べて粗く見えない大きさ）。
    static let thumbnailPixels = 480
    /// 拡大表示の長辺。原寸が大きすぎる画像でもメモリを食い過ぎないよう抑える。
    static let previewPixels = 2400

    typealias Source = @Sendable (String, String, Int) async -> Data?
    private let source: Source
    private let thumbnails = NSCache<NSString, NSImage>()
    private let previews = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init(source: @escaping Source) {
        self.source = source
        thumbnails.countLimit = 300
        thumbnails.totalCostLimit = 128 * 1024 * 1024
        previews.countLimit = 4
    }

    func cachedThumbnail(_ image: ChatImage, sessionId: String?) -> NSImage? {
        key(image, sessionId: sessionId, size: Self.thumbnailPixels).flatMap { thumbnails.object(forKey: $0 as NSString) }
    }

    func thumbnail(_ image: ChatImage, sessionId: String?) async -> NSImage? {
        await load(image, sessionId: sessionId, maxPixels: Self.thumbnailPixels, cache: thumbnails)
    }

    func preview(_ image: ChatImage, sessionId: String?) async -> NSImage? {
        await load(image, sessionId: sessionId, maxPixels: Self.previewPixels, cache: previews)
    }

    private func key(_ image: ChatImage, sessionId: String?, size: Int) -> String? {
        switch image {
        case .transcript:
            guard let sessionId else { return nil }
            return "\(sessionId)|\(image.id)|\(size)"
        case .file:
            return "\(image.id)|\(size)"
        }
    }

    private func load(_ image: ChatImage, sessionId: String?, maxPixels: Int, cache: NSCache<NSString, NSImage>) async -> NSImage? {
        guard let key = key(image, sessionId: sessionId, size: maxPixels) else { return nil }
        if let cached = cache.object(forKey: key as NSString) { return cached }
        // 同じ画像を複数の吹き出し・再描画から同時に頼まれても 1 回だけ取る。
        if let running = inFlight[key] { return await running.value }
        let source = source
        let task = Task<NSImage?, Never> {
            let decoded = await Task.detached(priority: .userInitiated) {
                await Self.decode(image, sessionId: sessionId, maxPixels: maxPixels, source: source)
            }.value
            return decoded.map { NSImage(pixelSized: $0.image) }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            cache.setObject(result, forKey: key as NSString, cost: Int(result.size.width * result.size.height * 4))
        }
        return result
    }

    nonisolated private static func decode(_ image: ChatImage, sessionId: String?, maxPixels: Int,
                                           source: Source) async -> DecodedImage? {
        let data: Data?
        switch image {
        case .file(let path):
            data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        case .transcript(let itemId, let index):
            guard let sessionId else { return nil }
            data = await source(sessionId, itemId, index)
        }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return ImageDecoding.thumbnail(of: source, maxPixels: maxPixels).map(DecodedImage.init)
    }
}

private struct DecodedImage: @unchecked Sendable {
    let image: CGImage
}

/// 吹き出しが画像を引くための組（どのセッションの transcript か）。
struct ChatImageSource {
    let loader: ChatImageLoader
    let sessionId: String?
}

/// 吹き出しに添える画像のサムネイル（最大 3 列）。クリックで拡大表示する。
struct ChatImageGrid: View {
    let images: [ChatImage]
    let source: ChatImageSource
    @State private var previewing: ChatImage?

    var body: some View {
        // 読み込みの前後で大きさが変わるとスクロール位置が揺れるので、枠の大きさは枚数だけで決める。
        let side: CGFloat = images.count == 1 ? 200 : 120
        let columns = Array(repeating: GridItem(.fixed(side), spacing: 6), count: min(images.count, 3))
        LazyVGrid(columns: columns, alignment: .trailing, spacing: 6) {
            ForEach(images) { image in
                Button { previewing = image } label: {
                    ChatImageThumbnail(image: image, source: source, side: side)
                }
                .buttonStyle(.plain)
                .help("クリックで拡大")
            }
        }
        .fixedSize()
        .sheet(item: $previewing) { image in
            ChatImagePreview(image: image, source: source)
        }
    }
}

struct ChatImageThumbnail: View {
    let image: ChatImage
    let source: ChatImageSource
    let side: CGFloat
    @State private var loaded: NSImage?
    @State private var failed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        ZStack {
            shape.fill(ChatTheme.inputSurface)
            ThumbnailContent(image: loaded ?? source.loader.cachedThumbnail(image, sessionId: source.sessionId), failed: failed)
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.stroke(ChatTheme.border))
        .contentShape(shape)
        .task(id: "\(source.sessionId ?? "")|\(image.id)") {
            // id が替わったら前の絵を出し続けない（読み直しは NSCache に当たる）。
            loaded = nil
            failed = false
            loaded = await source.loader.thumbnail(image, sessionId: source.sessionId)
            failed = loaded == nil
        }
    }
}

/// 画像の拡大表示。Esc か「閉じる」で閉じる。
struct ChatImagePreview: View {
    let image: ChatImage
    let source: ChatImageSource
    @Environment(\.dismiss) private var dismiss
    @State private var full: NSImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ImagePreviewContent(image: full, failed: failed)
        }
        .padding(16)
        .background(ChatTheme.background)
        .task {
            full = await source.loader.preview(image, sessionId: source.sessionId)
            failed = full == nil
        }
    }
}

/// サムネイルの枠の中身（読めた絵・読めなかった印・読み込み中）。
struct ThumbnailContent: View {
    let image: NSImage?
    let failed: Bool

    var body: some View {
        if let image {
            Image(nsImage: image)
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
}

/// 拡大表示の絵（画面に収まる大きさ）。読めなければ理由、読み込み中は回転の印。
struct ImagePreviewContent: View {
    let image: NSImage?
    let failed: Bool

    var body: some View {
        if let image {
            let size = Self.fitted(image.size)
            Image(nsImage: image)
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

    /// 画面に収まる大きさ（拡大はしない）。
    static func fitted(_ size: NSSize) -> NSSize {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let limit = NSSize(width: min(1200, screen.width * 0.85), height: min(860, screen.height * 0.8))
        guard size.width > 0, size.height > 0 else { return NSSize(width: 480, height: 320) }
        let scale = min(1, limit.width / size.width, limit.height / size.height)
        return NSSize(width: max(160, size.width * scale), height: max(120, size.height * scale))
    }
}
