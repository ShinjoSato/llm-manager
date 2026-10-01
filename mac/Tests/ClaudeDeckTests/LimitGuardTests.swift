import XCTest
@testable import MonitorKit

final class LimitGuardUsageTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func snapshot(fiveHour: Double?, sevenDay: Double? = nil, age: TimeInterval = 30, resetsIn: TimeInterval? = 3600) -> UsageSnapshot {
        let resets = resetsIn.map { (now.timeIntervalSince1970 + $0) * 1000 }
        return UsageSnapshot(
            fetchedAt: (now.timeIntervalSince1970 - age) * 1000,
            fiveHour: fiveHour.map { UsageWindow(usedPercentage: $0, resetsAt: resets) },
            sevenDay: sevenDay.map { UsageWindow(usedPercentage: $0, resetsAt: resets) }
        )
    }

    func testFreshHundredPercentIsHit() {
        XCTAssertEqual(LimitGuard.usageHit(snapshot(fiveHour: 100), now: now)?.window, .fiveHour)
        XCTAssertEqual(LimitGuard.usageHit(snapshot(fiveHour: 40, sevenDay: 100), now: now)?.window, .sevenDay)
    }

    func testNinetyNinePercentIsNotHit() {
        XCTAssertNil(LimitGuard.usageHit(snapshot(fiveHour: 99, sevenDay: 99.9), now: now))
    }

    func testStaleOrNilIsNotHit() {
        XCTAssertNil(LimitGuard.usageHit(nil, now: now))
        XCTAssertNil(LimitGuard.usageHit(snapshot(fiveHour: 100, age: LimitGuard.freshness + 1), now: now))
        XCTAssertNil(LimitGuard.usageHit(UsageSnapshot(fetchedAt: now.timeIntervalSince1970 * 1000, fiveHour: nil, sevenDay: nil), now: now))
    }

    func testValueFromPastWindowIsNotHit() {
        XCTAssertNil(LimitGuard.usageHit(snapshot(fiveHour: 100, resetsIn: -10), now: now))
    }

    func testLatchHoldsUntilResetThenClears() {
        var latch = UsageLimitLatch()
        XCTAssertTrue(latch.update(with: snapshot(fiveHour: 100, resetsIn: 3600), now: now))
        // 値が古くなっても（新しいセッションの起動時）リセット前は到達のまま。
        XCTAssertTrue(latch.update(with: snapshot(fiveHour: 100, resetsIn: 3600), now: now.addingTimeInterval(1800)))
        XCTAssertFalse(latch.update(with: nil, now: now.addingTimeInterval(3601)))
    }

    func testLatchClearsOnFreshLowerValue() {
        var latch = UsageLimitLatch()
        XCTAssertTrue(latch.update(with: snapshot(fiveHour: 100), now: now))
        XCTAssertFalse(latch.update(with: snapshot(fiveHour: 3), now: now.addingTimeInterval(60)))
    }

    func testLatchIgnoresStaleOrMissingValue() {
        var latch = UsageLimitLatch()
        XCTAssertFalse(latch.update(with: nil, now: now))
        XCTAssertFalse(latch.update(with: snapshot(fiveHour: 100, age: 3600), now: now))
    }

    func testLatchWithoutResetTimeLastsOnlyWhileFresh() {
        var latch = UsageLimitLatch()
        let usage = snapshot(fiveHour: 100, resetsIn: nil)
        XCTAssertTrue(latch.update(with: usage, now: now))
        XCTAssertFalse(latch.update(with: usage, now: now.addingTimeInterval(LimitGuard.freshness)))
    }
}

final class LimitGuardScreenTests: XCTestCase {
    let rule = String(repeating: "─", count: 60)

    /// 入力欄（罫線・❯ 行・罫線）とフッターを付けた画面。
    func screen(body: [String], footer: [String] = ["  ? for shortcuts"], blankRows: Int = 3) -> [String] {
        body + ["", rule, "❯ ", rule] + footer + Array(repeating: "", count: blankRows)
    }

    func testPhraseInConversationBodyDoesNotTrigger() {
        let body = [
            "❯ 上限の文言を調べて",
            "",
            "⏺ Claude Code は上限に達すると \"usage limit reached\" や",
            "  \"You've hit your session limit · resets 3pm\" と出します。",
            "  ⎿  Usage limit reached",
            "",
            "⏺ Update(mac/Sources/ClaudeDeck/ClaudeTerminalView.swift)",
            "  ⎿  Added 3 lines",
            "       \"5-hour limit reached\",",
            "       \"weekly limit reached\",",
            "",
            "⏺ 直しました。",
        ]
        XCTAssertNil(LimitGuard.screenLimitLine(screen(body: body)))
    }

    func testReplyTextJustAboveInputBoxDoesNotTrigger() {
        let body = ["⏺ 表示は次のとおりです:", "  You've hit your session limit · resets 3pm"]
        XCTAssertNil(LimitGuard.screenLimitLine(screen(body: body)))
    }

    func testLimitErrorAboveInputBoxTriggers() {
        let body = [
            "❯ つづけて",
            "  ⎿  You've hit your session limit · resets 3pm (Asia/Tokyo)",
            "     /upgrade to keep using Claude Code",
        ]
        XCTAssertEqual(LimitGuard.screenLimitLine(screen(body: body)), "⎿  You've hit your session limit · resets 3pm (Asia/Tokyo)")
    }

    func testWeeklyLimitWithNonBreakingSpaceTriggers() {
        let body = ["❯ hi", "  ⎿\u{A0}You've hit your weekly limit · resets Oct 3"]
        XCTAssertNotNil(LimitGuard.screenLimitLine(screen(body: body)))
    }

    func testFooterNotificationTriggers() {
        let footer = ["  ⏵⏵ auto mode on (shift+tab to cycle)        Usage limit reached · continuing automatically at 3pm · esc to cancel"]
        XCTAssertNotNil(LimitGuard.screenLimitLine(screen(body: ["⏺ done"], footer: footer)))
    }

    func testSwitchToUsageCreditsTriggers() {
        let footer = ["  You're now using usage credits · Your session limit resets 3pm"]
        XCTAssertNotNil(LimitGuard.screenLimitLine(screen(body: ["⏺ done"], footer: footer)))
    }

    func testWarningBeforeLimitDoesNotTrigger() {
        let footer = ["  You've used 90% of your session limit · resets 3pm"]
        XCTAssertNil(LimitGuard.screenLimitLine(screen(body: ["⏺ done"], footer: footer)))
    }

    func testRateLimitMenuTriggers() {
        let menu = [
            "❯ hi",
            "  ⎿  You've hit your limit · resets 3pm",
            "",
            "  What do you want to do?",
            "",
            "  ❯ 1. Stop and wait for limit to reset",
            "    2. Upgrade your plan",
            "",
            "  Enter to confirm · Esc to cancel",
            "", "",
        ]
        XCTAssertEqual(LimitGuard.screenLimitLine(menu), "❯ 1. Stop and wait for limit to reset")
    }

    func testToolOutputWithLimitPhraseDoesNotTrigger() {
        let body = ["❯ 上限の表示を試して", "⏺ Bash(echo \"Usage limit reached · wrapping up\")", "  ⎿  Usage limit reached · wrapping up"]
        XCTAssertNil(LimitGuard.screenLimitLine(screen(body: body)))
        let mcp = ["⏺ ai-manager - get_dashboard (MCP)(name: \"x\")", "  ⎿  You've hit your session limit · resets 3pm"]
        XCTAssertNil(LimitGuard.screenLimitLine(screen(body: mcp)))
    }

    func testNumberedListWithoutInputBoxOrMenuHintDoesNotTrigger() {
        let lines = ["⏺ 選択肢:", "  1. Upgrade your plan", "  2. Stop and wait for limit to reset", "", ""]
        XCTAssertNil(LimitGuard.screenLimitLine(lines))
    }

    func testMenuOptionQuotedInBodyDoesNotTrigger() {
        let body = ["⏺ メニューには次が出ます:", "  1. Stop and wait for limit to reset", "  2. Upgrade your plan"]
        XCTAssertNil(LimitGuard.screenLimitLine(screen(body: body)))
    }

    func testOldLimitErrorScrolledFarAboveDoesNotTrigger() {
        let body = ["❯ hi", "  ⎿  You've hit your session limit · resets 3pm"]
            + (1...10).map { "⏺ line \($0)" }
        XCTAssertNil(LimitGuard.screenLimitLine(screen(body: body)))
    }

    func testEmptyScreen() {
        XCTAssertNil(LimitGuard.screenLimitLine([]))
        XCTAssertNil(LimitGuard.screenLimitLine(["", ""]))
    }

    func testBufferLineCount() {
        for count in [0, 1, 5, 24, 25, 100, 1234] {
            XCTAssertEqual(LimitGuard.bufferLineCount(rows: 24) { $0 < count }, count)
        }
    }
}
