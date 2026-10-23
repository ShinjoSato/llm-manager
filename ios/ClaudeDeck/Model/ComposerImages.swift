import DeckCore
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// 入力欄に添えた画像 1 枚（送る形に整えたものと、並べて見せる縮小画像）。
struct ComposerImage: Identifiable, Equatable {
    let id = UUID()
    let payload: RemoteMessageImage
    let thumbnail: UIImage

    static func == (a: ComposerImage, b: ComposerImage) -> Bool { a.id == b.id }
}

/// 写真を送れる形（PNG / JPEG・上限内）に整える。重いので画面のスレッドから呼ばない。
enum ComposerImagePreparer {
    struct Prepared: Sendable {
        let payload: RemoteMessageImage
        let thumbnail: Data
    }

    /// 縮めすぎて読めなくなる手前で諦める長辺。
    static let minimumLongEdge = 320
    static let jpegQualities: [Double] = [0.8, 0.65, 0.5]
    static let thumbnailEdge = 160

    /// 長辺を `longEdge` までに縮め、向きを反映し、位置情報などのメタデータを落として書き直す。
    /// PNG（スクリーンショット等）は収まれば PNG のまま、それ以外（HEIC を含む）と収まらない PNG は JPEG にする。
    static func prepare(_ data: Data, budget: Int = RemoteImageLimits.budgetBytes,
                        longEdge: Int = RemoteImageLimits.preferredLongEdge) -> Prepared? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let isPNG = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }?.conforms(to: .png) == true
        var edge = min(max(width, height), longEdge, RemoteImageLimits.maxPixelSide)
        while true {
            guard let image = render(source, longEdge: edge) else { return nil }
            if let encoded = encode(image, isPNG: isPNG, budget: budget), let thumbnail = thumbnailData(encoded.data) {
                return Prepared(payload: encoded, thumbnail: thumbnail)
            }
            let next = edge * 3 / 4
            guard next >= minimumLongEdge, next < edge else { return nil }
            edge = next
        }
    }

    private static func encode(_ image: CGImage, isPNG: Bool, budget: Int) -> RemoteMessageImage? {
        if isPNG, let png = write(image, type: .png, quality: nil), png.count <= budget {
            return RemoteMessageImage(mediaType: "image/png", data: png)
        }
        let opaque = flattened(image) ?? image
        for quality in jpegQualities {
            if let jpeg = write(opaque, type: .jpeg, quality: quality), jpeg.count <= budget {
                return RemoteMessageImage(mediaType: "image/jpeg", data: jpeg)
            }
        }
        return nil
    }

    /// 向き（EXIF の Orientation）を反映した、長辺 `longEdge` 以下の画像。
    private static func render(_ source: CGImageSource, longEdge: Int) -> CGImage? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: longEdge, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    /// JPEG は透明を持てない（黒くなる）ので白の上に描く。
    private static func flattened(_ image: CGImage) -> CGImage? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(UIColor.white.cgColor)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// メタデータは付けずに書く。
    private static func write(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func thumbnailData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = render(source, longEdge: thumbnailEdge) else {
            return nil
        }
        return write(flattened(image) ?? image, type: .jpeg, quality: 0.8)
    }
}
