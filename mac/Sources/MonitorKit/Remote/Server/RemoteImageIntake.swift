import Foundation
import ImageIO
import UniformTypeIdentifiers

/// iPhone から届いた画像の検証と一時保存（保存先・形は mac の入力欄の添付と同じ `AttachmentStore`）。
public enum RemoteImageIntake {
    static let unreadable = RemoteActionResult.failure("unsupported_image", "画像として読めませんでした（壊れているか、途中で切れています）。")
    static let saveFailed = RemoteActionResult.failure("failed", "mac で画像を一時保存できませんでした。")

    /// ImageIO で読めて、宣言した型のとおりで、寸法が上限内か。通れば nil。
    public static func problem(_ image: RemoteMessageImage) -> RemoteActionResult? {
        if let problem = RemoteImageLimits.problem([image]) { return problem }
        // ImageIO は途中で切れた画像も読めたことにするので、終わりの印を先に見る。
        guard hasEndMarker(image.data, mediaType: image.mediaType) else { return unreadable }
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(image.data as CFData, noCache),
              CGImageSourceGetCount(source) >= 1,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier),
              let expected = expectedType(image.mediaType), type.conforms(to: expected),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return unreadable }
        guard width <= RemoteImageLimits.maxPixelSide, height <= RemoteImageLimits.maxPixelSide,
              width * height <= RemoteImageLimits.maxPixels else { return RemoteImageLimits.tooLarge }
        // 見出しだけ正しい壊れた画像を端末に渡さないよう、小さく描けるところまで確かめる。
        let thumbnail = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64,
                         kCGImageSourceShouldCache: false] as CFDictionary
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail) != nil else { return unreadable }
        return nil
    }

    /// PNG は最後が IEND のチャンク、JPEG は終わりの近くに EOI（FFD9）がある（後ろに付け足しのある JPEG を断らないため）。
    static func hasEndMarker(_ data: Data, mediaType: String) -> Bool {
        switch mediaType.lowercased() {
        case "image/png":
            return data.suffix(12).elementsEqual([0, 0, 0, 0, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82])
        case "image/jpeg":
            let tail = [UInt8](data.suffix(64 * 1024))
            return tail.count >= 2 && zip(tail, tail.dropFirst()).contains { $0 == 0xff && $1 == 0xd9 }
        default:
            return false
        }
    }

    static func expectedType(_ mediaType: String) -> UTType? {
        switch mediaType.lowercased() {
        case "image/png": return .png
        case "image/jpeg": return .jpeg
        default: return nil
        }
    }

    /// 全部を検証してから書く。途中で失敗したら書いた分を消す。重いので画面のスレッドから呼ばない。
    public static func store(_ images: [RemoteMessageImage], in store: AttachmentStore) -> Result<[Attachment], RemoteActionResult> {
        if let problem = RemoteImageLimits.problem(images) { return .failure(problem) }
        for image in images {
            if let problem = problem(image) { return .failure(problem) }
        }
        var stored: [Attachment] = []
        for (index, image) in images.enumerated() {
            do {
                stored.append(try store.ingest(.imageData(image.data, name: "iPhone の画像 \(index + 1)")))
            } catch {
                stored.forEach(store.discard)
                return .failure(saveFailed)
            }
        }
        return .success(stored)
    }
}
