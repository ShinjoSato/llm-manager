import AppKit
import XCTest
@testable import MonitorKit

final class AttachmentFormatTests: XCTestCase {
    private func image(_ path: String) -> Attachment { Attachment(kind: .image, path: path, name: "i", sourcePath: nil) }
    private func file(_ path: String) -> Attachment { Attachment(kind: .file, path: path, name: "f", sourcePath: path) }

    /// Claude Code v2.1.286 の貼り付け処理の写し（空白 + / と改行で割り、引用符を外し、`\x` を戻して拡張子を見る）。
    private func tuiImagePaths(_ pasted: String) -> [String] {
        let pieces = pasted.components(separatedBy: " /").enumerated()
            .map { $0.offset == 0 ? $0.element : "/" + $0.element }
            .flatMap { $0.components(separatedBy: "\n") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return pieces.compactMap { piece in
            var s = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) { s = String(s.dropFirst().dropLast()) }
            var out = ""
            var escaped = false
            for c in s {
                if escaped { out.append(c); escaped = false } else if c == "\\" { escaped = true } else { out.append(c) }
            }
            return out.range(of: #"\.(png|jpe?g|gif|webp)$"#, options: [.regularExpression, .caseInsensitive]) != nil ? out : nil
        }
    }

    func testTextOnlyIsUnchanged() {
        let m = AttachmentFormat.outgoing(text: "  こんにちは\n2 行目 ", attachments: [], pasteImages: true)
        XCTAssertNil(m.imagePaste)
        XCTAssertEqual(m.imageCount, 0)
        XCTAssertEqual(m.body, "こんにちは\n2 行目")
    }

    func testImagesArePastedSeparatelyAndFilesListed() {
        let m = AttachmentFormat.outgoing(text: "見て", attachments: [
            image("/c/a.png"), file("/docs/b.pdf"), image("/c/d.jpg"),
        ], pasteImages: true)
        XCTAssertEqual(m.imagePaste, "/c/a.png /c/d.jpg")
        XCTAssertEqual(m.imageCount, 2)
        XCTAssertEqual(m.body, "見て\n\n添付:\n/docs/b.pdf")
        XCTAssertEqual(tuiImagePaths(m.imagePaste!), ["/c/a.png", "/c/d.jpg"])
    }

    func testAttachmentsOnlyCanBeSent() {
        let m = AttachmentFormat.outgoing(text: "  ", attachments: [image("/c/a.png")], pasteImages: true)
        XCTAssertEqual(m.body, "")
        XCTAssertFalse(m.isEmpty)
        XCTAssertTrue(AttachmentFormat.outgoing(text: " ", attachments: [], pasteImages: true).isEmpty)
    }

    func testWithoutPasteEverythingIsListed() {
        let m = AttachmentFormat.outgoing(text: "伝言", attachments: [image("/c/a.png"), file("/My Docs/b.txt")], pasteImages: false)
        XCTAssertNil(m.imagePaste)
        XCTAssertEqual(m.body, "伝言\n\n添付:\n/c/a.png\n\"/My Docs/b.txt\"")
    }

    func testPasteTokenEscapesSpacesAndRoundTrips() {
        let path = "/Users/a b/It's \"x\".png"
        let token = AttachmentFormat.pasteToken(path)
        XCTAssertEqual(token, "/Users/a\\ b/It\\'s\\ \\\"x\\\".png")
        XCTAssertEqual(tuiImagePaths(token!), [path])
    }

    func testUnsafePathsAreListedInstead() {
        XCTAssertNil(AttachmentFormat.pasteToken("/a /b.png"))   // 空白 + / で割られる
        XCTAssertNil(AttachmentFormat.pasteToken("/a\\b.png"))
        XCTAssertNil(AttachmentFormat.pasteToken("rel/b.png"))
        XCTAssertNil(AttachmentFormat.pasteToken("/a/b.heic"))
        XCTAssertNil(AttachmentFormat.pasteToken("/a/b\n.png"))
        XCTAssertNotNil(AttachmentFormat.pasteToken("/a/B.JPEG"))
        let m = AttachmentFormat.outgoing(text: "", attachments: [image("/a /b.png")], pasteImages: true)
        XCTAssertNil(m.imagePaste)
        XCTAssertEqual(m.body, "添付:\n\"/a /b.png\"")
    }

    func testQuotedEscapesQuotes() {
        XCTAssertEqual(AttachmentFormat.quoted("/a/b.txt"), "/a/b.txt")
        XCTAssertEqual(AttachmentFormat.quoted("/a/\"b\" c.txt"), "\"/a/\\\"b\\\" c.txt\"")
    }

    func testImageTokenCount() {
        XCTAssertEqual(AttachmentFormat.imageTokenCount(in: ""), 0)
        XCTAssertEqual(AttachmentFormat.imageTokenCount(in: "[Image #1] [Image #2] 本文"), 2)
        XCTAssertEqual(AttachmentFormat.imageTokenCount(in: "[Pasted text #1]"), 0)
    }
}

@MainActor
final class AttachmentPasteboardTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("claude-deck-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    private func pngData() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testFileURLsBecomeFiles() {
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b c.txt")]
        pasteboard.writeObjects(urls as [NSURL])
        XCTAssertTrue(AttachmentPasteboard.canAttach(pasteboard))
        XCTAssertEqual(AttachmentPasteboard.sources(in: pasteboard), urls.map { .file($0) })
    }

    func testPlainTextStaysText() {
        pasteboard.setString("hello", forType: .string)
        XCTAssertFalse(AttachmentPasteboard.canAttach(pasteboard))
        XCTAssertEqual(AttachmentPasteboard.sources(in: pasteboard), [])
    }

    func testTextWithImageStaysText() {
        pasteboard.declareTypes([.string, .png], owner: nil)
        pasteboard.setString("hello", forType: .string)
        pasteboard.setData(pngData(), forType: .png)
        XCTAssertFalse(AttachmentPasteboard.canAttach(pasteboard))
        XCTAssertEqual(AttachmentPasteboard.sources(in: pasteboard), [])
    }

    func testScreenshotPNG() {
        let png = pngData()
        pasteboard.setData(png, forType: .png)
        XCTAssertTrue(AttachmentPasteboard.canAttach(pasteboard))
        XCTAssertEqual(AttachmentPasteboard.sources(in: pasteboard, imageName: "x.png"), [.imageData(png, name: "x.png")])
    }

    func testTIFFIsConvertedToPNG() throws {
        let tiff = try XCTUnwrap(NSImage(data: pngData())?.tiffRepresentation)
        pasteboard.setData(tiff, forType: .tiff)
        guard case .imageData(let data, _)? = AttachmentPasteboard.sources(in: pasteboard).first else { return XCTFail("画像になっていない") }
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}

final class AttachmentStoreTests: XCTestCase {
    private var root: URL!
    private var store: AttachmentStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = AttachmentStore(directory: root.appendingPathComponent("cache/attachments"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func permissions(_ path: String) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }

    private func pngData() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testClipboardImageIsSavedPrivately() throws {
        let attachment = try store.ingest(.imageData(pngData(), name: "貼り付けた画像.png"))
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertNil(attachment.sourcePath)
        XCTAssertTrue(attachment.path.hasSuffix(".png"))
        XCTAssertTrue(store.contains(attachment.path))
        XCTAssertEqual(try permissions(attachment.path), 0o600)
        XCTAssertEqual(try permissions(store.directory.path), 0o700)
        XCTAssertNotNil(AttachmentFormat.pasteToken(attachment.path))
    }

    func testImageFileIsCopiedAndOtherFilesKeepTheirPath() throws {
        let original = root.appendingPathComponent("スクリーン ショット.PNG")
        try pngData().write(to: original)
        let image = try store.ingest(.file(original))
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(image.name, "スクリーン ショット.PNG")
        XCTAssertEqual(image.sourcePath, original.path)
        XCTAssertTrue(store.contains(image.path))
        XCTAssertTrue(image.path.hasSuffix(".png"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: image.path)), try Data(contentsOf: original))

        let text = root.appendingPathComponent("memo.txt")
        try Data("x".utf8).write(to: text)
        let file = try store.ingest(.file(text))
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(file.path, text.path)
    }

    func testConvertibleImageBecomesPNG() throws {
        let tiffURL = root.appendingPathComponent("a.tiff")
        try XCTUnwrap(NSImage(data: pngData())?.tiffRepresentation).write(to: tiffURL)
        let attachment = try store.ingest(.file(tiffURL))
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertTrue(attachment.path.hasSuffix(".png"))
        XCTAssertEqual(Array(try Data(contentsOf: URL(fileURLWithPath: attachment.path)).prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try store.ingest(.file(root.appendingPathComponent("none.png"))))
    }

    func testDiscardOnlyTouchesCache() throws {
        let cached = try store.ingest(.imageData(pngData(), name: "a.png"))
        let outside = root.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: outside)
        let file = try store.ingest(.file(outside))
        store.discard(cached)
        store.discard(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testSweepRemovesOnlyOldFiles() throws {
        let old = try store.ingest(.imageData(pngData(), name: "old.png"))
        let fresh = try store.ingest(.imageData(pngData(), name: "new.png"))
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: old.path)
        XCTAssertEqual(store.sweep(now: now), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testSweepWithoutDirectoryIsNoop() {
        XCTAssertEqual(AttachmentStore(directory: root.appendingPathComponent("missing")).sweep(), 0)
    }
}
