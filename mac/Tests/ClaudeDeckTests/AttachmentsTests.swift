import AppKit
import UniformTypeIdentifiers
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
        XCTAssertEqual(m.imagePaths, ["/c/a.png", "/c/d.jpg"])
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
        XCTAssertEqual(m.imagePaths, [])
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

    func testImageTokenCountAcrossWrappedLines() {
        // 折り返しで印が割れた入力欄（InputBox.text は行ごとに詰めて改行でつなぐ）。
        let screen = [
            "────────────────────",
            "❯ [Image #1] [Image",
            "  #2] [Ima",
            "  ge #3]",
            "────────────────────",
        ]
        XCTAssertEqual(InputBox.text(screen: screen).map(AttachmentFormat.imageTokenCount), 3)
        XCTAssertEqual(AttachmentFormat.imageTokenCount(in: "[Image\n#2]"), 1)
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
        pasteboard.setData(testPNGData(), forType: .png)
        XCTAssertFalse(AttachmentPasteboard.canAttach(pasteboard))
        XCTAssertEqual(AttachmentPasteboard.sources(in: pasteboard), [])
    }

    func testScreenshotPNG() {
        let png = testPNGData()
        pasteboard.setData(png, forType: .png)
        XCTAssertTrue(AttachmentPasteboard.canAttach(pasteboard))
        XCTAssertEqual(AttachmentPasteboard.sources(in: pasteboard, imageName: "x.png"), [.imageData(png, name: "x.png")])
    }

    func testTIFFIsPassedAsIsForBackgroundConversion() throws {
        let tiff = try XCTUnwrap(NSImage(data: testPNGData())?.tiffRepresentation)
        pasteboard.setData(tiff, forType: .tiff)
        XCTAssertTrue(AttachmentPasteboard.canAttach(pasteboard))
        XCTAssertEqual(AttachmentPasteboard.sources(in: pasteboard, imageName: "x"), [.imageData(tiff, name: "x")])
    }

    func testJPEGOnlyIsAttached() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: testPNGData()))
        let jpeg = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
        let type = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        pasteboard.setData(jpeg, forType: type)
        XCTAssertTrue(AttachmentPasteboard.canAttach(pasteboard))
        XCTAssertEqual(AttachmentPasteboard.sources(in: pasteboard, imageName: "x"), [.imageData(jpeg, name: "x")])
    }

    func testImageTypesIncludeCommonFormats() {
        let types = Set(AttachmentPasteboard.imageTypes.map(\.rawValue))
        XCTAssertTrue(types.isSuperset(of: [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier]))
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

    func testClipboardImageIsSavedPrivately() throws {
        let attachment = try store.ingest(.imageData(testPNGData(), name: "貼り付けた画像.png"))
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
        try testPNGData().write(to: original)
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
        try XCTUnwrap(NSImage(data: testPNGData())?.tiffRepresentation).write(to: tiffURL)
        let attachment = try store.ingest(.file(tiffURL))
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertTrue(attachment.path.hasSuffix(".png"))
        XCTAssertEqual(Array(try Data(contentsOf: URL(fileURLWithPath: attachment.path)).prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testCopiedImageIsPrivateEvenIfOriginalIsNot() throws {
        let original = root.appendingPathComponent("a.jpeg")
        try testPNGData().write(to: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: original.path)
        let image = try store.ingest(.file(original))
        XCTAssertTrue(image.path.hasSuffix(".jpg"))
        XCTAssertEqual(try permissions(image.path), 0o600)
    }

    func testImageDataKeepsPasteableFormatAndConvertsOthers() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: testPNGData()))
        let jpeg = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
        let kept = try store.ingest(.imageData(jpeg, name: "j"))
        XCTAssertTrue(kept.path.hasSuffix(".jpg"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: kept.path)), jpeg)

        let tiff = try XCTUnwrap(rep.representation(using: .tiff, properties: [:]))
        let converted = try store.ingest(.imageData(tiff, name: "t"))
        XCTAssertTrue(converted.path.hasSuffix(".png"))
        XCTAssertEqual(Array(try Data(contentsOf: URL(fileURLWithPath: converted.path)).prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertNotNil(AttachmentStore.thumbnail(of: converted.path))
    }

    func testUnreadableImageDataThrows() {
        XCTAssertThrowsError(try store.ingest(.imageData(Data("not an image".utf8), name: "x"))) { error in
            XCTAssertEqual(error as? AttachmentStore.StoreError, .unreadable("x"))
        }
    }

    func testTooLargeImagesAreRefused() throws {
        let big = Data(count: AttachmentStore.maxImageBytes + 1)
        XCTAssertThrowsError(try store.ingest(.imageData(big, name: "big"))) { error in
            XCTAssertEqual(error as? AttachmentStore.StoreError, .tooLarge("big", bytes: AttachmentStore.maxImageBytes + 1))
        }
        let file = root.appendingPathComponent("big.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(AttachmentStore.maxImageBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try store.ingest(.file(file)))
        // 画像以外は写さないので大きさを問わない。
        let text = root.appendingPathComponent("big.log")
        try FileManager.default.copyItem(at: file, to: text)
        XCTAssertEqual(try store.ingest(.file(text)).kind, .file)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path))?.count ?? 0, 0)
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try store.ingest(.file(root.appendingPathComponent("none.png"))))
    }

    func testDiscardOnlyTouchesCache() throws {
        let cached = try store.ingest(.imageData(testPNGData(), name: "a.png"))
        let outside = root.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: outside)
        let file = try store.ingest(.file(outside))
        store.discard(cached)
        store.discard(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testSweepRemovesOnlyOldFiles() throws {
        let old = try store.ingest(.imageData(testPNGData(), name: "old.png"))
        let fresh = try store.ingest(.imageData(testPNGData(), name: "new.png"))
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

final class SendCompletionTests: XCTestCase {
    private func file(_ path: String) -> Attachment { Attachment(kind: .file, path: path, name: "f", sourcePath: path) }

    func testOnlyAbortBeforeBodyRestoresDraft() {
        XCTAssertTrue(SendCompletion.abortedBeforeBody(.menu).restoresDraft)
        XCTAssertFalse(SendCompletion.abortedAfterBody(.menu).restoresDraft)
        XCTAssertFalse(SendCompletion.submitted.restoresDraft)
        XCTAssertFalse(SendCompletion.ended.restoresDraft)
    }

    func testNoticeTellsWhatIsLeftInTheTerminal() throws {
        let before = try XCTUnwrap(SendCompletion.abortedBeforeBody(.permission).notice)
        XCTAssertTrue(before.contains("本文を貼る前に"))
        XCTAssertTrue(before.contains("画像（[Image #N]）だけが残っています"))
        XCTAssertTrue(before.contains("入力欄に戻しました"))
        XCTAssertTrue(before.contains("権限の確認"))
        XCTAssertFalse(before.contains("本文が残っています"))

        let after = try XCTUnwrap(SendCompletion.abortedAfterBody(.menu).notice)
        XCTAssertTrue(after.contains("本文を貼った後"))
        XCTAssertTrue(after.contains("本文が残っています"))
        XCTAssertTrue(after.contains("選択肢"))
        XCTAssertFalse(after.contains("戻しました"))

        XCTAssertNil(SendCompletion.submitted.notice)
        XCTAssertNil(SendCompletion.ended.notice)
    }

    func testRemoteNoticeDoesNotMentionTheMacComposer() throws {
        let before = try XCTUnwrap(SendCompletion.abortedBeforeBody(.permission).remoteNotice)
        XCTAssertEqual(before, "送信の途中で権限の確認が出たため、本文を貼る前に取りやめました。")
        let after = try XCTUnwrap(SendCompletion.abortedAfterBody(.menu).remoteNotice)
        XCTAssertTrue(after.contains("本文が残っています"))
        XCTAssertFalse(after.contains("戻しました"))
        XCTAssertNil(SendCompletion.submitted.remoteNotice)
        XCTAssertEqual(SendCompletion.ended.remoteNotice, "claude が終了したため送れませんでした。")
    }

    func testRestoredDraftComesBeforeNewText() {
        XCTAssertEqual(ComposerRestore.draft(restoring: "送った文", current: ""), "送った文")
        XCTAssertEqual(ComposerRestore.draft(restoring: "送った文", current: "  \n"), "送った文")
        XCTAssertEqual(ComposerRestore.draft(restoring: "送った文", current: "書き足し"), "送った文\n書き足し")
        XCTAssertEqual(ComposerRestore.draft(restoring: " ", current: "書き足し"), "書き足し")
    }

    func testRestoredAttachmentsDropDuplicatesAddedMeanwhile() {
        let sent = [file("/a.txt"), Attachment(kind: .image, path: "/c/1.png", name: "i", sourcePath: nil)]
        let again = file("/a.txt")
        let other = file("/b.txt")
        let result = ComposerRestore.attachments(restoring: sent, current: [again, other])
        XCTAssertEqual(result.merged.map(\.id), sent.map(\.id) + [other.id])
        XCTAssertEqual(result.dropped.map(\.id), [again.id])
    }
}
