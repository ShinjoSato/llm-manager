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

    private func pngData() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
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
        pasteboard.setData(pngData(), forType: .png)
        XCTAssertNil(pasteboard.availableType(from: plain.readablePasteboardTypes))
    }

    func testScreenshotEnablesPasteAndAttaches() {
        let png = pngData()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        XCTAssertTrue(view.validateMenuItem(pasteItem()))
        XCTAssertTrue(view.validateUserInterfaceItem(pasteItem()))
        view.paste(nil)
        XCTAssertEqual(attached, [[.imageData(png, name: "貼り付けた画像")]])
        XCTAssertEqual(view.string, "")
    }

    func testTIFFOnlyIsAttached() throws {
        let tiff = try XCTUnwrap(NSImage(data: pngData())?.tiffRepresentation)
        pasteboard.setData(tiff, forType: .tiff)
        XCTAssertTrue(view.validateMenuItem(pasteItem()))
        view.paste(nil)
        XCTAssertEqual(attached.count, 1)
    }

    func testPasteAsPlainTextAlsoAttaches() {
        pasteboard.setData(pngData(), forType: .png)
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
        pasteboard.setData(pngData(), forType: .png)
        view.isEditable = false
        XCTAssertFalse(view.canAttachPaste)
        XCTAssertFalse(view.attachPaste())
        XCTAssertEqual(attached.count, 0)
    }

    func testWithoutHandlerItIsNotEnabled() {
        pasteboard.setData(pngData(), forType: .png)
        view.onAttach = nil
        XCTAssertFalse(view.canAttachPaste)
        XCTAssertFalse(view.attachPaste())
    }
}

final class ChatImageTimelineTests: XCTestCase {
    private func user(_ id: String, _ text: String, at: Double?, images: Int = 0) -> TranscriptItem {
        TranscriptItem(id: id, kind: .user, at: at, text: text, tool: nil, parentId: nil,
                       images: (0..<images).map { TranscriptImage(index: $0, mediaType: "image/png") })
    }

    private func assistant(_ id: String, at: Double?) -> TranscriptItem {
        TranscriptItem(id: id, kind: .assistant, at: at, text: id, tool: nil, parentId: nil)
    }

    func testDecodesImagesAndToleratesOldMonitor() throws {
        let json = #"""
        [{"id":"u:0","kind":"user","at":1,"text":"[画像]\nこれ","tool":null,"parentId":null,"images":[{"index":0,"mediaType":"image/png"}]},
         {"id":"a:0","kind":"assistant","at":2,"text":"はい","tool":null,"parentId":null}]
        """#
        let items = try JSONDecoder().decode([TranscriptItem].self, from: Data(json.utf8))
        XCTAssertEqual(items[0].images, [TranscriptImage(index: 0, mediaType: "image/png")])
        XCTAssertEqual(items[1].images, [])
    }

    func testImagesReplacePlaceholders() {
        let entries = ChatTimeline.entries(from: [user("u:0", "[画像]\nコンフリクトしてる\n[画像]", at: 1, images: 2)])
        XCTAssertEqual(entries[0].text, "コンフリクトしてる")
        XCTAssertEqual(entries[0].images, [.transcript(itemId: "u:0", index: 0), .transcript(itemId: "u:0", index: 1)])
    }

    func testPlaceholdersStayWithoutServableImages() {
        let entries = ChatTimeline.entries(from: [user("u:0", "[画像]\nこれ", at: 1)])
        XCTAssertEqual(entries[0].text, "[画像]\nこれ")
        XCTAssertEqual(entries[0].images, [])
    }

    func testOnlyAsManyPlaceholdersAsImagesAreRemoved() {
        XCTAssertEqual(ChatImageText.removingPlaceholders("[画像]\n[画像]\nx", count: 1), "[画像]\nx")
        XCTAssertEqual(ChatImageText.removingPlaceholders("[画像]", count: 1), "")
        XCTAssertEqual(ChatImageText.removingPlaceholders("文中の [画像] は残す", count: 1), "文中の [画像] は残す")
    }

    func testOutgoingShowsUntilRecorded() {
        let message = PendingImageMessage(id: "m", text: "見て", imagePaths: ["/c/a.png"], sentAt: 10_000)
        let before = ChatTimeline.entries(from: [assistant("a:0", at: 9_000)], notes: [], pending: [message])
        XCTAssertEqual(before.map(\.id), ["a:0", "outgoing:m"])
        XCTAssertEqual(before[1].role, .outgoing)
        XCTAssertEqual(before[1].images, [.file("/c/a.png")])

        let after = ChatTimeline.entries(from: [assistant("a:0", at: 9_000), user("u:0", "[Image #1] 見て", at: 11_000, images: 1)],
                                         notes: [], pending: [message])
        XCTAssertEqual(after.map(\.id), ["a:0", "u:0"])
    }

    func testOlderImageMessagesDoNotCountAsRecorded() {
        let message = PendingImageMessage(id: "m", text: "", imagePaths: ["/c/a.png"], sentAt: 100_000)
        let items = [user("u:0", "[画像]", at: 10_000, images: 1), user("u:1", "文字だけ", at: 101_000)]
        XCTAssertEqual(PendingImageMessages.unrecorded([message], in: items), [message])
    }

    func testEachRecordMatchesOneMessage() {
        let first = PendingImageMessage(id: "1", text: "", imagePaths: ["/a"], sentAt: 10_000)
        let second = PendingImageMessage(id: "2", text: "", imagePaths: ["/b"], sentAt: 20_000)
        let items = [user("u:0", "[画像]", at: 12_000, images: 1)]
        XCTAssertEqual(PendingImageMessages.unrecorded([second, first], in: items).map(\.id), ["2"])
    }

    func testRelayNoteCarriesImages() {
        let note = RelayNote(id: "n", text: "添付:\n/c/a.png", sentAt: 5, state: .sent, imagePaths: ["/c/a.png"])
        let entries = ChatTimeline.entries(from: [], notes: [note])
        XCTAssertEqual(entries.first?.images, [.file("/c/a.png")])
    }

    func testImageURLEncodesItemId() {
        let client = MonitorClient(configuration: MonitorConfiguration(baseURL: URL(string: "http://127.0.0.1:8766")!))
        XCTAssertEqual(client.transcriptImageURL(sessionId: "s-1", itemId: "u-1:0", index: 2).absoluteString,
                       "http://127.0.0.1:8766/api/sessions/s-1/transcript/u-1%3A0/images/2")
    }
}
