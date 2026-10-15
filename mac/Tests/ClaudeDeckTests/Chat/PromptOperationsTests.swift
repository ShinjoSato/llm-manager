import XCTest
@testable import MonitorKit

/// 送信中の印はカード（identity）単位で、期限で必ず外れる。
final class PromptOperationBookTests: XCTestCase {
    private let key = "menu:room"
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// 1 問目を答えた直後に出た 2 問目のカードは、送信中を引き継がずに生まれ、すぐ押せる。
    func testNextQuestionCardIsNotBornBusy() throws {
        var book = PromptOperationBook()
        let token = try book.begin(key: key, identity: "q1", now: at(0)).get()
        XCTAssertTrue(book.isCardBusy(key: key, identity: "q1", now: at(0.05)))
        XCTAssertFalse(book.isCardBusy(key: key, identity: "q2", now: at(0.05)))
        // 送っている最中は別のカードも押させない（矢印が重なるため）。
        XCTAssertEqual(book.refusal(key: key, identity: "q2", now: at(0.05)), .operating)

        XCTAssertTrue(book.finish(key: key, token: token, now: at(0.11)))
        // 2 問目が出た（1 問目の描き替え待ちの間）。
        XCTAssertFalse(book.isCardBusy(key: key, identity: "q2", now: at(0.3)))
        XCTAssertNil(book.refusal(key: key, identity: "q2", now: at(0.3)))
        // 1 問目のカードはまだ押せない（古い表示への押し直しを送らない）。
        XCTAssertTrue(book.isCardBusy(key: key, identity: "q1", now: at(0.3)))
        XCTAssertEqual(book.refusal(key: key, identity: "q1", now: at(0.3)), .settling)

        // 2 問目をすぐ押せる。押すと 2 問目のカードだけが送信中になる。
        let second = try book.begin(key: key, identity: "q2", now: at(0.4)).get()
        XCTAssertNotEqual(second, token)
        XCTAssertTrue(book.isCardBusy(key: key, identity: "q2", now: at(0.45)))
        XCTAssertFalse(book.isCardBusy(key: key, identity: "q1", now: at(0.45)))
        XCTAssertFalse(book.isCardBusy(key: key, identity: "q3", now: at(0.45)))
    }

    /// 描き替え待ちは送り終えてから `settle` 秒で外れる。
    func testSettleEndsAfterFinish() throws {
        var book = PromptOperationBook()
        let token = try book.begin(key: key, identity: "q1", now: at(0)).get()
        book.finish(key: key, token: token, now: at(1))
        XCTAssertTrue(book.isCardBusy(key: key, identity: "q1", now: at(1 + PromptOperationBook.settle - 0.01)))
        XCTAssertFalse(book.isCardBusy(key: key, identity: "q1", now: at(1 + PromptOperationBook.settle)))
        XCTAssertNil(book.refusal(key: key, identity: "q1", now: at(1 + PromptOperationBook.settle)))
        XCTAssertEqual(book.activeKeys(now: at(1 + PromptOperationBook.settle)), [])
    }

    /// 結果が返らなくても、送信中は上限（12 秒）を超えて残らない。
    func testBusyNeverOutlivesLimit() throws {
        var book = PromptOperationBook()
        _ = try book.begin(key: key, identity: "q1", now: at(0)).get()
        XCTAssertEqual(PromptOperationBook.limit, 12)
        XCTAssertTrue(book.isCardBusy(key: key, identity: "q1", now: at(11.99)))
        XCTAssertFalse(book.isCardBusy(key: key, identity: "q1", now: at(12)))
        XCTAssertNil(book.refusal(key: key, identity: "q2", now: at(12)))
        XCTAssertEqual(book.nextExpiry, at(12))
        let expired = book.expire(now: at(12))
        XCTAssertEqual(expired.map(\.key), [key])
        XCTAssertTrue(expired[0].timedOut)
        XCTAssertTrue(book.entries.isEmpty)
    }

    /// 上限の間際に送り終えても、描き替え待ちで上限を延ばさない。
    func testFinishNearLimitDoesNotExtend() throws {
        var book = PromptOperationBook()
        let token = try book.begin(key: key, identity: "q1", now: at(0)).get()
        book.finish(key: key, token: token, now: at(11.5))
        XCTAssertEqual(book.entry(key, now: at(11.6))?.until, at(12))
        XCTAssertFalse(book.isCardBusy(key: key, identity: "q1", now: at(12)))
        XCTAssertFalse(book.expire(now: at(12))[0].timedOut)
    }

    /// 後から届いた古い操作の完了・解除は、今の操作の印を外さない。
    func testOnlyOwnTokenFinishesOrReleases() throws {
        var book = PromptOperationBook()
        let old = try book.begin(key: key, identity: "q1", now: at(0)).get()
        _ = book.expire(now: at(13))
        let current = try book.begin(key: key, identity: "q2", now: at(13)).get()
        XCTAssertFalse(book.finish(key: key, token: old, now: at(13.1)))
        XCTAssertFalse(book.release(key: key, token: old))
        XCTAssertTrue(book.entry(key, now: at(13.1))?.isOperating == true)
        XCTAssertTrue(book.isCardBusy(key: key, identity: "q2", now: at(13.1)))
        XCTAssertTrue(book.release(key: key, token: current))
        XCTAssertNil(book.entry(key, now: at(13.1)))
    }

    /// キー 1 つの操作（端末の権限・読めない選択肢の Esc）は描き替え待ちだけを付ける。
    func testHoldMarksOnlyThatCard() {
        var book = PromptOperationBook()
        book.hold(key: key, identity: "p1", now: at(0))
        XCTAssertTrue(book.isCardBusy(key: key, identity: "p1", now: at(0.5)))
        XCTAssertFalse(book.isCardBusy(key: key, identity: "p2", now: at(0.5)))
        XCTAssertEqual(book.refusal(key: key, identity: "p1", now: at(0.5)), .settling)
        XCTAssertNil(book.refusal(key: key, identity: "p2", now: at(0.5)))
        XCTAssertNil(book.entry(key, now: at(PromptOperationBook.settle)))
    }

    /// カードを指さない印は、どのカードも送信中に見せずに重ねての操作だけを断る。
    func testHoldWithoutIdentityBlocksButShowsNoBusyCard() {
        var book = PromptOperationBook()
        book.hold(key: key, identity: nil, now: at(0))
        XCTAssertFalse(book.isCardBusy(key: key, identity: "q1", now: at(0.1)))
        XCTAssertEqual(book.refusal(key: key, identity: "q1", now: at(0.1)), .settling)
        XCTAssertEqual(book.activeKeys(now: at(0.1)), [key])
    }

    /// ルームが違えば互いに影響しない。
    func testKeysAreIndependent() throws {
        var book = PromptOperationBook()
        _ = try book.begin(key: "menu:a", identity: "x", now: at(0)).get()
        XCTAssertNil(book.refusal(key: "menu:b", identity: "x", now: at(0)))
        XCTAssertFalse(book.isCardBusy(key: "menu:b", identity: "x", now: at(0)))
    }
}

@MainActor
final class PromptCardBoardTests: XCTestCase {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 2_000_000)
    }

    private func makeBoard() -> (PromptCardBoard, Clock, () -> [String]) {
        let clock = Clock()
        var lines: [String] = []
        let board = PromptCardBoard(clock: { clock.now }) { event, fields in
            lines.append(([event] + fields.map { "\($0.0)=\($0.1)" }).joined(separator: " "))
        }
        return (board, clock, { lines })
    }

    /// MessageList と同じ流れ: 1 問目を押す → 結果 → 2 問目のカードが出る。2 問目は送信中で生まれない。
    func testSecondQuestionCardAppearsNotBusy() throws {
        let (board, clock, lines) = makeBoard()
        let key = "menu:room"
        board.cardAppeared(key: key, identity: "q1", kind: "menu")
        let token = try board.begin(key: key, identity: "q1").get()
        XCTAssertTrue(board.isCardBusy(key: key, identity: "q1"))
        clock.now += 0.11
        board.finish(key: key, token: token)
        clock.now += 0.19
        board.cardAppeared(key: key, identity: "q2", kind: "menu")
        XCTAssertFalse(board.isCardBusy(key: key, identity: "q2"))
        XCTAssertNil(board.nextChange(key: key, identity: "q2"))
        XCTAssertNotNil(board.nextChange(key: key, identity: "q1"))
        XCTAssertTrue(lines().contains("card key=menu:room card=q2 kind=menu busy=no"))
        XCTAssertTrue(lines().contains("card key=menu:room card=q1 kind=menu busy=no"))
        // 2 問目をすぐ押せる。
        XCTAssertNotNil(try? board.begin(key: key, identity: "q2").get())
    }

    /// 送っている最中の押下は黙って捨てず、カードに理由を出す。
    func testRefusedPressShowsNotice() throws {
        let (board, clock, lines) = makeBoard()
        let key = "menu:room"
        _ = try board.begin(key: key, identity: "q1").get()
        guard case .failure(.operating) = board.begin(key: key, identity: "q1") else { return XCTFail("二度押しを通した") }
        XCTAssertEqual(board.notice(key: key, identity: "q1"), PromptCardBoard.message(.operating))
        // 一言はそのルームのどのカードにも出る。
        XCTAssertEqual(board.notice(key: key, identity: "q2"), PromptCardBoard.message(.operating))
        XCTAssertTrue(lines().contains("refuse key=menu:room card=q1 reason=operating"))
        XCTAssertFalse(board.admit(key: key, identity: "q2"))
        clock.now += PromptCardBoard.noticeDuration
        XCTAssertNil(board.notice(key: key, identity: "q1"))
    }

    /// 結果が返らないまま上限を過ぎたら、送信中を外して案内を出す。
    func testSweepAtLimitReleasesAndShowsTimeoutNotice() throws {
        let (board, clock, lines) = makeBoard()
        let key = "menu:room"
        let token = try board.begin(key: key, identity: "q1").get()
        XCTAssertEqual(board.nextChange(key: key, identity: "q1"), clock.now + PromptOperationBook.limit)
        clock.now += PromptOperationBook.limit
        // 掃除が遅れても、カードは期限で送信中に見せない。
        XCTAssertFalse(board.isCardBusy(key: key, identity: "q1"))
        board.sweep()
        XCTAssertTrue(board.book.entries.isEmpty)
        XCTAssertEqual(board.notice(key: key, identity: "q1"), PromptCardBoard.timeoutNotice)
        XCTAssertEqual(board.notice(key: key, identity: "q9"), PromptCardBoard.timeoutNotice)
        XCTAssertTrue(lines().contains("busy- key=menu:room token=\(PromptCardBoard.short(token)) reason=timeout"))
        // 後から届いた古い操作の解除は何もしない。
        board.release(key: key, token: token, reason: "late")
        XCTAssertTrue(lines().last?.hasSuffix("removed=stale") == true)
    }

    /// 掃除より先に次の操作が来ても、時間切れは記録と一言に残る。
    func testTimeoutIsReportedEvenIfNextPressComesBeforeSweep() throws {
        let (board, clock, lines) = makeBoard()
        let key = "menu:room"
        let stale = try board.begin(key: key, identity: "q1").get()
        clock.now += PromptOperationBook.limit + 1
        let next = try board.begin(key: key, identity: "q2").get()
        XCTAssertTrue(lines().contains("busy- key=menu:room token=\(PromptCardBoard.short(stale)) reason=timeout"))
        // 新しい操作を始めたので、前の操作の一言は残さない。
        XCTAssertNil(board.notice(key: key, identity: "q2"))
        XCTAssertTrue(board.isCardBusy(key: key, identity: "q2"))
        board.release(key: key, token: stale, reason: "late")
        XCTAssertTrue(board.isCardBusy(key: key, identity: "q2"))
        board.release(key: key, token: next, reason: "done")
        XCTAssertFalse(board.isCardBusy(key: key, identity: "q2"))
    }

    /// 掃除は実際の時計でも予約される（カードの描き直しに頼らない）。
    func testSweepIsScheduledOnRealClock() async throws {
        let board = PromptCardBoard()
        board.showNotice("一言", key: "menu:x", duration: 0.1)
        XCTAssertEqual(board.notices.count, 1)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(board.notices.isEmpty)
    }

    func testClearNoticeOnlyClearsSameText() {
        let (board, _, _) = makeBoard()
        board.showNotice("A", key: "k")
        board.clearNotice("B", key: "k")
        XCTAssertEqual(board.notice(key: "k", identity: "x"), "A")
        board.clearNotice("A", key: "k")
        XCTAssertNil(board.notice(key: "k", identity: "x"))
    }

    func testNoticeForSpecificCard() {
        let (board, _, _) = makeBoard()
        board.showNotice("この札だけ", key: "k", identity: "c1")
        XCTAssertEqual(board.notice(key: "k", identity: "c1"), "この札だけ")
        XCTAssertNil(board.notice(key: "k", identity: "c2"))
    }

    func testActiveKeys() throws {
        let (board, clock, _) = makeBoard()
        _ = try board.begin(key: "a", identity: "x").get()
        board.hold(key: "b", identity: nil)
        XCTAssertEqual(board.activeKeys, ["a", "b"])
        clock.now += PromptOperationBook.settle
        XCTAssertEqual(board.activeKeys, ["a"])
    }
}

@MainActor
final class OnceDeliveryTests: XCTestCase {
    func testDeliversOnlyOnce() {
        var received: [Int] = []
        let box = OnceDelivery<Int> { received.append($0) }
        XCTAssertFalse(box.isDelivered)
        XCTAssertTrue(box.deliver(1))
        XCTAssertFalse(box.deliver(2))
        XCTAssertTrue(box.isDelivered)
        XCTAssertEqual(received, [1])
    }

    /// 完了が返らなければ時間切れの値が 1 回だけ届き、後から返った完了は届かない。
    func testTimeoutDeliversWhenNoCompletion() async throws {
        var received: [String] = []
        let box = OnceDelivery<String> { received.append($0) }
        box.deliver(after: 0.05) { "timeout" }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(received, ["timeout"])
        XCTAssertFalse(box.deliver("late"))
        XCTAssertEqual(received, ["timeout"])
    }

    /// 先に完了すれば時間切れは届かない。
    func testCompletionBeatsTimeout() async throws {
        var received: [String] = []
        let box = OnceDelivery<String> { received.append($0) }
        box.deliver(after: 0.05) { "timeout" }
        box.deliver("done")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(received, ["done"])
    }

    /// 受け口を誰も持っていなくても時間切れは届く（端末側が完了を捨てても送信中を残さない）。
    func testTimeoutFiresEvenIfBoxIsDropped() async throws {
        var received: [String] = []
        do {
            let box = OnceDelivery<String> { received.append($0) }
            box.deliver(after: 0.05) { "timeout" }
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(received, ["timeout"])
    }
}
