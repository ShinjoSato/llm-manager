import XCTest
@testable import DeckCore

final class ChatImageTimelineTests: XCTestCase {
    private func user(_ id: String, _ text: String, at: Double?, images: Int = 0) -> TranscriptItem {
        TestItem.user(id, text, at: at, images: images)
    }

    private func assistant(_ id: String, at: Double?) -> TranscriptItem { TestItem.assistant(id, at: at) }

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

    func testRecordedOnlyWhenTextAndImageCountMatch() {
        let message = PendingImageMessage(id: "m", text: "見て", sentBody: "見て\n\n添付:\n/docs/b.pdf",
                                          imagePaths: ["/c/a.png", "/c/b.png"], sentAt: 100_000)
        // ターミナルから直接送った別の画像付きの発話では消し込まない。
        let other = user("u:0", "[Image #1] 別の話\n[画像]", at: 101_000, images: 1)
        let otherSameCount = user("u:1", "[Image #1] [Image #2] 別の話\n[画像]\n[画像]", at: 101_500, images: 2)
        let fewer = user("u:2", "[Image #1] 見て\n\n添付:\n/docs/b.pdf\n[画像]", at: 102_000, images: 1)
        XCTAssertEqual(PendingImageMessages.unrecorded([message], in: [other, otherSameCount, fewer]), [message])
        // 印・空白の違いは無視して本文と枚数で合わせる。
        let record = user("u:3", "[Image #1] [Image #2] 見て\n\n添付:\n/docs/b.pdf\n[画像]\n[画像]", at: 103_000, images: 2)
        XCTAssertTrue(PendingImageMessages.isRecorded(record, of: message))
        XCTAssertEqual(PendingImageMessages.unrecorded([message], in: [other, record]), [])
        // 少し前（時計のずれ）は許し、それより前の発話は記録とみなさない。
        var early = record
        early.at = 96_000
        XCTAssertTrue(PendingImageMessages.isRecorded(early, of: message))
        early.at = 90_000
        XCTAssertFalse(PendingImageMessages.isRecorded(early, of: message))
    }

    func testOutgoingExpiresWhenNeverRecorded() {
        let message = PendingImageMessage(id: "m", text: "見て", imagePaths: ["/c/a.png"], sentAt: 100_000)
        let justBefore = 100_000 + PendingImageMessages.lifetime - 1
        XCTAssertEqual(PendingImageMessages.unrecorded([message], in: [], now: justBefore), [message])
        XCTAssertFalse(PendingImageMessages.isExpired(message, now: justBefore))
        XCTAssertEqual(PendingImageMessages.unrecorded([message], in: [], now: 100_000 + PendingImageMessages.lifetime), [])
        XCTAssertTrue(PendingImageMessages.isExpired(message, now: 100_000 + PendingImageMessages.lifetime))
    }

    func testRelayNoteCarriesImages() {
        let note = RelayNote(id: "n", text: "添付:\n/c/a.png", sentAt: 5, state: .sent, imagePaths: ["/c/a.png"])
        let entries = ChatTimeline.entries(from: [], notes: [note])
        XCTAssertEqual(entries.first?.images, [.file("/c/a.png")])
    }
}
