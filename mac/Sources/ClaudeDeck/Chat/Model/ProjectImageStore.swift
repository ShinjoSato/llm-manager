import AppKit
import ImageIO
import MonitorKit

/// ディレクトリの詳細の「画像」: プロジェクト配下の走査とサムネイル。走査もデコードもバックグラウンドで行い、縮小した絵だけを NSCache に持つ。
@MainActor
@Observable
final class ProjectImageStore {
    /// グリッドのサムネイルの長辺（Retina の 150px の枠で粗く見えない大きさ）。
    static let thumbnailPixels = 320
    /// 拡大表示の長辺。原寸が大きすぎる画像でもメモリを食い過ぎないよう抑える。
    static let previewPixels = 2400
    /// ImageIO で読めないもの（SVG 等）を描く時の長辺。ベクターは大きく描いても意味が薄い。
    private static let rasterPixels = 1200

    struct PixelSize: Equatable {
        let width: Int
        let height: Int
    }

    private(set) var scan: ProjectImageScan?
    private(set) var scanning = false
    /// 読み込めた画像のピクセル寸法（キャッシュのキーごと。SVG 等は無い）。
    private(set) var dimensions: [String: PixelSize] = [:]

    @ObservationIgnored private let thumbnails = NSCache<NSString, NSImage>()
    @ObservationIgnored private let previews = NSCache<NSString, NSImage>()
    @ObservationIgnored private var inFlight: [String: Task<NSImage?, Never>] = [:]
    @ObservationIgnored private var generation = 0

    init() {
        thumbnails.countLimit = 600
        thumbnails.totalCostLimit = 96 * 1024 * 1024
        previews.countLimit = 3
    }

    /// 走査し直す。遅れて返った古い走査の結果は捨てる。
    func reload(projectPath: String) {
        generation += 1
        let current = generation
        scanning = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { ProjectImages.scan(projectPath: projectPath) }.value
            guard generation == current else { return }
            scan = result
            scanning = false
        }
    }

    /// 同じファイルでも更新されていれば別の絵として読み直す。
    func key(_ image: ProjectImage) -> String {
        "\(image.path)|\(image.modified?.timeIntervalSince1970 ?? 0)|\(image.fileSize)"
    }

    func cachedThumbnail(_ image: ProjectImage) -> NSImage? {
        thumbnails.object(forKey: "\(key(image))|\(Self.thumbnailPixels)" as NSString)
    }

    func thumbnail(_ image: ProjectImage) async -> NSImage? {
        await load(image, maxPixels: Self.thumbnailPixels, cache: thumbnails)
    }

    func preview(_ image: ProjectImage) async -> NSImage? {
        await load(image, maxPixels: Self.previewPixels, cache: previews)
    }

    private func load(_ image: ProjectImage, maxPixels: Int, cache: NSCache<NSString, NSImage>) async -> NSImage? {
        let baseKey = key(image)
        let cacheKey = "\(baseKey)|\(maxPixels)"
        if let cached = cache.object(forKey: cacheKey as NSString) { return cached }
        // 同じ画像を複数の枠・再描画から同時に頼まれても 1 回だけ読む。
        if let running = inFlight[cacheKey] { return await running.value }
        let path = image.path
        let task = Task<NSImage?, Never> {
            let decoded = await Task.detached(priority: .userInitiated) { Self.decode(path: path, maxPixels: maxPixels) }.value
            guard let decoded else { return nil }
            if let size = decoded.pixelSize { dimensions[baseKey] = size }
            return NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
        }
        inFlight[cacheKey] = task
        let result = await task.value
        inFlight[cacheKey] = nil
        if let result {
            cache.setObject(result, forKey: cacheKey as NSString, cost: Int(result.size.width * result.size.height * 4))
        }
        return result
    }

    nonisolated private static func decode(path: String, maxPixels: Int) -> DecodedImage? {
        let url = URL(fileURLWithPath: path)
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return DecodedImage(image: thumbnail, pixelSize: pixelSize(of: source))
            }
        }
        // SVG 等 ImageIO が読めないものは NSImage で描く（寸法は出さない）。
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        return rasterize(image, maxPixels: min(maxPixels, rasterPixels)).map { DecodedImage(image: $0, pixelSize: nil) }
    }

    /// 回転の向きを反映した原寸のピクセル寸法。
    nonisolated private static func pixelSize(of source: CGImageSource) -> PixelSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height)
    }

    nonisolated private static func rasterize(_ image: NSImage, maxPixels: Int) -> CGImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = CGFloat(maxPixels) / max(size.width, size.height)
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}

private struct DecodedImage: @unchecked Sendable {
    let image: CGImage
    let pixelSize: ProjectImageStore.PixelSize?
}
