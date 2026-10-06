import AppKit
import XCTest
@testable import MonitorKit

/// ⌘V の経路。実クリップボードは読み書きせず、専用のペーストボードを差し込んで確かめる。
@MainActor
final class AttachmentPasteTextViewTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var view: AttachmentPasteTextView!
    private var attached: [[AttachmentSource]] = []

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("claude-deck-paste-\(UUID().uuidString)"))
        pasteboard.clearContents()
        view = AttachmentPasteTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        // 入力欄（SubmitTextView）と同じ文字専用の設定。
        view.isRichText = false
        view.importsGraphics = false
        view.pasteSource = pasteboard
        attached = []
        view.onAttach = { [weak self] in self?.attached.append($0) }
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    private func pasteItem() -> NSMenuItem {
        NSMenuItem(title: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    }

    /// 原因の裏付け: 文字専用の NSTextView が読める型には画像が無いので、画像だけのクリップボードではペーストが無効になる。
    func testPlainTextViewCannotReadImageOnlyPasteboard() {
        let plain = NSTextView(frame: .zero)
        plain.isRichText = false
        plain.importsGraphics = false
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(testPNGData(), forType: .png)
        XCTAssertNil(pasteboard.availableType(from: plain.readablePasteboardTypes))
    }

    func testScreenshotEnablesPasteAndAttaches() {
        let png = testPNGData()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        XCTAssertTrue(view.validateMenuItem(pasteItem()))
        XCTAssertTrue(view.validateUserInterfaceItem(pasteItem()))
        view.paste(nil)
        XCTAssertEqual(attached, [[.imageData(png, name: "貼り付けた画像")]])
        XCTAssertEqual(view.string, "")
    }

    func testTIFFOnlyIsAttached() throws {
        let tiff = try XCTUnwrap(NSImage(data: testPNGData())?.tiffRepresentation)
        pasteboard.setData(tiff, forType: .tiff)
        XCTAssertTrue(view.validateMenuItem(pasteItem()))
        view.paste(nil)
        XCTAssertEqual(attached.count, 1)
    }

    func testPasteAsPlainTextAlsoAttaches() {
        pasteboard.setData(testPNGData(), forType: .png)
        let item = NSMenuItem(title: "", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "")
        XCTAssertTrue(view.validateMenuItem(item))
        view.pasteAsPlainText(nil)
        XCTAssertEqual(attached.count, 1)
    }

    func testFinderFilesAreAttached() {
        let url = URL(fileURLWithPath: "/tmp/スクリーンショット 1.png")
        pasteboard.writeObjects([url as NSURL])
        XCTAssertTrue(view.canAttachPaste)
        view.paste(nil)
        XCTAssertEqual(attached, [[.file(url)]])
    }

    func testTextIsNotTakenOver() {
        pasteboard.setString("hello", forType: .string)
        XCTAssertFalse(view.canAttachPaste)
        XCTAssertFalse(view.attachPaste())
        XCTAssertEqual(attached.count, 0)
    }

    func testDisabledFieldDoesNotAttach() {
        pasteboard.setData(testPNGData(), forType: .png)
        view.isEditable = false
        XCTAssertFalse(view.canAttachPaste)
        XCTAssertFalse(view.attachPaste())
        XCTAssertEqual(attached.count, 0)
    }

    func testWithoutHandlerItIsNotEnabled() {
        pasteboard.setData(testPNGData(), forType: .png)
        view.onAttach = nil
        XCTAssertFalse(view.canAttachPaste)
        XCTAssertFalse(view.attachPaste())
    }
}

final class OutgoingImageMessageTests: XCTestCase {
    func testImagesSentAsPathsShowNoOutgoingBubble() {
        // パスとして本文に回った画像は記録に画像が付かないので、仮の吹き出しを出さない。
        let m = AttachmentFormat.outgoing(text: "見て", attachments: [
            Attachment(kind: .image, path: "/a /b.png", name: "b.png", sourcePath: nil),
        ], pasteImages: true)
        XCTAssertNil(PendingImageMessages.outgoing(text: "見て", sentBody: m.body, pastedImagePaths: m.imagePaths, sentAt: 1))
        let pasted = PendingImageMessages.outgoing(id: "m", text: " 見て ", sentBody: "見て",
                                                   pastedImagePaths: ["/c/a.png"], sentAt: 1)
        XCTAssertEqual(pasted?.text, "見て")
        XCTAssertEqual(pasted?.imagePaths, ["/c/a.png"])
    }
}
