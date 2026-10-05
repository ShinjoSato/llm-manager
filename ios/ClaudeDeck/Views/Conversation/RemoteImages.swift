import SwiftUI
import UIKit

/// 発話に添えられた画像 1 枚（mac から `GET …/images/{index}` で取る）。
struct RemoteImageRef: Hashable, Identifiable {
    let sessionId: String
    let itemId: String
    let index: Int

    var id: String { "\(sessionId)/\(itemId)/\(index)" }
}

/// 取った画像を縮小して覚えておく（同じ発話の同じ位置の画像は変わらない）。
@MainActor
enum RemoteImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 << 20
        return cache
    }()

    static func image(_ ref: RemoteImageRef) -> UIImage? { cache.object(forKey: ref.id as NSString) }

    static func store(_ image: UIImage, for ref: RemoteImageRef) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: ref.id as NSString, cost: cost)
    }
}

/// 吹き出しのサムネイル（最大 3 列）。押すと全画面で開く。
struct RemoteImageGrid: View {
    let images: [RemoteImageRef]
    @State private var opened: RemoteImageRef?

    var body: some View {
        let columns = min(images.count, 3)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 6), count: max(columns, 1)), spacing: 6) {
            ForEach(images) { ref in
                RemoteThumbnail(ref: ref)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { opened = ref }
            }
        }
        .fixedSize()
        .fullScreenCover(item: $opened) { ref in
            RemoteImageViewer(ref: ref) { opened = nil }
        }
    }
}

private struct RemoteThumbnail: View {
    let ref: RemoteImageRef
    @Environment(AppModel.self) private var model
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            DeckTheme.inputSurface
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if failed {
                Image(systemName: "photo").foregroundStyle(DeckTheme.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityLabel("画像")
        .task(id: ref) { await load() }
    }

    private func load() async {
        if let cached = RemoteImageCache.image(ref) {
            image = cached
            return
        }
        guard let data = await model.imageData(sessionId: ref.sessionId, itemId: ref.itemId, index: ref.index),
              let decoded = Self.downsample(data, maxPixel: 1600) else {
            failed = true
            return
        }
        RemoteImageCache.store(decoded, for: ref)
        image = decoded
    }

    /// 大きな画像をそのまま持たない（スクリーンショットは数千ピクセルある）。
    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height) * image.scale
        guard longest > maxPixel else { return image }
        return image.preparingThumbnail(of: CGSize(width: image.size.width * image.scale * maxPixel / longest,
                                                   height: image.size.height * image.scale * maxPixel / longest))
    }
}

private struct RemoteImageViewer: View {
    let ref: RemoteImageRef
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image = RemoteImageCache.image(ref) {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        .containerRelativeFrame([.horizontal, .vertical])
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.black.opacity(0.55)))
            }
            .padding(16)
            .accessibilityLabel("閉じる")
        }
    }
}
