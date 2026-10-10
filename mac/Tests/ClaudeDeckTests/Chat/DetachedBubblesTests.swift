import XCTest
@testable import MonitorKit

final class DetachedBubblesTests: XCTestCase {
    private func snapshot(_ session: String, _ item: String, text: String = "本文") -> BubbleSnapshot {
        BubbleSnapshot(key: BubbleKey(sessionId: session, itemId: item), roomName: "ai-manager", text: text, at: nil)
    }

    private func entry(_ role: ChatEntry.Role, text: String = "## 機能一覧\n- a", id: String = "m1") -> ChatEntry {
        ChatEntry(id: id, role: role, text: text, at: 1_700_000_000_000, tools: [])
    }

    func testOpeningTheSameBubbleTwiceReusesTheWindowAndKeepsTheFirstCopy() {
        var bubbles = DetachedBubbles()
        let first = bubbles.open(snapshot("s", "m1", text: "最初"))
        XCTAssertTrue(first.isNew)
        let second = bubbles.open(snapshot("s", "m1", text: "後から"))
        XCTAssertFalse(second.isNew)
        XCTAssertEqual(second.token, first.token)
        XCTAssertEqual(bubbles.entries.count, 1)
        XCTAssertEqual(bubbles.snapshot(for: first.token)?.text, "最初")
    }

    func testTheSameItemIdInAnotherSessionIsAnotherBubble() {
        var bubbles = DetachedBubbles()
        let a = bubbles.open(snapshot("s1", "m1"))
        let b = bubbles.open(snapshot("s2", "m1"))
        XCTAssertTrue(b.isNew)
        XCTAssertNotEqual(a.token, b.token)
        XCTAssertEqual(bubbles.token(for: BubbleKey(sessionId: "s2", itemId: "m1")), b.token)
    }

    func testClosingForgetsOnlyThatWindowAndAllowsReopening() {
        var bubbles = DetachedBubbles()
        let a = UUID(), b = UUID()
        bubbles.open(snapshot("s", "m1"), token: a)
        bubbles.open(snapshot("s", "m2"), token: b)
        bubbles.close(a)
        XCTAssertNil(bubbles.snapshot(for: a))
        XCTAssertEqual(bubbles.snapshot(for: b)?.key.itemId, "m2")
        XCTAssertTrue(bubbles.open(snapshot("s", "m1")).isNew)
        bubbles.close(UUID())
        XCTAssertEqual(bubbles.entries.count, 2)
    }

    func testOnlyClaudeRepliesWithTextAndASessionCanBeOpened() {
        let reply = BubbleSnapshot(entry: entry(.assistant), sessionId: "s", roomName: "ai-manager")
        XCTAssertEqual(reply?.key, BubbleKey(sessionId: "s", itemId: "m1"))
        XCTAssertEqual(reply?.text, "## 機能一覧\n- a")
        XCTAssertEqual(reply?.at, 1_700_000_000_000)
        XCTAssertEqual(reply?.roomName, "ai-manager")

        for role in [ChatEntry.Role.user, .relay, .outgoing, .toolsOnly] {
            XCTAssertNil(BubbleSnapshot(entry: entry(role), sessionId: "s", roomName: "r"), "\(role)")
        }
        XCTAssertNil(BubbleSnapshot(entry: entry(.assistant, text: " \n "), sessionId: "s", roomName: "r"))
        XCTAssertNil(BubbleSnapshot(entry: entry(.assistant), sessionId: nil, roomName: "r"))
    }

    func testTitleJoinsTheRoomNameAndTheTime() {
        let bubble = snapshot("s", "m1")
        XCTAssertEqual(bubble.title(time: "14:32"), "ai-manager · 14:32")
        XCTAssertEqual(bubble.title(time: ""), "ai-manager")
    }
}
