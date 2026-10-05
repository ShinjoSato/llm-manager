import XCTest
@testable import DeckCore

final class RelayNotesTests: XCTestCase {
    private func user(_ id: String, _ text: String, at: Double?) -> TranscriptItem { TestItem.user(id, text, at: at) }

    private func assistant(_ id: String, at: Double?) -> TranscriptItem { TestItem.assistant(id, at: at) }

    func testNotesAreInsertedByTime() {
        let items = [user("u1", "最初", at: 1000), assistant("a1", at: 2000), user("u2", "次", at: 5000), assistant("a2", at: 6000)]
        let note = RelayNote(id: "n", text: "伝言", sentAt: 3000, state: .sent)
        let entries = ChatTimeline.entries(from: items, notes: [note])
        XCTAssertEqual(entries.map(\.id), ["u1", "a1", "relay:n", "u2", "a2"])
        XCTAssertEqual(entries[2].role, .relay)
        XCTAssertEqual(entries[2].relay?.state, .sent)
    }

    func testNoteAfterEverythingIsAppended() {
        let items = [user("u1", "最初", at: 1000), assistant("a1", at: nil)]
        let entries = ChatTimeline.entries(from: items, notes: [RelayNote(id: "n", text: "伝言", sentAt: 9000)])
        XCTAssertEqual(entries.map(\.id), ["u1", "a1", "relay:n"])
    }

    func testEchoInTranscriptIsNotShownTwice() {
        let echo = user("e", "Another Claude session sent a message:\n伝言です\n\nThis came from another Claude session — …", at: 3100)
        let items = [user("u1", "最初", at: 1000), echo, assistant("a1", at: 4000)]
        let entries = ChatTimeline.entries(from: items, notes: [RelayNote(id: "n", text: "伝言です\n", sentAt: 3000, state: .sent)])
        XCTAssertEqual(entries.map(\.id), ["u1", "relay:n", "a1"])
    }

    func testPlainEchoRightAfterSendingIsDeduplicated() {
        let items = [user("e", "伝言です", at: 3100)]
        let entries = ChatTimeline.entries(from: items, notes: [RelayNote(id: "n", text: "伝言です", sentAt: 3000, state: .sent)])
        XCTAssertEqual(entries.map(\.id), ["relay:n"])
    }

    func testOwnMessagesWithTheSameTextAreKept() {
        let note = RelayNote(id: "n", text: "OK", sentAt: 100_000, state: .sent)
        // 送る前に本人が打った同文・ずっと後に打った同文・届かなかった伝言と同文は消さない。
        let before = user("b", "OK", at: 10_000)
        let later = user("l", "OK", at: 100_000 + 60 * 60_000)
        XCTAssertEqual(RelayNotes.removingEchoes(from: [before, later], notes: [note]).map(\.id), ["b", "l"])
        let failed = RelayNote(id: "f", text: "OK", sentAt: 100_000, state: .failed("x"))
        XCTAssertEqual(RelayNotes.removingEchoes(from: [user("x", "OK", at: 100_100)], notes: [failed]).map(\.id), ["x"])
    }

    func testPlainTextWithoutTimestampIsKept() {
        // 時刻の無い過去の発話は、書き出しが無ければ伝言の写しと見なさない。
        let note = RelayNote(id: "n", text: "OK", sentAt: 100_000, state: .sent)
        XCTAssertEqual(RelayNotes.removingEchoes(from: [user("old", "OK", at: nil)], notes: [note]).map(\.id), ["old"])
        let prefixed = user("p", "Another Claude session sent a message:\nOK", at: nil)
        XCTAssertEqual(RelayNotes.removingEchoes(from: [prefixed], notes: [note]).map(\.id), [])
    }

    func testOneNoteHidesAtMostOneEcho() {
        let note = RelayNote(id: "n", text: "OK", sentAt: 1000, state: .sent)
        let items = [user("e1", "OK", at: 1100), user("e2", "OK", at: 1200)]
        XCTAssertEqual(RelayNotes.removingEchoes(from: items, notes: [note]).map(\.id), ["e2"])
    }
}
