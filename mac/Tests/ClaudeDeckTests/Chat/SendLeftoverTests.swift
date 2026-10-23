import XCTest
@testable import MonitorKit

/// 作業中（稼働中）の画面を模した見本。v2.1.300 の写し（`Fixtures/ClaudeCode-2.1.300/`）と同じ桁・字下げで、
/// 入力欄まわりは v2.1.309 のバイナリで確かめた描き方（キューに積んだ発話は入力欄の上・空欄の案内は薄字で ❯ の後ろ）をなぞる。
private enum WorkingScreen {
    static let rule = String(repeating: "─", count: 160)

    static let head: [String] = [
        " ▐▛███▜▌   Claude Code v2.1.300",
        "▝▜█████▛▘  Opus 5.5 with high effort · Claude Max",
        "  ▘▘ ▝▝    /tmp/work/app",
        "",
        "❯ テストを直して、終わったら報告してください                                                                                     ",
        "",
        "⏺ Read 3 files (ctrl+o to expand)",
        "",
        "⏺ Bash(swift test 2>&1 | tail -20)",
        "  ⎿  Running…",
        "",
        "✻ Pondering… (42s · ↓ 1.2k tokens · esc to interrupt)",
        "",
    ]

    /// `queued` はキューに積んだ発話（入力欄の上に出る）、`box` は入力欄の行。下に statusLine・モード・裏のエージェント一覧が続く。
    static func screen(queued: [String] = [], box: [String], rows: Int = 40) -> [String] {
        let footer = [
            "  セッション: 49% (リセット: 10分後) | 週間: 51%",
            "  ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt",
            "",
            "  ◯ general-purpose               Listing schemes in Sample.xcodeproj                                    5m 38s · ↓ 85.2k tokens",
        ]
        let body = head + queued.map { "❯ " + $0 } + [rule] + box + [rule] + footer
        return body + Array(repeating: "", count: max(0, rows - body.count))
    }
}

final class WorkingScreenInputBoxTests: XCTestCase {
    /// キューに積んだメッセージがあると、空欄に薄字の案内が出る。空として読む（前は本文と読み、残りがあると止め続けた）。
    func testQueuedHintPlaceholdersReadAsEmpty() {
        for hint in ["Press up to edit queued messages",
                     "Press up to select a queued message, then Enter to edit it",
                     "Press up to edit queued messages, Enter to send them immediately",
                     "Press up to select a queued message to edit, or Enter to send them now",
                     "Press Enter to edit the selected message, or up again for history",
                     "Press Enter to edit the selected message, or up again for an older one"] {
            let screen = WorkingScreen.screen(queued: ["次はビルドも確かめて"], box: ["❯\u{00A0}" + hint])
            XCTAssertEqual(InputBox.text(screen: screen), "", hint)
            XCTAssertNil(InputBlock.detect(screen: screen), hint)
            XCTAssertTrue(LeftoverCheck.untilClear(baseline: "", body: "x").decide(box: InputBox.text(screen: screen)).0 == .send, hint)
        }
        XCTAssertEqual(InputBox.text(screen: WorkingScreen.screen(box: ["❯ Message @reviewer…"])), "")
        // 案内に似ているだけの本文は本文として読む。
        XCTAssertEqual(InputBox.text(screen: WorkingScreen.screen(box: ["❯ Press up to edit queued messages please"])),
                       "Press up to edit queued messages please")
        XCTAssertEqual(InputBox.text(screen: WorkingScreen.screen(box: ["❯ Message @reviewer… と送って"])), "Message @reviewer… と送って")
    }

    /// 作業中の画面（返答・スピナー・キューの発話・下の statusLine とエージェント一覧）でも、入力欄の中身だけを読む。
    func testWorkingScreenReadsOnlyTheBox() {
        XCTAssertEqual(InputBox.text(screen: WorkingScreen.screen(box: ["❯\u{00A0}"])), "")
        let typed = WorkingScreen.screen(queued: ["次はビルドも確かめて"], box: ["❯ 一行目の本文", "  二行目"])
        XCTAssertEqual(InputBox.text(screen: typed), "一行目の本文\n二行目")
        XCTAssertNil(InputBlock.detect(screen: typed))
        XCTAssertEqual(TerminalScreen.mainPane(typed), typed)
        XCTAssertEqual(InputBox.promptRow(screen: typed), WorkingScreen.head.count + 2)
    }

    /// 長い貼り付けは `[Pasted text #N +M lines]` に畳まれる。空欄・案内の出た空欄のどちらからでも「入った」と読む。
    func testFoldedPasteIsJudgedPasted() {
        let folded = WorkingScreen.screen(box: ["❯ [Pasted text #1 +12 lines]"])
        let after = InputBox.text(screen: folded)
        XCTAssertEqual(after, "[Pasted text #1 +12 lines]")
        let body = "\u{1b}[200~" + String(repeating: "長い本文\n", count: 13) + "\u{1b}[201~"
        XCTAssertEqual(PasteCheck.judge(before: "", after: after, body: body), .pasted)
        let hinted = InputBox.text(screen: WorkingScreen.screen(queued: ["先の依頼"], box: ["❯ Press up to edit queued messages"]))
        XCTAssertEqual(PasteCheck.judge(before: hinted, after: after, body: body), .pasted)
        // 入る前（案内のまま）は入っていない。
        XCTAssertEqual(PasteCheck.judge(before: hinted, after: hinted, body: body), .missing)
        XCTAssertTrue(LeftoverCheck.untilClear(baseline: "", body: PasteCheck.plainText(body)).showsBody(box: after))
        // 2 回目の畳みも新しい印として数える。
        XCTAssertTrue(InputBoxMatch.showsBody(box: "[Pasted text #1 +12 lines][Pasted text #2 +3 lines]",
                                              baseline: "[Pasted text #1 +12 lines]", body: "別の長文"))
        XCTAssertFalse(InputBoxMatch.showsBody(box: "[Pasted text #1 +12 lines]", baseline: "[Pasted text #1 +12 lines]", body: "別の長文"))
    }

    /// 写しの選択肢の画面では入力欄を読めない（nil）。記録には画面の形だけを残し、文字は書かない。
    func testFixtureMenuScreenHasNoBoxAndShapeHasNoText() throws {
        for name in ["r2-app-05", "r3-long-11", "r4-wait-16", "r5-combo-22"] {
            let screen = try ScreenFixture.load(name)
            XCTAssertNil(InputBox.text(screen: screen), name)
            let shape = SendOpsFields.shape(screen)
            XCTAssertEqual(shape.first { $0.0 == "footer" }?.1, "yes", name)
            for (_, value) in shape {
                XCTAssertNotNil(Int(value) ?? (["yes", "no", "-"].contains(value) ? 0 : nil), "\(name): \(value)")
            }
        }
    }

    func testShapeOfWorkingScreen() {
        let shape = Dictionary(uniqueKeysWithValues: SendOpsFields.shape(WorkingScreen.screen(queued: ["q"], box: ["❯ 本文"])))
        XCTAssertEqual(shape["rules"], "2")
        XCTAssertEqual(shape["promptsAfterRule"], "1")
        XCTAssertEqual(shape["interrupt"], "yes")
        XCTAssertEqual(shape["replyOrSpinner"], "yes")
        XCTAssertEqual(shape["footer"], "no")
    }

    /// 作業中は出力の描き替えに押されて貼り付けの反映が遅れうるので、長めに待つ。
    func testWorkingWaitsLonger() {
        XCTAssertEqual(PasteCheck.extraWait(bodyLength: 10, working: true) - PasteCheck.extraWait(bodyLength: 10),
                       PasteCheck.workingExtraWait, accuracy: 0.001)
    }
}

final class LeftoverEscapeTests: XCTestCase {
    private let strict = LeftoverCheck.untilClear(baseline: "", body: "テストを直して\n報告して")

    func testShowsBodyIgnoresWrappingAndBaseline() {
        XCTAssertTrue(strict.showsBody(box: "テストを直して\n報告して"))
        // 端末の折り返しで改行・空白の位置が変わっても本文とみなす。
        XCTAssertTrue(strict.showsBody(box: "テストを直し\nて 報告して"))
        XCTAssertTrue(LeftoverCheck.untilClear(baseline: "[Image #1]", body: "見て").showsBody(box: "[Image #1] 見て"))
        XCTAssertFalse(strict.showsBody(box: "別の文"))
        XCTAssertFalse(strict.showsBody(box: ""))
        XCTAssertFalse(strict.showsBody(box: nil))
        XCTAssertFalse(LeftoverCheck.warnOnce.showsBody(box: "テストを直して\n報告して"))
        XCTAssertFalse(LeftoverCheck.untilClear(baseline: "", body: "  ").showsBody(box: "x"))
    }

    func testEscapeStates() {
        XCTAssertNil(strict.escape(box: "", unreadableFor: 0), "空なら送れる")
        XCTAssertNil(LeftoverCheck.untilClear(baseline: "[Image #1]", body: "x").escape(box: "[Image #1]", unreadableFor: 0))
        XCTAssertNil(LeftoverCheck.warnOnce.escape(box: "x", unreadableFor: 99), "1 回だけの知らせには案内を出さない")
        XCTAssertNil(LeftoverCheck.none.escape(box: nil, unreadableFor: 99))
        XCTAssertEqual(strict.escape(box: "テストを直して 報告して", unreadableFor: 0), LeftoverEscape(box: .showsBody, canForce: false))
        XCTAssertEqual(strict.escape(box: "別の文", unreadableFor: 0), LeftoverEscape(box: .other, canForce: false))
        XCTAssertEqual(strict.escape(box: nil, unreadableFor: 29.9), LeftoverEscape(box: .unreadable, canForce: false))
        XCTAssertEqual(strict.escape(box: nil, unreadableFor: LeftoverCheck.forceAfter), LeftoverEscape(box: .unreadable, canForce: true))
    }

    func testUnreadableSpanCountsOnlyWhileUnreadable() {
        var span = UnreadableSpan()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(span.observe(readable: false, now: start), 0)
        XCTAssertEqual(span.observe(readable: false, now: start + 31), 31)
        XCTAssertEqual(span.observe(readable: true, now: start + 32), 0)
        XCTAssertNil(span.since)
        XCTAssertEqual(span.observe(readable: false, now: start + 40), 0)
        span.reset()
        XCTAssertNil(span.since)
    }

    /// 断った時の選択肢: 端末の画面はいつも、そのまま送るは本文が見えている時、確かめずに送るは読めない状態が続いた時だけ。
    func testChoices() {
        XCTAssertEqual(LeftoverChoice.choices(strict: false, escape: nil), [.openTerminal, .clearInput])
        XCTAssertEqual(LeftoverChoice.choices(strict: true, escape: LeftoverEscape(box: .showsBody, canForce: false)),
                       [.openTerminal, .submitAsIs, .clearInput])
        XCTAssertEqual(LeftoverChoice.choices(strict: true, escape: LeftoverEscape(box: .other, canForce: false)),
                       [.openTerminal, .clearInput])
        XCTAssertEqual(LeftoverChoice.choices(strict: true, escape: LeftoverEscape(box: .unreadable, canForce: false)),
                       [.openTerminal, .clearInput])
        XCTAssertEqual(LeftoverChoice.choices(strict: true, escape: LeftoverEscape(box: .unreadable, canForce: true)),
                       [.openTerminal, .clearInput, .forceSend])
    }

    /// 入らなかった送信 → 遅れて入った → 断る（そのまま送るを出す）→ そのまま送ったら外れて次は送れる、の流れ。
    func testLateArrivalFlow() {
        let body = "テストを直して"
        var check = LeftoverCheck.untilClear(baseline: "", body: body)
        // 遅れて入った本文が見えている間は何度でも止め、そのまま送るを出す。
        let late = InputBox.text(screen: WorkingScreen.screen(box: ["❯ " + body]))
        XCTAssertTrue(check.decide(box: late) == (.refuse(strict: true), check))
        XCTAssertEqual(LeftoverChoice.choices(strict: true, escape: check.escape(box: late, unreadableFor: 0)),
                       [.openTerminal, .submitAsIs, .clearInput])
        // キューの案内が出ている空欄（端末で消した・送った後）は空とみなして送る。
        let hinted = InputBox.text(screen: WorkingScreen.screen(queued: [body], box: ["❯ Press up to edit queued messages"]))
        let (decision, next) = check.decide(box: hinted)
        XCTAssertEqual(decision, .send)
        check = next
        XCTAssertEqual(check, .none)
    }

    func testSameSend() {
        XCTAssertTrue(ComposerRestore.isSameSend(restored: "本文\n", submitted: "本文"))
        XCTAssertTrue(ComposerRestore.isSameSend(restored: "本文", submitted: "本文\n\n添付:\n/tmp/a.txt"))
        XCTAssertTrue(ComposerRestore.isSameSend(restored: "", submitted: "添付:\n/tmp/a.txt"))
        XCTAssertFalse(ComposerRestore.isSameSend(restored: "本文", submitted: "iPhone から送った別の本文"))
        XCTAssertFalse(ComposerRestore.isSameSend(restored: "本文", submitted: "本文の続き"))
        XCTAssertEqual(LeftoverCheck.untilClear(baseline: "", body: "b").lateBody, "b")
        XCTAssertNil(LeftoverCheck.warnOnce.lateBody)
    }

    func testDraftRemovingRestoredText() {
        XCTAssertEqual(ComposerRestore.draft(removing: "本文", from: "本文"), "")
        let merged = ComposerRestore.draft(restoring: "本文", current: "書き足し")
        XCTAssertEqual(ComposerRestore.draft(removing: "本文", from: merged), "書き足し")
        XCTAssertNil(ComposerRestore.draft(removing: "本文", from: "本文を直した"))
        XCTAssertNil(ComposerRestore.draft(removing: "本文", from: ""))
    }
}

final class SendOpsFieldsTests: XCTestCase {
    /// 記録には本文を書かず、長さ・行数・SHA-256 の先頭 8 桁だけにする。
    func testFieldsNeverContainText() {
        let secret = "秘密の本文 password=hunter2\n二行目"
        let fields = SendOpsFields.text(secret, prefix: "body") + SendOpsFields.box(secret, body: secret, baseline: "")
        for (_, value) in fields {
            XCTAssertFalse(value.contains("秘密"), value)
            XCTAssertFalse(value.contains("hunter2"), value)
        }
        let map = Dictionary(fields, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(map["bodyLen"], "\(secret.count)")
        XCTAssertEqual(map["bodyLines"], "2")
        XCTAssertEqual(map["bodySha"]?.count, 8)
        XCTAssertTrue(map["bodySha"]?.allSatisfy(\.isHexDigit) ?? false)
        XCTAssertEqual(map["boxHasBody"], "yes")
        XCTAssertEqual(map["boxFolded"], "no")
        XCTAssertEqual(map["boxSameAsBefore"], "no")
        let line = MenuOpsLog.line("refuse", fields, date: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(line.contains("秘密"))
    }

    func testBoxStates() {
        XCTAssertEqual(SendOpsFields.box(nil, body: "x", baseline: nil).map(\.1), ["unreadable"])
        XCTAssertEqual(SendOpsFields.box("", body: "x", baseline: nil).map(\.1), ["empty"])
        let folded = Dictionary(SendOpsFields.box("[Image #1] [Pasted text #1 +5 lines]", body: nil, baseline: nil),
                                uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(folded["boxFolded"], "yes")
        XCTAssertEqual(folded["boxImages"], "1")
        XCTAssertNil(folded["boxHasBody"])
    }

    func testSendLogFileIsSeparateFromMenuLog() {
        XCTAssertEqual(MenuOpsLog.send.url.lastPathComponent, "send-ops.log")
        XCTAssertEqual(MenuOpsLog.send.url.deletingLastPathComponent(), MenuOpsLog.shared.url.deletingLastPathComponent())
    }
}

/// 入力欄を消すキーの組（Ctrl-E・Ctrl-K・Ctrl-U）が、カーソルの位置によらず複数行の入力欄を空にできるか。
/// v2.1.309 の入力欄の実装（Ctrl-U は行頭まで、行頭なら前の改行を消す・Ctrl-K は行末まで、行末なら次の改行を消す・Ctrl-E は行末へ）を写した見本で確かめる。
final class ClearInputRoundTests: XCTestCase {
    private struct Editor {
        var text: [Character]
        var cursor: Int

        mutating func apply(_ key: String) {
            switch key {
            case "\u{05}":
                while cursor < text.count, text[cursor] != "\n" { cursor += 1 }
            case "\u{0B}":
                if cursor < text.count, text[cursor] == "\n" {
                    text.remove(at: cursor)
                } else {
                    var end = cursor
                    while end < text.count, text[end] != "\n" { end += 1 }
                    text.removeSubrange(cursor..<end)
                }
            case "\u{15}":
                if cursor > 0, text[cursor - 1] == "\n" {
                    text.remove(at: cursor - 1)
                    cursor -= 1
                } else {
                    var start = cursor
                    while start > 0, text[start - 1] != "\n" { start -= 1 }
                    text.removeSubrange(start..<cursor)
                    cursor = start
                }
            default:
                XCTFail("消すキー以外: \(key.unicodeScalars.map(\.value))")
            }
        }
    }

    func testRoundsClearMultilineTextFromAnyCursor() {
        let samples = ["一行だけ", "一行目\n二行目\n三行目", "\n\n空行を挟む\n\n", "[Pasted text #1 +20 lines]", "[Image #1] 本文\n続き"]
        for sample in samples {
            let characters = Array(sample)
            let lines = sample.split(separator: "\n", omittingEmptySubsequences: false).count
            for cursor in 0...characters.count {
                var editor = Editor(text: characters, cursor: cursor)
                var rounds = 0
                while !editor.text.isEmpty, rounds < PTYInput.clearMaxRounds {
                    PTYInput.clearInputRound.forEach { editor.apply($0) }
                    rounds += 1
                }
                XCTAssertTrue(editor.text.isEmpty, "\(sample) @\(cursor)")
                // 行ごとに 2 組あれば足りる（上限の範囲に収まる）。
                XCTAssertLessThanOrEqual(rounds, lines * 2, "\(sample) @\(cursor)")
            }
        }
    }

    /// 消すキーに中断（Esc・Ctrl-C）や送信（Enter）を含めない。
    func testRoundHasNoInterruptOrSubmit() {
        for key in PTYInput.clearInputRound {
            XCTAssertFalse(["\u{1b}", "\u{03}", "\r", "\n", "\u{0C}"].contains(key))
            XCTAssertEqual(key.unicodeScalars.count, 1)
        }
    }

    func testTerminalKeyClearInput() {
        XCTAssertNil(TerminalKey.clearInput.sequence(applicationCursor: false))
        XCTAssertFalse(TerminalKey.clearInput.movesCursor)
        XCTAssertEqual(TerminalKey.clearInput.label, "入力欄を消す")
        XCTAssertFalse(TerminalKey.all.contains(.clearInput), "キーボードの 1 キーではないので表に入れない")
    }
}
