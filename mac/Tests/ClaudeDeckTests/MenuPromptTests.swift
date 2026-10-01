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
}

final class MenuNavigatorTests: XCTestCase {
    private func menu(cursor: Int, labels: [String] = ["Red", "Blue", "Type something.", "Chat about this"],
                      question: String = "Pick a color?") -> MenuPrompt {
        MenuPrompt(context: ["☐ Color"], question: question,
                   options: labels.enumerated().map { .init(number: $0.offset + 1, label: $0.element) }, cursor: cursor)
    }

    func testConfirmsImmediatelyWhenCursorIsOnTarget() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 0)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .confirm)
    }

    func testMovesDownStepByStepThroughFreeTextRow() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 3)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 1)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 2)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 3)), .confirm)
    }

    func testMovesUp() {
        var nav = MenuNavigator(expected: menu(cursor: 3), target: 1)!
        XCTAssertEqual(nav.next(menu(cursor: 3)), .press(.up))
        XCTAssertEqual(nav.next(menu(cursor: 2)), .press(.up))
        XCTAssertEqual(nav.next(menu(cursor: 1)), .confirm)
    }

    /// 画面が追いつく前に次の矢印を送らない（行き過ぎないため）。
    func testWaitsForScreenBeforeNextPress() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 1)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 0)), .wait)
        XCTAssertEqual(nav.next(menu(cursor: 1)), .confirm)
    }

    /// 行き過ぎたら戻す。
    func testCorrectsOvershoot() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 1)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .press(.down))
        XCTAssertEqual(nav.next(menu(cursor: 2)), .press(.up))
        XCTAssertEqual(nav.next(menu(cursor: 1)), .confirm)
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
        XCTAssertEqual(nav.next(menu(cursor: 1)), .confirm)
    }

    func testMenuGoneWhileMovingAbortsEventually() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 1)!
        XCTAssertEqual(nav.next(menu(cursor: 0)), .press(.down))
        var last: MenuNavigator.Action = .wait
        for _ in 0..<6 { last = nav.next(nil) }
        XCTAssertEqual(last, .abort(.gone))
    }

    /// 矢印が効かず ❯ が動かないままなら、いずれ諦める。
    func testStuckCursorGivesUp() {
        var nav = MenuNavigator(expected: menu(cursor: 0), target: 1)!
        var last: MenuNavigator.Action = .wait
        for _ in 0..<100 {
            last = nav.next(menu(cursor: 0))
            if case .abort = last { break }
        }
        XCTAssertEqual(last, .abort(.stuck))
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
        XCTAssertEqual(nav.next(ChoiceMenu.parse(screen: screen(cursor: 1))), .confirm)
    }
}
