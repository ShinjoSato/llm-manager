import XCTest
@testable import MonitorKit

final class MenuPromptParseTests: XCTestCase {
    private let rule = String(repeating: "─", count: 40)

    private var trustScreen: [String] {
        [
            rule,
            " Accessing workspace:",
            "",
            " /tmp/trust-a1",
            "",
            " Quick safety check: Is this a project you created or one you trust?",
            "",
            " ❯ No, exit",
            "   Yes, I trust this folder",
            "",
            " Enter to confirm · Esc to cancel",
            "", "", "",
        ]
    }

    private var askScreen: [String] {
        [
            "❯ Use the AskUserQuestion tool once to ask me: pick a color.",
            rule,
            " ☐ Color",
            "",
            "Pick a color?",
            "",
            "❯ 1. Red",
            "     Choose red",
            "  2. Blue",
            "     Choose blue",
            "  3. Type something.",
            rule,
            "  4. Chat about this",
            "",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ]
    }

    private var planScreen: [String] {
        [
            "  " + rule,
            "   Ready to code?",
            "   Here is Claude's plan:",
            "   Create an empty file a.txt in the working directory.",
            "  " + rule,
            "   Claude has written up a plan and is ready to execute. Would you like to proceed?",
            "   ❯ 1. Yes, and use auto mode",
            "     2. Yes, manually approve edits",
            "     3. Tell Claude what to change",
            "        shift+tab to approve with this feedback",
            "   ctrl+g to edit in Vim · ~/.claude/plans/plan.md",
        ]
    }

    /// 自由入力の行に ❯ が乗った AskUserQuestion。案内行が出ていなくても入力欄への送信を止める。
    private func freeTextScreen(cursorLine: String, footer: Bool) -> [String] {
        [
            "❯ Use the AskUserQuestion tool once to ask me: pick a color.",
            rule,
            " ☐ Color",
            "",
            "Pick a color?",
            "",
            "  1. Red",
            "     Choose red",
            "  2. Blue",
            "     Choose blue",
            cursorLine,
            rule,
            "  4. Chat about this",
        ] + (footer ? ["", "Enter to select · ↑/↓ to navigate · Esc to cancel"] : [])
    }

    func testFreeTextRowBlocksInputWithoutFooter() {
        for cursorLine in ["❯ 3. Type something.", "❯ 3.", "❯ 3. ", "❯ 3. hello there"] {
            let screen = freeTextScreen(cursorLine: cursorLine, footer: false)
            XCTAssertEqual(InputBlock.detect(screen: screen), .menu, cursorLine)
            XCTAssertNil(InputBox.text(screen: screen), cursorLine)
        }
    }

    func testFreeTextRowBlocksInputWithFooter() {
        for cursorLine in ["❯ 3.", "❯ 3. hello there"] {
            XCTAssertEqual(InputBlock.detect(screen: freeTextScreen(cursorLine: cursorLine, footer: true)), .menu, cursorLine)
        }
    }

    /// 空の自由入力の行はメニューとして止めるが、中身は読めない（読めないカードで閉じるだけにする）。
    func testEmptyFreeTextRowIsUnreadable() {
        let screen = freeTextScreen(cursorLine: "❯ 3.", footer: true)
        XCTAssertNil(ChoiceMenu.parse(screen: screen))
        XCTAssertNotNil(ChoiceMenu.unreadable(screen: screen))
    }

    /// 番号だけの ❯ 行でも、前後に続き番号の選択肢が無ければメニューとみなさない。
    func testLoneNumberCursorIsNotMenu() {
        XCTAssertNil(InputBlock.detect(screen: ["⏺ Done.", "", "❯ 3."]))
    }

    func testTrustDialog() throws {
        let menu = try XCTUnwrap(ChoiceMenu.parse(screen: trustScreen))
        XCTAssertEqual(menu.question, "Quick safety check: Is this a project you created or one you trust?")
        XCTAssertEqual(menu.context, ["Accessing workspace:", "/tmp/trust-a1"])
        XCTAssertEqual(menu.options, [
            .init(number: nil, label: "No, exit"),
            .init(number: nil, label: "Yes, I trust this folder"),
        ])
        XCTAssertEqual(menu.cursor, 0)
    }

    func testTrustDialogWithCursorOnSecondRow() throws {
        var screen = trustScreen
        screen[7] = "   No, exit"
        screen[8] = " ❯ Yes, I trust this folder"
        let menu = try XCTUnwrap(ChoiceMenu.parse(screen: screen))
        XCTAssertEqual(menu.options.map(\.label), ["No, exit", "Yes, I trust this folder"])
        XCTAssertEqual(menu.cursor, 1)
        XCTAssertTrue(menu.sameMenu(as: try XCTUnwrap(ChoiceMenu.parse(screen: trustScreen))))
    }

    func testAskUserQuestion() throws {
        let menu = try XCTUnwrap(ChoiceMenu.parse(screen: askScreen))
        XCTAssertEqual(menu.question, "Pick a color?")
        XCTAssertEqual(menu.context, ["☐ Color"])
        XCTAssertEqual(menu.options, [
            .init(number: 1, label: "Red", detail: ["Choose red"]),
            .init(number: 2, label: "Blue", detail: ["Choose blue"]),
            .init(number: 3, label: "Type something."),
            .init(number: 4, label: "Chat about this"),
        ])
        XCTAssertEqual(menu.cursor, 0)
        XCTAssertEqual(menu.options.map(\.isFreeText), [false, false, true, false])
    }

    func testPlanApproval() throws {
        let menu = try XCTUnwrap(ChoiceMenu.parse(screen: planScreen))
        XCTAssertEqual(menu.question, "Claude has written up a plan and is ready to execute. Would you like to proceed?")
        XCTAssertEqual(menu.context, ["Ready to code?", "Here is Claude's plan:", "Create an empty file a.txt in the working directory."])
        XCTAssertEqual(menu.options.map(\.label), ["Yes, and use auto mode", "Yes, manually approve edits", "Tell Claude what to change"])
        XCTAssertEqual(menu.options[2].detail, ["shift+tab to approve with this feedback"])
        XCTAssertTrue(menu.options[2].isFreeText)
        XCTAssertEqual(menu.cursor, 0)
    }

    /// 選択肢より上の本文に番号付きリストがあっても選択肢に混ぜない。
    func testNumberedPlanStepsAreNotOptions() throws {
        let screen = [
            "  " + rule,
            "   Here is Claude's plan:",
            "   1. Write a test",
            "   2. Implement it",
            "  " + rule,
            "   Would you like to proceed?",
            "     1. Yes, and use auto mode",
            "   ❯ 2. Yes, manually approve edits",
            "     3. Tell Claude what to change",
        ]
        let menu = try XCTUnwrap(ChoiceMenu.parse(screen: screen))
        XCTAssertEqual(menu.options.map(\.number), [1, 2, 3])
        XCTAssertEqual(menu.cursor, 1)
        XCTAssertEqual(menu.context, ["Here is Claude's plan:", "1. Write a test", "2. Implement it"])
    }

    func testCursorMovesButMenuIsSame() throws {
        var screen = askScreen
        screen[6] = "  1. Red"
        screen[8] = "❯ 2. Blue"
        let moved = try XCTUnwrap(ChoiceMenu.parse(screen: screen))
        let original = try XCTUnwrap(ChoiceMenu.parse(screen: askScreen))
        XCTAssertEqual(moved.cursor, 1)
        XCTAssertTrue(moved.sameMenu(as: original))
        XCTAssertNotEqual(moved, original)
    }

    func testNoMenuOnPermissionOrIdle() {
        let idle = ["⏺ done", rule, "❯ ", rule, "  ⏵⏵ auto mode on"]
        XCTAssertNil(ChoiceMenu.parse(screen: idle))
        let history = ["❯ 1. まずテストを書く", "  2. 次に実装する", "", "⏺ 了解しました。", rule, "❯ ", rule]
        XCTAssertNil(ChoiceMenu.parse(screen: history))
    }

    func testFooterAndExitDetection() throws {
        let ask = try XCTUnwrap(ChoiceMenu.parse(screen: askScreen))
        XCTAssertEqual(ask.footer, "Enter to select · ↑/↓ to navigate · Esc to cancel")
        XCTAssertFalse(ask.cancelExits)
        // trust 確認は案内が「Esc to cancel」でも Esc で claude が終わる。
        XCTAssertTrue(try XCTUnwrap(ChoiceMenu.parse(screen: trustScreen)).cancelExits)
        XCTAssertEqual(try XCTUnwrap(ChoiceMenu.parse(screen: planScreen)).footer, "")

        var exitScreen = askScreen
        exitScreen[14] = "Enter to select · Esc to exit"
        XCTAssertTrue(try XCTUnwrap(ChoiceMenu.parse(screen: exitScreen)).cancelExits)
    }

    /// 選択肢の ❯ が読めない時に、上の会話履歴の発話（❯ …）を選択肢と読まない。
    func testHistoryPromptIsNotReadAsOptions() {
        let screen = [
            "❯ 一つ目の依頼",
            "  二行目の続き",
            "⏺ 了解しました。",
            rule,
            " Pick a color?",
            "   1. Red",
            "   2. Blue",
            "",
            " Enter to select · Esc to cancel",
        ]
        XCTAssertTrue(ChoiceMenu.isShowing(screen: screen))
        XCTAssertNil(ChoiceMenu.parse(screen: screen))
        let unreadable = ChoiceMenu.unreadable(screen: screen)
        XCTAssertNotNil(unreadable)
        XCTAssertEqual(unreadable?.cancelExits, false)
    }

    /// 番号の無い ❯ 行は操作案内が無ければ選択肢と読まない。
    func testPlainCursorWithoutFooterIsNotMenu() {
        let screen = ["❯ 依頼の一行目", "  依頼の二行目", "", "  1. a", "  2. b"]
        XCTAssertNil(ChoiceMenu.parseShowing(screen: screen))
    }

    /// ❯ を探すのは案内行から上へ限られた行数まで。
    func testCursorFarAboveFooterIsIgnored() {
        var screen = ["❯ 1. 古い発話", "  2. 続き"]
        screen += Array(repeating: "  本文", count: ChoiceMenu.cursorSearchLines)
        screen += ["Enter to select · Esc to cancel"]
        XCTAssertNil(ChoiceMenu.parse(screen: screen))
    }

    /// 罫線が無い時は、空行・会話の行・経過表示の手前までを本文にする。
    func testContextWithoutRuleStopsAtBlankAndHistory() throws {
        let screen = [
            "⏺ 以前の返答",
            "✻ Thinking… (12s)",
            "",
            "Color",
            "Pick a color?",
            "❯ 1. Red",
            "  2. Blue",
            "Enter to select · Esc to cancel",
        ]
        let menu = try XCTUnwrap(ChoiceMenu.parse(screen: screen))
        XCTAssertEqual(menu.question, "Pick a color?")
        XCTAssertEqual(menu.context, ["Color"])

        let noBlank = ["⏺ 以前の返答", "✻ Thinking… (12s)", "Pick a color?", "❯ 1. Red", "  2. Blue", "Enter to select · Esc to cancel"]
        XCTAssertEqual(try XCTUnwrap(ChoiceMenu.parse(screen: noBlank)).context, [])
    }

    func testMultiSelectCheckboxes() throws {
        let screen = [
            rule,
            "Pick colors?",
            "",
            "❯ 1. [ ] Red",
            "  2. [✓] Blue",
            "  3. Type something.",
            "",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ]
        let menu = try XCTUnwrap(ChoiceMenu.parse(screen: screen))
        XCTAssertTrue(menu.isMultiSelect)
        XCTAssertEqual(menu.options.map(\.label), ["Red", "Blue", "Type something."])
        XCTAssertEqual(menu.options.map(\.checked), [false, true, nil])
        XCTAssertTrue(menu.options[2].isFreeText)
        XCTAssertFalse(try XCTUnwrap(ChoiceMenu.parse(screen: askScreen)).isMultiSelect)
    }
}

final class MenuNavigatorTests: XCTestCase {
    private func menu(cursor: Int, labels: [String] = ["Red", "Blue", "Type something.", "Chat about this"],
                      question: String = "Pick a color?") -> MenuPrompt {
        MenuPrompt(context: ["☐ Color"], question: question,
                   options: labels.enumerated().map { .init(number: $0.offset + 1, label: $0.element) }, cursor: cursor)
    }

    /// 目的の行にいても、もう一度読んで動いていないのを確かめてから Enter。
    func testConfirmsAfterStableReadOnTarget() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 0)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .wait)
        XCTAssertEqual(nav.next(menu(cursor: 0)), .confirm)
    }

    func testMovesDownStepByStepThroughFreeTextRow() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 3)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 1)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 2)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 3)), .wait)
        XCTAssertEqual(nav.next(menu(cursor: 3)), .confirm)
    }

    /// 自由入力の行に乗った時点で画面が選択肢として読めなくなれば、Enter を押さずに止まる。
    func testStopsWhenFreeTextRowMakesMenuUnreadable() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 3)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 1)), .press(.down))
        var actions: [MenuNavigator.Action] = []
        for _ in 0..<6 { actions.append(nav.next(nil)) }
        XCTAssertEqual(actions.last, .abort(.vanished))
        XCTAssertFalse(actions.contains(.confirm))
        XCTAssertFalse(actions.contains { if case .press = $0 { return true } else { return false } })
    }

    /// 自由入力の行で選択肢の並びが変わって見えたら止まる。
    func testStopsWhenFreeTextRowChangesOptions() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 3)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 1)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 2, labels: ["Red", "Blue", "Chat about this"])), .abort(.changed))
    }

    func testMovesUp() {
        var nav = MenuNavigator(expected: menu(cursor: 3), target: 1)!
        XCTAssertEqual(nav.next(menu(cursor: 3)), .press(.up))
        XCTAssertEqual(nav.next(menu(cursor: 2)), .press(.up))
        XCTAssertEqual(nav.next(menu(cursor: 1)), .wait)
        XCTAssertEqual(nav.next(menu(cursor: 1)), .confirm)
    }

    /// 画面が追いつく前に次の矢印を送らない（行き過ぎないため）。
    func testWaitsForScreenBeforeNextPress() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 1)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 0)), .wait)
        XCTAssertEqual(nav.next(menu(cursor: 1)), .wait)
        XCTAssertEqual(nav.next(menu(cursor: 1)), .confirm)
    }

    /// 反映待ちが切れても同じ矢印を再送しない（未反映のキーを 2 つにしない）。
    func testDoesNotResendArrowWhileWaiting() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 3)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .press(.down))
        for _ in 0..<MenuNavigator.maxWaitsPerPress {
            XCTAssertEqual(nav.next(menu(cursor: 0)), .wait)
        }
        XCTAssertEqual(nav.next(menu(cursor: 0)), .abort(.stuck))
    }

    /// 目的の行に見えた後で遅れて届いたキーで ❯ が動いたら、確定しない。
    func testLateMoveAfterReachingTargetDoesNotConfirm() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 1)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 0)), .wait)
        XCTAssertEqual(nav.next(menu(cursor: 1)), .wait)
        XCTAssertEqual(nav.next(menu(cursor: 2)), .abort(.stuck))
    }

    /// 送っていないのに ❯ が動いたら（送った数と動いた回数が合わない）確定しない。
    func testCursorMovingWithoutPressAborts() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 0)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .wait)
        XCTAssertEqual(nav.next(menu(cursor: 1)), .abort(.stuck))
    }

    /// 1 回の変化で ❯ が 2 行動いたら（数えていない入力がある）戻さずに止まる。
    func testStopsOnOvershoot() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 1)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 2)), .abort(.stuck))
    }

    /// 目的の行を通り越さなくても、1 回で 2 行動いたら止まる。
    func testStopsWhenCursorJumpsTwoRows() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 3)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 2)), .abort(.stuck))
        XCTAssertTrue(nav.hasPendingKey)
    }

    /// 送った向きと逆に動いたら止まる。
    func testStopsWhenCursorMovesAgainstPressedDirection() {
        var nav = MenuNavigator(expected: menu(cursor: 1), target: 3)!
        XCTAssertEqual(nav.next(menu(cursor: 1)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 0)), .abort(.stuck))
    }

    func testDifferentMenuAtStartIsRejected() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 1)!
        XCTAssertEqual(nav.next(menu(cursor: 0, labels: ["Red", "Green", "Type something.", "Chat about this"])), .abort(.changed))
    }

    func testQuestionChangedWhileMovingAborts() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 1)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 1, question: "Pick a size?")), .abort(.changed))
    }

    /// 着いた時に選択肢の文言が違えば Enter を送らない。
    func testLabelsChangedAtTargetAborts() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 1)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 1, labels: ["Red", "Green", "Type something.", "Chat about this"])), .abort(.changed))
    }

    func testMenuGoneAtStartAborts() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 1)!
        XCTAssertEqual(nav.next(nil), .abort(.gone))
    }

    func testBrieflyUnreadableWhileMovingWaits() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 1)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .press(.down))
        XCTAssertEqual(nav.next(nil), .wait)
        XCTAssertEqual(nav.next(menu(cursor: 1)), .wait)
        XCTAssertEqual(nav.next(menu(cursor: 1)), .confirm)
    }

    /// 安定確認の間に読めなくなったら、読み直して確かめ直す。
    func testUnreadableDuringSettleRestartsCheck() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 0)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .wait)
        XCTAssertEqual(nav.next(nil), .wait)
        XCTAssertEqual(nav.next(menu(cursor: 0)), .wait)
        XCTAssertEqual(nav.next(menu(cursor: 0)), .confirm)
    }

    func testMenuGoneWhileMovingAbortsEventually() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 1)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .press(.down))
        var last: MenuNavigator.Action = .wait
        for _ in 0..<6 { last = nav.next(nil) }
        XCTAssertEqual(last, .abort(.vanished))
    }

    /// 矢印が効かず ❯ が動かないままなら、矢印は 1 回だけ送って諦める。
    func testStuckCursorGivesUp() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 1)!
        var last: MenuNavigator.Action = .wait
        var presses = 0
        for _ in 0..<100 {
            last = nav.next(menu(cursor: 0))
            if case .press = last { presses += 1 }
            if case .abort = last { break }
        }
        XCTAssertEqual(last, .abort(.stuck))
        XCTAssertEqual(presses, 1)
    }

    func testFreeTextAndOutOfRangeTargetsAreRejected() {
        XCTAssertNil(MenuNavigator(expected: menu(cursor: 0), target: 2))
        XCTAssertNil(MenuNavigator(expected: menu(cursor: 0), target: 4))
        XCTAssertNil(MenuNavigator(expected: menu(cursor: 0), target: -1))
    }

    func testArrowKeys() {
        XCTAssertEqual(PTYInput.arrowKey(.up, applicationCursor: false), "\u{1b}[A")
        XCTAssertEqual(PTYInput.arrowKey(.down, applicationCursor: false), "\u{1b}[B")
        XCTAssertEqual(PTYInput.arrowKey(.up, applicationCursor: true), "\u{1b}OA")
        XCTAssertEqual(PTYInput.arrowKey(.down, applicationCursor: true), "\u{1b}OB")
    }

    /// 端末の実画面の写しから読んだメニューで、そのまま目的の行まで進める。
    func testNavigatesOnParsedTrustDialog() throws {
        let rule = String(repeating: "─", count: 40)
        func screen(cursor: Int) -> [String] {
            [rule, " Accessing workspace:", "", " /tmp/trust-a1", "",
             " Quick safety check: Is this a project you created or one you trust?", "",
             cursor == 0 ? " ❯ No, exit" : "   No, exit",
             cursor == 1 ? " ❯ Yes, I trust this folder" : "   Yes, I trust this folder",
             "", " Enter to confirm · Esc to cancel"]
        }
        let expected = try XCTUnwrap(ChoiceMenu.parse(screen: screen(cursor: 0)))
        var nav = try XCTUnwrap(MenuNavigator(expected: expected, target: 1))
        XCTAssertEqual(nav.next(ChoiceMenu.parse(screen: screen(cursor: 0))), .press(.down))
        XCTAssertEqual(nav.next(ChoiceMenu.parse(screen: screen(cursor: 1))), .wait)
        XCTAssertEqual(nav.next(ChoiceMenu.parse(screen: screen(cursor: 1))), .confirm)
    }
}

final class PendingArrowHoldTests: XCTestCase {
    private func menu(cursor: Int) -> MenuPrompt {
        MenuPrompt(context: ["☐ Color"], question: "Pick a color?",
                   options: ["Red", "Blue", "Green", "Chat about this"].enumerated().map { .init(number: $0.offset + 1, label: $0.element) },
                   cursor: cursor)
    }

    /// キーを受け取ってから画面に反映するまでが遅れうる端末の模型。`frozen` の間はキーを溜めるだけ。
    private struct FakeTerminal {
        var cursor = 0
        var queue: [String] = []
        var frozen = false
        var confirmed: Int?

        mutating func send(_ key: String) { queue.append(key) }

        /// 溜まったキーを 1 つだけ処理する（1 回の描き替えで 1 キー）。
        mutating func tick() {
            guard !frozen, !queue.isEmpty else { return }
            switch queue.removeFirst() {
            case "down": cursor = min(cursor + 1, 3)
            case "up": cursor = max(cursor - 1, 0)
            case "enter": confirmed = cursor
            default: break
            }
        }
    }

    /// 移動をやめた時に矢印が 1 つ未反映のまま残り、次の移動が始まる前にそれが反映される流れ。
    /// 印を守れば次の移動は残りのキーを自分の 1 歩と数えず、押した選択肢で確定する。
    func testLeftoverArrowFromAbortedNavigationIsNotCountedByNextOne() throws {
        var term = FakeTerminal()
        let start = Date(timeIntervalSince1970: 1_000)
        var now = start
        var lastOutput = start

        // 1 回目: 端末が固まっていて矢印が反映されず、Enter を押さずにやめる。
        var first = try XCTUnwrap(MenuNavigator(expected: menu(cursor: 0), target: 2))
        term.frozen = true
        var action = MenuNavigator.Action.wait
        for _ in 0..<50 {
            action = first.next(menu(cursor: term.cursor))
            if case .press = action { term.send("down") }
            if case .abort = action { break }
            now += PTYInput.menuStepInterval
        }
        XCTAssertEqual(action, .abort(.stuck))
        let hold = try XCTUnwrap(PendingArrowHold.after(first, now: now))

        // 印がある間（出力が流れていて ❯ も動いていない）は 2 回目を始めない。
        lastOutput = now
        XCTAssertFalse(hold.isReleased(now: now + 0.3, lastOutput: lastOutput, currentCursor: term.cursor))

        // 残っていた矢印が遅れて反映されると ❯ が動き、印が外れる。
        term.frozen = false
        term.tick()
        now += 0.3
        lastOutput = now
        XCTAssertEqual(term.cursor, 1)
        XCTAssertTrue(hold.isReleased(now: now, lastOutput: lastOutput, currentCursor: term.cursor))

        // 2 回目は今の画面から数え直すので、押した選択肢（Green = 2）で確定する。
        var second = try XCTUnwrap(MenuNavigator(expected: menu(cursor: term.cursor), target: 2))
        for _ in 0..<50 {
            action = second.next(menu(cursor: term.cursor))
            switch action {
            case .press(let direction): term.send(direction == .down ? "down" : "up")
            case .confirm: term.send("enter")
            default: break
            }
            term.tick()
            if action == .confirm { break }
            if case .abort = action { break }
        }
        XCTAssertEqual(action, .confirm)
        term.tick()
        XCTAssertEqual(term.confirmed, 2)
    }

    /// 印を見ずに次の移動を始めると、残りのキー（K0）の反映を自分の 1 歩と数えて確定に進んでしまう。
    /// 端末にはまだ自分の最後の矢印が残っているので、実際は 1 行先で確定する（印が要る理由）。
    func testNavigatorAloneCannotTellLeftoverArrow() throws {
        var nav = try XCTUnwrap(MenuNavigator(expected: menu(cursor: 0), target: 2))
        XCTAssertEqual(nav.next(menu(cursor: 0)), .press(.down))   // K1（端末には K0, K1）
        XCTAssertEqual(nav.next(menu(cursor: 1)), .press(.down))   // K0 の反映を K1 と数える → K2
        XCTAssertEqual(nav.next(menu(cursor: 2)), .wait)           // K1 の反映
        XCTAssertEqual(nav.next(menu(cursor: 2)), .confirm)        // K2 が遅れると見分けられない
    }

    func testHoldIsCreatedOnlyWithPendingKey() throws {
        var idle = try XCTUnwrap(MenuNavigator(expected: menu(cursor: 0), target: 1))
        XCTAssertEqual(idle.next(nil), .abort(.gone))
        XCTAssertNil(PendingArrowHold.after(idle, now: Date()))

        var pressed = try XCTUnwrap(MenuNavigator(expected: menu(cursor: 0), target: 1))
        XCTAssertEqual(pressed.next(menu(cursor: 0)), .press(.down))
        XCTAssertEqual(PendingArrowHold.after(pressed, now: Date(timeIntervalSince1970: 5)),
                       PendingArrowHold(since: Date(timeIntervalSince1970: 5), cursor: 0))
    }

    func testReleaseRules() {
        let since = Date(timeIntervalSince1970: 1_000)
        let hold = PendingArrowHold(since: since, cursor: 1)
        // 出力が流れ続け、❯ も動かない間は外さない。
        XCTAssertFalse(hold.isReleased(now: since + 1, lastOutput: since + 0.9, currentCursor: 1))
        // メニューが読めない時も外さない。
        XCTAssertFalse(hold.isReleased(now: since + 1, lastOutput: since + 0.9, currentCursor: nil))
        // ❯ が動いた。
        XCTAssertTrue(hold.isReleased(now: since + 0.2, lastOutput: since + 0.2, currentCursor: 2))
        // 出力が止まって 1.5 秒。中止より前の出力は数えない。
        XCTAssertFalse(hold.isReleased(now: since + 1.4, lastOutput: since - 10, currentCursor: 1))
        XCTAssertTrue(hold.isReleased(now: since + 1.5, lastOutput: since - 10, currentCursor: 1))
        XCTAssertTrue(hold.isReleased(now: since + 3, lastOutput: since + 1.4, currentCursor: 1))
        // 出力が流れ続けても上限で外す。
        XCTAssertFalse(hold.isReleased(now: since + 4.9, lastOutput: since + 4.8, currentCursor: 1))
        XCTAssertTrue(hold.isReleased(now: since + PendingArrowHold.maxHold, lastOutput: since + 4.9, currentCursor: 1))
    }
}
