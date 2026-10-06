import AppKit
import UniformTypeIdentifiers
import MonitorKit

/// SwiftUI のドロップ（入力欄の枠全体）から添付を拾う。
enum AttachmentDrop {
    /// ファイルと、画像のデータ表現（JPEG / HEIC / TIFF 等。ブラウザや写真からのドラッグ）。ファイルプロミスは受けない。
    static let types: [UTType] = [.fileURL, .image]

    /// 読み込みは非同期なので、揃ったらメインで `completion` に渡す。受け取れるものが無ければ false。
    /// 画像のデータは元の形式のまま渡し、変換は取り込み（バックグラウンド）に任せる。
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([AttachmentSource]) -> Void) -> Bool {
        let usable = providers.filter { provider in types.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) } }
        guard !usable.isEmpty else { return false }
        let collector = DropCollector(count: usable.count)
        for (index, provider) in usable.enumerated() {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    collector.set(index, url.map { .file($0) }, completion: completion)
                }
            } else if let type = imageType(of: provider) {
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    collector.set(index, data.map { .imageData($0, name: "ドロップした画像") }, completion: completion)
                }
            } else {
                collector.set(index, nil, completion: completion)
            }
        }
        return true
    }

    /// 載っている画像の型。PNG を優先し、無ければ最初の画像の型。
    private static func imageType(of provider: NSItemProvider) -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) { return UTType.png.identifier }
        return provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
    }
}

/// ドロップの各項目の読み込み結果を並び順のまま集める。
private final class DropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [AttachmentSource?]
    private var remaining: Int

    init(count: Int) {
        results = Array(repeating: nil, count: count)
        remaining = count
    }

    func set(_ index: Int, _ source: AttachmentSource?, completion: @escaping @MainActor ([AttachmentSource]) -> Void) {
        lock.lock()
        results[index] = source
        remaining -= 1
        let done = remaining == 0 ? results.compactMap { $0 } : nil
        lock.unlock()
        guard let done, !done.isEmpty else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(done) } }
    }
}
