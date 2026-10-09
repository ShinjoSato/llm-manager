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
    nonisolated private static let rasterPixels = 1200
    /// 同時にデコードする枚数（枠が一斉に表示されても CPU とメモリを食いすぎないため）。
    private static let decodeLimit = 4

    struct PixelSize: Equatable {
        let width: Int
        let height: Int
    }

    /// 読み込んだ絵と、読めた時の原寸のピクセル寸法（SVG 等は無い）。
    final class LoadedImage {
        let image: NSImage
        let pixelSize: PixelSize?

        init(image: NSImage, pixelSize: PixelSize?) {
            self.image = image
            self.pixelSize = pixelSize
        }
    }

    private let scanner = BackgroundScan<ProjectImageScan>()
    var scan: ProjectImageScan? { scanner.value }
    var scanning: Bool { scanner.scanning }
    var reloadToken: Int {
        get { scanner.reloadToken }
        set { scanner.reloadToken = newValue }
    }

    // 画面の初期化のたびに作られるので、使う時まで NSCache を作らない。
    @ObservationIgnored private lazy var thumbnails: NSCache<NSString, LoadedImage> = {
        let cache = NSCache<NSString, LoadedImage>()
        cache.countLimit = 600
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    @ObservationIgnored private lazy var previews: NSCache<NSString, LoadedImage> = {
        let cache = NSCache<NSString, LoadedImage>()
        cache.countLimit = 3
        return cache
    }()
    @ObservationIgnored private lazy var gate = DecodeGate(limit: Self.decodeLimit)

    /// 前に走り切った鍵と同じなら走査しない。
    func scanIfNeeded(_ key: DetailScanKey) async {
        await scanner.scanIfNeeded(key) { ProjectImages.scan(projectPath: key.path, isCancelled: $0) }
    }

    /// 同じファイルでも更新されていれば別の絵として読み直す。
    func key(_ image: ProjectImage) -> String {
        "\(image.path)|\(image.modified?.timeIntervalSince1970 ?? 0)|\(image.fileSize)"
    }

    func cachedThumbnail(_ image: ProjectImage) -> LoadedImage? {
        thumbnails.object(forKey: cacheKey(image, maxPixels: Self.thumbnailPixels))
    }

    private func cacheKey(_ image: ProjectImage, maxPixels: Int) -> NSString {
        "\(key(image))|\(maxPixels)" as NSString
    }

    func thumbnail(_ image: ProjectImage) async -> LoadedImage? {
        await load(image, maxPixels: Self.thumbnailPixels, cache: thumbnails)
    }

    func preview(_ image: ProjectImage) async -> LoadedImage? {
        await load(image, maxPixels: Self.previewPixels, cache: previews)
    }

    private func load(_ image: ProjectImage, maxPixels: Int, cache: NSCache<NSString, LoadedImage>) async -> LoadedImage? {
        let entry = cacheKey(image, maxPixels: maxPixels)
        if let cached = cache.object(forKey: entry) { return cached }
        // 枠が画面から消えたら（取り消し）読まずに返す。
        guard await gate.acquire() else { return nil }
        if Task.isCancelled { await gate.release(); return nil }
        let path = image.path
        let decoded = await Task.detached(priority: .userInitiated) { Self.decode(path: path, maxPixels: maxPixels) }.value
        await gate.release()
        guard let decoded else { return nil }
        let loaded = LoadedImage(image: NSImage(pixelSized: decoded.image), pixelSize: decoded.pixelSize)
        cache.setObject(loaded, forKey: entry, cost: decoded.image.width * decoded.image.height * 4)
        return loaded
    }

    nonisolated private static func decode(path: String, maxPixels: Int) -> DecodedImage? {
        let url = URL(fileURLWithPath: path)
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) > 0 {
            let index = frameIndex(of: source, path: path)
            if let thumbnail = ImageDecoding.thumbnail(of: source, at: index, maxPixels: maxPixels) {
                return DecodedImage(image: thumbnail, pixelSize: pixelSize(of: source, index: index))
            }
        }
        // SVG 等 ImageIO が読めないものは NSImage で描く（寸法は出さない）。
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        return rasterize(image, maxPixels: min(maxPixels, rasterPixels)).map { DecodedImage(image: $0, pixelSize: nil) }
    }

    /// 読むフレーム。ICO は入っている大きさの中でいちばん大きいもの、HEIC 等は主画像。
    nonisolated private static func frameIndex(of source: CGImageSource, path: String) -> Int {
        guard (path as NSString).pathExtension.lowercased() == "ico" else { return CGImageSourceGetPrimaryImageIndex(source) }
        let count = CGImageSourceGetCount(source)
        return (0..<count).max { a, b in area(pixelSize(of: source, index: a)) < area(pixelSize(of: source, index: b)) } ?? 0
    }

    nonisolated private static func area(_ size: PixelSize?) -> Int {
        size.map { $0.width * $0.height } ?? 0
    }

    /// 回転の向きを反映した原寸のピクセル寸法。
    nonisolated private static func pixelSize(of source: CGImageSource, index: Int) -> PixelSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
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

/// 詳細の節の走査の鍵（タブを開いた時・「再読み込み」で走査する）。
struct DetailScanKey: Hashable {
    let path: String
    let token: Int
}

/// 節の走査をバックグラウンドで回す（「画像」と「iPhone のプレビュー」で共通）。呼び出し側の取り消しで走査を止め、遅れて返った古い結果は捨てる。
@MainActor
@Observable
final class BackgroundScan<Value: Sendable> {
    private(set) var value: Value?
    private(set) var scanning = false
    /// 「再読み込み」の回数。タブを離れて節の画面が消えても数を保ち、戻った時に走査し直さない。
    var reloadToken = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var scannedKey: DetailScanKey?

    /// 取りやめた走査は済みにせず、次にタブを開いた時にやり直す。
    func scanIfNeeded(_ key: DetailScanKey, _ work: @escaping @Sendable (_ isCancelled: () -> Bool) -> Value) async {
        guard scannedKey != key else { return }
        if await reload(work) { scannedKey = key }
    }

    /// 走り切って反映した時だけ true。
    @discardableResult
    func reload(_ work: @escaping @Sendable (_ isCancelled: () -> Bool) -> Value) async -> Bool {
        generation += 1
        let current = generation
        scanning = true
        let task = Task.detached(priority: .userInitiated) { work { Task.isCancelled } }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard generation == current else { return false }
        scanning = false
        guard !Task.isCancelled else { return false }
        value = result
        return true
    }
}

/// デコードの同時実行を絞る。枠が空くのを待っている間に取り消されれば待つのをやめる。
actor DecodeGate {
    private let limit: Int
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) {
        self.limit = limit
    }

    /// 枠を取れたら true。取り消されていれば（待つ前・待っている間とも）false。
    func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if running < limit {
            running += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// 待っている人がいればその人に枠を譲る。
    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
