import CryptoKit
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

/// 実画面の描き方の読み取りの見本。入力欄の行を v2.1.309 の案内と同じく、先頭 1 文字を反転（カーソル）・残りを薄字にする。
enum ScreenTones {
    static func faintBox(_ screen: [String], cursorFirst: Bool = true) -> CellToneReader {
        let rows = boxRows(screen)
        return { row in
            let characters = Array(screen[row])
            guard rows.contains(row) else { return characters.map { _ in .plain } }
            var first = true
            return characters.map { character in
                if character.isWhitespace || character == "❯" { return .plain }
                defer { first = false }
                return first && cursorFirst ? .inverse : .dim
            }
        }
    }

    /// 全部が普通の文字（打った本文）。
    static func plain(_ screen: [String]) -> CellToneReader {
        { row in screen.indices.contains(row) ? Array(screen[row]).map { _ in .plain } : nil }
    }

    static func boxRows(_ screen: [String]) -> Set<Int> {
        guard let start = InputBox.promptRow(screen: screen) else { return [] }
        var rows: Set<Int> = [start]
        for index in (start + 1)..<screen.count {
            let line = screen[index].trimmingCharacters(in: .whitespaces)
            if !line.isEmpty, line.allSatisfy({ $0 == "─" }) { break }
            rows.insert(index)
        }
        return rows
    }
}

final class WorkingScreenInputBoxTests: XCTestCase {
    /// キューに積んだメッセージがあると、空欄に薄字の案内が出る。薄字と読めた時は空として読む。
    func testQueuedHintPlaceholdersReadAsEmpty() {
        for hint in ["Press up to edit queued messages",
                     "Press up to select a queued message, then Enter to edit it",
                     "Press up to edit queued messages, Enter to send them immediately",
                     "Press up to select a queued message to edit, or Enter to send them now",
                     "Press Enter to edit the selected message, or up again for history",
                     "Press Enter to edit the selected message, or up again for an older one"] {
            let screen = WorkingScreen.screen(queued: ["次はビルドも確かめて"], box: ["❯\u{00A0}" + hint])
            let box = InputBox.text(screen: screen, tones: ScreenTones.faintBox(screen))
            XCTAssertEqual(box, "", hint)
            XCTAssertNil(InputBlock.detect(screen: screen), hint)
            XCTAssertTrue(LeftoverCheck.untilClear(baseline: "", body: "x").decide(box: box).0 == .send, hint)
        }
        let agent = WorkingScreen.screen(box: ["❯ Message @reviewer…"])
        XCTAssertEqual(InputBox.text(screen: agent, tones: ScreenTones.faintBox(agent)), "")
        // カーソルが無い（全部薄字）時も、次の依頼の候補のような決まっていない文も、薄字なら空。
        let suggestion = WorkingScreen.screen(box: ["❯ run the tests"])
        XCTAssertEqual(InputBox.text(screen: suggestion, tones: ScreenTones.faintBox(suggestion, cursorFirst: false)), "")
    }

    /// 案内と同じ形でも、打った文字（薄字でない）か描き方を読めない時は本文として読む（空と読み違えて二重に貼らないため）。
    func testPlaceholderShapedTextIsBodyUnlessFaint() {
        for lines in [["❯ Press up to edit queued messages"], ["❯ Try \"fix lint errors\""], ["❯ Try \"a", "  b\""]] {
            let screen = WorkingScreen.screen(box: lines)
            let expected = lines.map { $0.replacingOccurrences(of: "❯ ", with: "").trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            XCTAssertEqual(InputBox.text(screen: screen), expected, "描き方を読めない")
            XCTAssertEqual(InputBox.text(screen: screen, tones: ScreenTones.plain(screen)), expected, "打った文字")
        }
        // 一部だけ薄字（打った文字の後ろに候補が続く等）も本文。
        let mixed = WorkingScreen.screen(box: ["❯ Try \"x\""])
        let row = InputBox.promptRow(screen: mixed)
        let partly: CellToneReader = { index in
            let faint = ScreenTones.faintBox(mixed)(index)
            guard index == row, var tones = faint, let last = tones.lastIndex(of: .dim) else { return faint }
            tones[last] = .plain
            return tones
        }
        XCTAssertEqual(InputBox.text(screen: mixed, tones: partly), "Try \"x\"")
        // 1 文字だけの本文にカーソル（反転）が乗っていても、薄字が無ければ空にしない。
        let single = WorkingScreen.screen(box: ["❯ a"])
        let singleRow = InputBox.promptRow(screen: single)
        let cursorOnly: CellToneReader = { index in
            Array(single[index]).map { index == singleRow && $0 == "a" ? .inverse : .plain }
        }
        XCTAssertEqual(InputBox.text(screen: single, tones: cursorOnly), "a")
        // 描き方の行が足りない時も空にしない。
        XCTAssertEqual(InputBox.text(screen: mixed, tones: { _ in [] }), "Try \"x\"")
    }

    /// 2 行の本文が例文と同じ形でも、入ったら「入った」と読んで Enter を送る（空と読み違えて取りやめ、残りの後ろへ同じ本文を貼らないため）。
    func testTwoLinePlaceholderShapedBodyIsNotMissing() {
        let body = "\u{1b}[200~Try \"fix\n lint\"\u{1b}[201~"
        let screen = WorkingScreen.screen(box: ["❯ Try \"fix", "   lint\""])
        let after = InputBox.text(screen: screen, tones: ScreenTones.plain(screen))
        XCTAssertEqual(after, "Try \"fix\nlint\"")
        XCTAssertNotEqual(PasteCheck.judge(before: "", after: after, body: body), .missing)
        // 入力欄の読み取りと同じく 2 行までをつないで案内の形かを見るので、確かめずに送る側になる。
        XCTAssertEqual(PasteCheck.judge(before: "", after: "", body: body), .unknown)
    }

    /// 作業中の画面（返答・スピナー・キューの発話・下の statusLine とエージェント一覧）でも、入力欄の中身だけを読む。
    func testWorkingScreenReadsOnlyTheBox() {
        let empty = WorkingScreen.screen(box: ["❯\u{00A0}"])
        XCTAssertEqual(InputBox.text(screen: empty), "")
        XCTAssertEqual(InputBox.text(screen: empty, tones: ScreenTones.faintBox(empty)), "")
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
        let body = "\u{1b}[200~" + Array(repeating: "長い本文", count: 13).joined(separator: "\n") + "\u{1b}[201~"
        XCTAssertEqual(PasteCheck.judge(before: "", after: after, body: body), .pasted)
        let hintedScreen = WorkingScreen.screen(queued: ["先の依頼"], box: ["❯ Press up to edit queued messages"])
        let hinted = InputBox.text(screen: hintedScreen, tones: ScreenTones.faintBox(hintedScreen))
        XCTAssertEqual(hinted, "")
        XCTAssertEqual(PasteCheck.judge(before: hinted, after: after, body: body), .pasted)
        // 入る前（案内のまま）は入っていない。
        XCTAssertEqual(PasteCheck.judge(before: hinted, after: hinted, body: body), .missing)
        XCTAssertEqual(LeftoverCheck.untilClear(baseline: "", body: PasteCheck.plainText(body)).match(box: after), .folded)
    }

    /// 畳みの印で本文とみなすのは、増えた印が 1 つだけで `+N lines` が本文の改行の数と合う時だけ。
    func testFoldedMatchIsStrict() {
        let fourLines = "一\n二\n三\n四"
        XCTAssertEqual(InputBoxMatch.match(box: "[Pasted text #1 +12 lines][Pasted text #2 +3 lines]",
                                           baseline: "[Pasted text #1 +12 lines]", body: fourLines), .folded)
        XCTAssertEqual(InputBoxMatch.match(box: "[Pasted text #2 +5 lines]", baseline: "", body: fourLines), .none, "行数が合わない")
        XCTAssertEqual(InputBoxMatch.match(box: "[Pasted text #1 +3 lines] [Pasted text #2 +3 lines]", baseline: "", body: fourLines), .none,
                       "増えた印が 2 つ")
        XCTAssertEqual(InputBoxMatch.match(box: "[Pasted text #1 +12 lines]", baseline: "[Pasted text #1 +12 lines]", body: fourLines), .none)
        XCTAssertEqual(InputBoxMatch.match(box: "[Pasted text #3]", baseline: "", body: "改行の無い長文"), .folded)
        XCTAssertEqual(InputBoxMatch.match(box: "[...Truncated text #1 +300 lines...]", baseline: "", body: fourLines), .none)
        // 止めている間に「端末の画面」から入力欄を触ったら、本文が見えているとはみなさない。
        let check = LeftoverCheck.untilClear(baseline: "", body: "本文", id: "s1")
        XCTAssertEqual(check.match(box: "本文"), .text)
        XCTAssertEqual(check.touched.match(box: "本文"), .none)
        XCTAssertEqual(check.touched.lateId, "s1")
        XCTAssertTrue(check.touched.decide(box: "本文").0 == .refuse(strict: true), "触っても止めるのは続ける")
        XCTAssertEqual(LeftoverCheck.warnOnce.touched, .warnOnce)
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
        let lateScreen = WorkingScreen.screen(box: ["❯ " + body])
        let late = InputBox.text(screen: lateScreen, tones: ScreenTones.plain(lateScreen))
        XCTAssertTrue(check.decide(box: late) == (.refuse(strict: true), check))
        XCTAssertEqual(LeftoverChoice.choices(strict: true, escape: check.escape(box: late, unreadableFor: 0)),
                       [.openTerminal, .submitAsIs, .clearInput])
        // キューの案内が出ている空欄（端末で消した・送った後）は空とみなして送る。
        let hintedScreen = WorkingScreen.screen(queued: [body], box: ["❯ Press up to edit queued messages"])
        let hinted = InputBox.text(screen: hintedScreen, tones: ScreenTones.faintBox(hintedScreen))
        let (decision, next) = check.decide(box: hinted)
        XCTAssertEqual(decision, .send)
        check = next
        XCTAssertEqual(check, .none)
    }

    /// 端末から送った本文がどの送信のものかは、本文ではなく送信の印で突き合わせる。
    func testLateId() {
        XCTAssertEqual(LeftoverCheck.untilClear(baseline: "", body: "b", id: "send-1").lateId, "send-1")
        XCTAssertNil(LeftoverCheck.warnOnce.lateId)
        XCTAssertNotEqual(LeftoverCheck.untilClear(baseline: "", body: "b", id: "a"), LeftoverCheck.untilClear(baseline: "", body: "b", id: "c"))
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
        XCTAssertEqual(map["bodyMac"]?.count, 8)
        XCTAssertTrue(map["bodyMac"]?.allSatisfy(\.isHexDigit) ?? false)
        XCTAssertNil(map["bodySha"])
        XCTAssertEqual(map["boxHasBody"], "text")
        XCTAssertEqual(map["boxFolded"], "no")
        XCTAssertEqual(map["boxSameAsBefore"], "no")
        let line = MenuOpsLog.line("refuse", fields, date: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(line.contains("秘密"))
    }

    /// 指紋は起動ごとの鍵付き（素の SHA-256 ではないので、短い本文を辞書で逆算できない）。同じ起動の中では同じ値になる。
    func testFingerprintIsKeyedPerLaunch() {
        let a = SendOpsFields.text("はい", prefix: "b").first { $0.0 == "bMac" }?.1
        XCTAssertEqual(a, SendOpsFields.text("はい", prefix: "b").first { $0.0 == "bMac" }?.1)
        XCTAssertNotEqual(a, SendOpsFields.text("いいえ", prefix: "b").first { $0.0 == "bMac" }?.1)
        let plainSha = SHA256.hash(data: Data("はい".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(a, String(plainSha.prefix(8)))
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
