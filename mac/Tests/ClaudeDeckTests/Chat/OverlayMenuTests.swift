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

    func testFooterInConversationAboveInputBoxDoesNotBlock() {
        let quoted = [
            "⏺ 案内行は次の形です:",
            "  ↑/↓ to navigate · Enter to select · Esc to cancel",
            "",
            "✻ Crunched for 3s",
        ] + inputBox
        XCTAssertNil(ChoiceMenu.overlayRange(quoted))
        XCTAssertNil(InputBlock.detect(screen: quoted))
        // 上に罫線（前の表示の名残）があっても、間に会話・ステータス行があれば重ね表示ではない。
        XCTAssertNil(InputBlock.detect(screen: [rule] + quoted))

        for wrapped in ["  Esc to cancel を押せば取りやめられます。", "  Enter to confirm で確定します。"] {
            let screen = ["⏺ 選択メニューでは、やめたい時に", wrapped] + inputBox
            XCTAssertNil(InputBlock.detect(screen: screen), wrapped)
            XCTAssertNil(InputBlock.detect(screen: [rule] + screen), wrapped)
            XCTAssertNil(ChoiceMenu.unreadable(screen: screen), wrapped)
        }
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
        // 入力欄が見えない（ダイアログが画面を占めている）時は waitingFor だけで止める。
        let hidden = ["⏺ done", "", " Some dialog we cannot read"]
        XCTAssertEqual(InputBlock.detect(screen: hidden, waiting: dialog, screenChangedAt: nil), .menu)
        XCTAssertNil(InputBlock.detect(screen: hidden, waiting: SessionWaiting(status: "idle", waitingFor: nil), screenChangedAt: nil))
        XCTAssertNil(InputBlock.detect(screen: hidden, waiting: nil, screenChangedAt: nil))

        let card = try XCTUnwrap(ChoiceMenu.unreadable(screen: hidden, waiting: dialog, screenChangedAt: nil))
        XCTAssertTrue(card.isDialog)
        XCTAssertFalse(card.cancelExits)
        XCTAssertNil(ChoiceMenu.unreadable(screen: hidden, waiting: nil, screenChangedAt: nil))
    }

    func testStaleDialogOpenWithPlainInputBoxDoesNotBlock() {
        let idle = ["⏺ done", "", "✻ Crunched for 3s"] + inputBox
        XCTAssertTrue(InputBox.isPlainEmpty(screen: idle))
        let openedAt = Date(timeIntervalSince1970: 1_000)
        let stale = SessionWaiting(status: "waiting", waitingFor: "dialog open", statusUpdatedAt: 1_000_000)

        // 閉じた後に画面が描き替わったのに waitingFor が残っている。
        XCTAssertNil(InputBlock.detect(screen: idle, waiting: stale, screenChangedAt: openedAt.addingTimeInterval(5)))
        XCTAssertNil(ChoiceMenu.unreadable(screen: idle, waiting: stale, screenChangedAt: openedAt.addingTimeInterval(5)))
        // 時刻が分からなければ通常の入力欄を信じる。
        XCTAssertNil(InputBlock.detect(screen: idle, waiting: dialog, screenChangedAt: nil))
        // 画面の最後の変化と同じ頃か後に書かれた waitingFor は信じる。
        XCTAssertEqual(InputBlock.detect(screen: idle, waiting: stale, screenChangedAt: openedAt.addingTimeInterval(0.3)), .menu)
        XCTAssertEqual(InputBlock.detect(screen: idle, waiting: stale, screenChangedAt: openedAt.addingTimeInterval(-2)), .menu)

        // 入力欄に書きかけがあれば通常の空の入力欄ではない。例文だけなら空。
        XCTAssertFalse(InputBox.isPlainEmpty(screen: ["⏺ done", rule, "❯ hello", rule]))
        XCTAssertTrue(InputBox.isPlainEmpty(screen: ["⏺ done", rule, "❯ Try \"fix lint errors\"", rule]))
    }

    func testWizardWithStaleTimeStillBlocks() throws {
        let stale = SessionWaiting(status: "waiting", waitingFor: "dialog open", statusUpdatedAt: 1_000_000)
        let later = Date(timeIntervalSince1970: 1_060)
        for screen in [wizard(continueLine: " Continue") + inputBox,
                       // 案内行が読めない形に変わっても、入力欄の上に罫線で閉じた塊があれば通常の入力欄ではない。
                       Array(wizard(continueLine: " Continue").dropLast()) + ["", " (unknown hint)"] + inputBox] {
            XCTAssertFalse(InputBox.isPlainEmpty(screen: screen))
            XCTAssertEqual(InputBlock.detect(screen: screen, waiting: stale, screenChangedAt: later), .menu)
            XCTAssertNotNil(ChoiceMenu.unreadable(screen: screen, waiting: stale, screenChangedAt: later))
        }
    }

    func testScreenTakesPrecedenceOverSessionFile() throws {
        let readable = offer(footer: footers[0]) + inputBox
        XCTAssertEqual(InputBlock.detect(screen: readable, waiting: dialog, screenChangedAt: nil), .menu)
        XCTAssertNil(ChoiceMenu.unreadable(screen: readable, waiting: dialog, screenChangedAt: nil))

        let wizardScreen = wizard(continueLine: " Continue") + inputBox
        XCTAssertFalse(try XCTUnwrap(ChoiceMenu.unreadable(screen: wizardScreen, waiting: dialog, screenChangedAt: nil)).isDialog)

        let permission = [rule, " Bash command", "   ls", " Do you want to proceed?", " ❯ 1. Yes", "   2. No"]
        XCTAssertEqual(InputBlock.detect(screen: permission, waiting: dialog, screenChangedAt: nil), .permission)
        XCTAssertNil(ChoiceMenu.unreadable(screen: permission, waiting: dialog, screenChangedAt: nil))
    }

    func testSessionFileFieldsAreRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = #"{"pid":4242,"sessionId":"s1","cwd":"/a","startedAt":1,"status":"waiting","waitingFor":"dialog open"}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent("4242.json"))

        let record = try XCTUnwrap(ClaudeSessionRegistry(directory: directory).record(forPid: 4242))
        XCTAssertTrue(record.waiting.isDialogOpen)
        XCTAssertNil(record.statusUpdatedAt)
    }

    func testMistypedWaitingFieldsKeepRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = [
            #"{"pid":4243,"sessionId":"s2","cwd":"/a","status":3,"waitingFor":{"kind":"dialog"},"statusUpdatedAt":"x"}"#,
            #"{"pid":4243,"sessionId":"s2","cwd":"/a","status":null,"waitingFor":["dialog open"],"statusUpdatedAt":{}}"#,
        ]
        for json in samples {
            try Data(json.utf8).write(to: directory.appendingPathComponent("4243.json"))
            let record = try XCTUnwrap(ClaudeSessionRegistry(directory: directory).record(forPid: 4243), json)
            XCTAssertEqual(record.sessionId, "s2")
            XCTAssertEqual(record.cwd, "/a")
            XCTAssertNil(record.status)
            XCTAssertNil(record.waitingFor)
            XCTAssertNil(record.statusUpdatedAt)
            XCTAssertFalse(record.waiting.isDialogOpen)
        }
        let json = #"{"pid":4243,"sessionId":"s2","status":"waiting","waitingFor":"dialog open","statusUpdatedAt":1791286354878}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent("4243.json"))
        let record = try XCTUnwrap(ClaudeSessionRegistry(directory: directory).record(forPid: 4243))
        XCTAssertEqual(record.statusUpdatedAt, 1791286354878)
        XCTAssertTrue(record.waiting.isDialogOpen)
    }
}

final class PasteCheckTests: XCTestCase {
    func testJudge() {
        XCTAssertEqual(PasteCheck.judge(before: "", after: "", body: "hello"), .missing)
        XCTAssertEqual(PasteCheck.judge(before: nil, after: "", body: "hello"), .missing)
        XCTAssertEqual(PasteCheck.judge(before: "", after: "hello", body: "hello"), .pasted)
        // 長文は畳まれるので本文との一致では見ない。
        XCTAssertEqual(PasteCheck.judge(before: "", after: "[Pasted text #1 +20 lines]", body: "long"), .pasted)
        XCTAssertEqual(PasteCheck.judge(before: "[Image #1]", after: "[Image #1]", body: "hi"), .missing)
        XCTAssertEqual(PasteCheck.judge(before: "[Image #1]", after: "[Image #1] hi", body: "hi"), .pasted)
        XCTAssertEqual(PasteCheck.judge(before: "", after: nil, body: "hi"), .unknown)
    }

    func testPlaceholderShapedBodyIsNotJudgedMissing() {
        // 入っても例文と同じ形なので InputBox.text は空を返す。確かめられないので従来どおり送る。
        let plain = #"Try "fix lint errors""#
        XCTAssertEqual(InputBox.text(screen: ["─────────", "❯ " + plain, "─────────"]), "")
        XCTAssertEqual(PasteCheck.judge(before: "", after: "", body: plain), .unknown)
        XCTAssertEqual(PasteCheck.judge(before: "", after: "", body: "\u{1b}[200~" + plain + "\u{1b}[201~"), .unknown)
        XCTAssertEqual(PasteCheck.judge(before: "", after: "", body: "Try \"a\nb\""), .missing)
        XCTAssertEqual(PasteCheck.judge(before: "", after: "", body: "Try it"), .missing)
    }

    func testExtraWaitGrowsWithLengthAndIsCapped() {
        XCTAssertEqual(PasteCheck.extraWait(bodyLength: 10), 1.005, accuracy: 0.001)
        XCTAssertGreaterThan(PasteCheck.extraWait(bodyLength: 4000), PasteCheck.extraWait(bodyLength: 100))
        XCTAssertEqual(PasteCheck.extraWait(bodyLength: 1_000_000), 4.0)
    }

    func testLeftoverCheck() {
        XCTAssertTrue(LeftoverCheck.none.decide(box: "x") == (.send, .none))
        // 1 回だけ知らせる。
        XCTAssertTrue(LeftoverCheck.warnOnce.decide(box: "x") == (.refuse(strict: false), .none))
        XCTAssertTrue(LeftoverCheck.warnOnce.decide(box: "") == (.send, .none))
        XCTAssertTrue(LeftoverCheck.warnOnce.decide(box: nil) == (.send, .warnOnce))
        // 貼り付けが入らなかった後は、遅れて入った本文が消えるまで何度でも止める。
        let strict = LeftoverCheck.untilClear(baseline: "")
        XCTAssertTrue(strict.decide(box: "hello") == (.refuse(strict: true), strict))
        XCTAssertTrue(strict.decide(box: nil) == (.refuse(strict: true), strict))
        XCTAssertTrue(strict.decide(box: "") == (.send, .none))
        let images = LeftoverCheck.untilClear(baseline: "[Image #1]")
        XCTAssertTrue(images.decide(box: "[Image #1]") == (.send, .none))
        XCTAssertTrue(images.decide(box: "[Image #1] hello") == (.refuse(strict: true), images))
    }

    func testNotPastedRestoresDraft() throws {
        XCTAssertTrue(SendCompletion.notPasted(imagesPasted: false).restoresDraft)
        let notice = try XCTUnwrap(SendCompletion.notPasted(imagesPasted: false).notice)
        XCTAssertTrue(notice.contains("端末の入力欄に入りませんでした"))
        XCTAssertTrue(notice.contains("遅れて端末に入った場合は、次の送信の前に残りとして知らせます"))
        XCTAssertTrue(try XCTUnwrap(SendCompletion.notPasted(imagesPasted: false).remoteNotice).contains("遅れて端末に入った場合"))
        XCTAssertFalse(notice.contains("[Image #N]"))
        XCTAssertTrue(try XCTUnwrap(SendCompletion.notPasted(imagesPasted: true).notice).contains("[Image #N]"))
        XCTAssertNotNil(SendCompletion.notPasted(imagesPasted: false).remoteNotice)
    }
}
