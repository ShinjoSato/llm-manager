import AppKit
import ImageIO

/// ImageIO の縮小読み込み（吹き出しの画像・詳細の画像で共通）。
enum ImageDecoding {
    /// 長辺を `maxPixels` に縮めた絵（回転の向きを反映）。読めなければ nil。
    static func thumbnail(of source: CGImageSource, at index: Int = 0, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }
}

extension NSImage {
    /// 画素数をそのままポイントの大きさにした絵。
    convenience init(pixelSized image: CGImage) {
        self.init(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// 縮小した絵をバックグラウンドから渡す包み（作った後は変えない）。
struct DecodedCGImage: @unchecked Sendable {
    let image: CGImage
}
