import XCTest
@testable import MonitorKit

/// 入力欄の上に重ねて出るダイアログ（TUI v2.1.288 の fullscreen）と、セッションファイルの waitingFor による送信の停止。
final class OverlayMenuTests: XCTestCase {
    private let rule = String(repeating: "─", count: 40)

    private var inputBox: [String] { [rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"] }

    private func offer(footer: String) -> [String] {
        [
            "⏺ 完了しました。",
            "",
            "✻ Crunched for 3s",
            rule,
            " Teach auto mode about your environment?",
            "",
            " Claude Code can learn how you work to make better auto mode decisions.",
            "",
            " ❯ 1. Yes",
            "   2. Not now",
            "   3. Don't show again",
            "",
            " " + footer,
        ]
    }

    private func wizard(continueLine: String) -> [String] {
        [
            "⏺ 完了しました。",
            "",
            rule,
            " Teach auto mode about your environment?",
            "",
            " Claude Code reads this project, your recent Claude sessions, and optionally your shell history…",
            "",
            " How you use Claude here ‹ Mixed ›",
            "",
            " ☑ Also scan shell history",
            " ☐ Also scan your other repos",
            "",
            continueLine,
            "",
            " ←/→ to change · Enter to continue · Esc to cancel",
        ]
    }

    private let footers = [
        "↑/↓ to navigate · Enter to select · Esc to cancel",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
        "↑/↓ to navigate · Esc to cancel · Enter to select",
    ]

    func testFooterLineByParts() {
        XCTAssertTrue(ChoiceMenu.isFooter(" ↑/↓ to navigate · Enter to select · Esc to cancel"))
        XCTAssertTrue(ChoiceMenu.isFooter("←/→ to change · Enter to continue · Esc to cancel"))
        XCTAssertTrue(ChoiceMenu.isFooter("Enter to confirm · Esc to cancel"))
        XCTAssertTrue(ChoiceMenu.isFooter("Esc to exit"))
        XCTAssertFalse(ChoiceMenu.isFooter("↑/↓ to navigate · Tab to switch"))
        XCTAssertFalse(ChoiceMenu.isFooter("  案内行は「↑/↓ to navigate · Enter to select · Esc to cancel」です。"))
        XCTAssertFalse(ChoiceMenu.isFooter("✻ Crunched for 25s · done 1:26 AM"))
    }

    func testOfferAboveInputBoxBlocksAndParses() throws {
        for footer in footers {
            let screen = offer(footer: footer) + inputBox
            XCTAssertEqual(InputBlock.detect(screen: screen), .menu, footer)
            let menu = try XCTUnwrap(ChoiceMenu.parse(screen: screen), footer)
            XCTAssertEqual(menu.options.map(\.label), ["Yes", "Not now", "Don't show again"])
            XCTAssertEqual(menu.cursor, 0)
            XCTAssertEqual(menu.footer, footer)
            XCTAssertTrue(menu.context.contains("Teach auto mode about your environment?"))
            XCTAssertFalse(menu.context.contains("⏺ 完了しました。"))
            XCTAssertNil(ChoiceMenu.unreadable(screen: screen))
        }
    }

    func testOfferWithoutInputBox() throws {
        for footer in footers {
            let screen = offer(footer: footer)
            XCTAssertEqual(InputBlock.detect(screen: screen), .menu, footer)
            XCTAssertEqual(try XCTUnwrap(ChoiceMenu.parse(screen: screen), footer).options.count, 3)
        }
    }

    func testOfferWithBlankLineAboveInputBox() {
        let screen = offer(footer: footers[0]) + ["", ""] + inputBox
        XCTAssertEqual(InputBlock.detect(screen: screen), .menu)
    }

    func testCursorMovesInOverlay() throws {
        var screen = offer(footer: footers[0]) + inputBox
        screen[8] = "   1. Yes"
        screen[9] = " ❯ 2. Not now"
        XCTAssertEqual(try XCTUnwrap(ChoiceMenu.parse(screen: screen)).cursor, 1)
    }

    func testWizardAboveInputBoxIsUnreadable() throws {
        for line in [" Continue", " ❯ Continue"] {
            for screen in [wizard(continueLine: line) + inputBox, wizard(continueLine: line)] {
                XCTAssertEqual(InputBlock.detect(screen: screen), .menu, line)
                if screen.count > wizard(continueLine: line).count {
                    // 番号の無い行を選択肢と読むと押し方が違うので、重ね表示ではカードにしない。
                    XCTAssertNil(ChoiceMenu.parse(screen: screen), line)
                    let unreadable = try XCTUnwrap(ChoiceMenu.unreadable(screen: screen), line)
                    XCTAssertFalse(unreadable.cancelExits)
                    XCTAssertTrue(unreadable.lines.contains("←/→ to change · Enter to continue · Esc to cancel"))
                }
            }
        }
    }

    func testPlainInputBoxDoesNotBlock() {
        let screen = ["⏺ done", "", "✻ Crunched for 3s"] + inputBox
        XCTAssertNil(InputBlock.detect(screen: screen))
        XCTAssertNil(ChoiceMenu.unreadable(screen: screen))
    }

    func testFooterLikeTextInConversationDoesNotBlock() {
        let quotedEarlier = [
            "⏺ 案内行は次の形です:",
            "  ↑/↓ to navigate · Enter to select · Esc to cancel",
            "  これで選びます。",
            "  ほかに質問があればどうぞ。",
            "  以上です。",
            "",
            "✻ Crunched for 3s",
        ] + inputBox
        XCTAssertNil(InputBlock.detect(screen: quotedEarlier))

        let quotedInline = [
            "⏺ 答えました。",
            "  案内行は「↑/↓ to navigate · Enter to select · Esc to cancel」です。",
        ] + inputBox
        XCTAssertNil(InputBlock.detect(screen: quotedInline))

        // 入力欄の罫線との間に会話の罫線があれば、接していないので重ね表示ではない。
        let ruled = ["⏺ 例:", "  Enter to select · Esc to cancel", rule] + inputBox
        XCTAssertNil(ChoiceMenu.overlayRange(ruled))
    }

    func testTypingFooterTextInInputBoxDoesNotBlock() {
        let screen = ["⏺ done", rule, "❯ Enter to select · Esc to cancel", rule, "  ⏵⏵ auto mode on"]
        XCTAssertNil(InputBlock.detect(screen: screen))
    }

    // MARK: - セッションファイルの waitingFor

    private let dialog = SessionWaiting(status: "waiting", waitingFor: "dialog open")

    func testDialogOpenFromSessionFile() {
        XCTAssertTrue(dialog.isDialogOpen)
        XCTAssertTrue(SessionWaiting(status: "waiting", waitingFor: "sandbox request").isDialogOpen)
        XCTAssertFalse(SessionWaiting(status: "busy", waitingFor: "dialog open").isDialogOpen)
        XCTAssertFalse(SessionWaiting(status: "waiting", waitingFor: "input needed").isDialogOpen)
        XCTAssertFalse(SessionWaiting(status: "idle", waitingFor: nil).isDialogOpen)
    }

    func testDialogOpenBlocksSendWithEscCard() throws {
        let idle = ["⏺ done"] + inputBox
        XCTAssertEqual(InputBlock.detect(screen: idle, waiting: dialog), .menu)
        XCTAssertNil(InputBlock.detect(screen: idle, waiting: SessionWaiting(status: "idle", waitingFor: nil)))
        XCTAssertNil(InputBlock.detect(screen: idle, waiting: nil))

        let card = try XCTUnwrap(ChoiceMenu.unreadable(screen: idle, waiting: dialog))
        XCTAssertTrue(card.isDialog)
        XCTAssertFalse(card.cancelExits)
        XCTAssertNil(ChoiceMenu.unreadable(screen: idle, waiting: nil))
    }

    func testScreenTakesPrecedenceOverSessionFile() throws {
        let readable = offer(footer: footers[0]) + inputBox
        XCTAssertEqual(InputBlock.detect(screen: readable, waiting: dialog), .menu)
        XCTAssertNil(ChoiceMenu.unreadable(screen: readable, waiting: dialog))

        let wizardScreen = wizard(continueLine: " Continue") + inputBox
        XCTAssertFalse(try XCTUnwrap(ChoiceMenu.unreadable(screen: wizardScreen, waiting: dialog)).isDialog)

        let permission = [rule, " Bash command", "   ls", " Do you want to proceed?", " ❯ 1. Yes", "   2. No"]
        XCTAssertEqual(InputBlock.detect(screen: permission, waiting: dialog), .permission)
        XCTAssertNil(ChoiceMenu.unreadable(screen: permission, waiting: dialog))
    }

    func testSessionFileFieldsAreRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = #"{"pid":4242,"sessionId":"s1","cwd":"/a","startedAt":1,"status":"waiting","waitingFor":"dialog open"}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent("4242.json"))

        let record = try XCTUnwrap(ClaudeSessionRegistry(directory: directory).record(forPid: 4242))
        XCTAssertTrue(record.waiting.isDialogOpen)
        let raw = try XCTUnwrap(SessionInventory.scan(directory: directory, isAlive: { _ in true }).first)
        XCTAssertEqual(raw.waiting, dialog)
    }
}

final class PasteCheckTests: XCTestCase {
    func testJudge() {
        XCTAssertEqual(PasteCheck.judge(before: "", after: ""), .missing)
        XCTAssertEqual(PasteCheck.judge(before: nil, after: ""), .missing)
        XCTAssertEqual(PasteCheck.judge(before: "", after: "hello"), .pasted)
        // 長文は畳まれるので本文との一致では見ない。
        XCTAssertEqual(PasteCheck.judge(before: "", after: "[Pasted text #1 +20 lines]"), .pasted)
        XCTAssertEqual(PasteCheck.judge(before: "[Image #1]", after: "[Image #1]"), .missing)
        XCTAssertEqual(PasteCheck.judge(before: "[Image #1]", after: "[Image #1] hi"), .pasted)
        XCTAssertEqual(PasteCheck.judge(before: "", after: nil), .unknown)
    }

    func testNotPastedRestoresDraft() throws {
        XCTAssertTrue(SendCompletion.notPasted(imagesPasted: false).restoresDraft)
        let notice = try XCTUnwrap(SendCompletion.notPasted(imagesPasted: false).notice)
        XCTAssertTrue(notice.contains("端末の入力欄に入りませんでした"))
        XCTAssertFalse(notice.contains("[Image #N]"))
        XCTAssertTrue(try XCTUnwrap(SendCompletion.notPasted(imagesPasted: true).notice).contains("[Image #N]"))
        XCTAssertNotNil(SendCompletion.notPasted(imagesPasted: false).remoteNotice)
    }
}
