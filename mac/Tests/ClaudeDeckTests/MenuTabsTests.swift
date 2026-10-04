import XCTest
@testable import MonitorKit

/// AskUserQuestion の複数選択・複数の問い（タブ）の画面。v2.1.286 の描画（TS / s5 / FF / l5）をなぞった写し。
private enum Fixture {
    static let rule = String(repeating: "─", count: 60)
    static let tabLine = "←  ☒ 対応範囲  ✔ Submit  →"

    /// 実機で読み違えた画面（複数選択・問いが 1 つ・問いが 3 行に折り返し、❯ は 3 番目）。
    static func multiSelect(cursorRow: String = "❯ 3. [✔] App Store Connect", typeRow: String = "  4. [ ] Type something",
                            submitRow: String = "     Submit") -> [String] {
        [
            "❯ 次の内容です。オランダ語にも対応させて欲しい。",
            "",
            "⏺ フランス語対応は 3 Issue に分けて進めました。",
            "",
            rule,
            tabLine,
            "",
            "│ フランス語対応は iOS (#324)・LP (#325)・App Store Connect (#326) の 3 Issue に分けて進めました。オラ",
            "│ ンダ語はどこまで対応しますか？(なお「次の内容です」の後に貼り付けるつもりの内容があれば、Other",
            "│ から送ってください)",
            "",
            "  1. [✔] iOS アプリ",
            "       Localizable.xcstrings / InfoPlist.xcstrings に nl を追加し、言語設定に Nederlands を足す",
            "  2. [✔] LP サイト",
            "       site/ に /nl を追加（規約・プライバシーのリンク先も含む）",
            cursorRow,
            "       nl-NL のストアページ（説明文・キーワード等）を追加。外部への書き込みなので実行前に文面を確認します",
            typeRow,
            submitRow,
            rule,
            "  5. Chat about this",
            "",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
            "", "",
        ]
    }

    static let question = "フランス語対応は iOS (#324)・LP (#325)・App Store Connect (#326) の 3 Issue に分けて進めました。"
        + "オランダ語はどこまで対応しますか？(なお「次の内容です」の後に貼り付けるつもりの内容があれば、Otherから送ってください)"

    /// 問いが 2 つ（1 つ目は単一選択）。
    static func twoQuestionsFirst(cursor: Int = 0) -> [String] {
        [
            rule,
            "←  ☐ 言語  ☐ 範囲  ✔ Submit  →",
            "",
            "どの言語を足しますか？",
            "",
            (cursor == 0 ? "❯" : " ") + " 1. オランダ語",
            "     nl",
            (cursor == 1 ? "❯" : " ") + " 2. ドイツ語",
            "     de",
            "  3. Type something.",
            rule,
            "  4. Chat about this",
            "",
            "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
        ]
    }

    /// 問いが 2 つの 2 つ目（複数選択）。最後の問いではないので「Next」ではなく「Submit」。
    static var twoQuestionsSecond: [String] {
        [
            rule,
            "←  ☒ 言語  ☐ 範囲  ✔ Submit  →",
            "",
            "どこまで対応しますか？",
            "",
            "❯ 1. [ ] iOS アプリ",
            "  2. [ ] LP サイト",
            "  3. [ ] Type something",
            "     Submit",
            rule,
            "  4. Chat about this",
            "",
            "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
        ]
    }

    /// Submit タブ（回答の確認）。
    static var review: [String] {
        [
            rule,
            "←  ☒ 言語  ☒ 範囲  ✔ Submit  →",
            "",
            "Review your answers",
            "",
            " どの言語を足しますか？",
            "   → オランダ語",
            " どこまで対応しますか？",
            "   → iOS アプリ, LP サイト",
            "",
            "Ready to submit your answers?",
            "",
            "❯ 1. Submit answers",
            "  2. Cancel",
        ]
    }

    /// 行の中の `text` の文字位置に背景色が付いている、という読み取り結果。
    static func highlight(row: Int, line: String, text: String) -> (Int) -> [Bool]? {
        let characters = Array(line)
        let needle = Array(text)
        let start = (0...(characters.count - needle.count)).first { Array(characters[$0..<($0 + needle.count)]) == needle }!
        let flags = characters.indices.map { (start - 1)..<(start + needle.count + 1) ~= $0 }
        return { $0 == row ? flags : Array(repeating: false, count: 80) }
    }
}

final class MenuTabsParseTests: XCTestCase {
    func testTabLine() throws {
        let (tabs, ranges) = try XCTUnwrap(MenuTabs.parse(Fixture.tabLine))
        XCTAssertEqual(tabs.tabs, [.init(title: "対応範囲", answered: true)])
        XCTAssertTrue(tabs.hasSubmit)
        XCTAssertTrue(tabs.hasArrows)
        XCTAssertNil(tabs.current)
        XCTAssertEqual(ranges.count, 2)
        let characters = Array(Fixture.tabLine)
        XCTAssertEqual(String(characters[ranges[0]]), "☒ 対応範囲")
        XCTAssertEqual(String(characters[ranges[1]]), "✔ Submit")

        let two = try XCTUnwrap(MenuTabs.parse("  ←  ☐ 言語  ☒ Scope of work  ✔ Submit  →  ")).0
        XCTAssertEqual(two.tabs.map(\.title), ["言語", "Scope of work"])
        XCTAssertEqual(two.tabs.map(\.answered), [false, true])
    }

    func testNonTabLines() {
        XCTAssertNil(MenuTabs.parse("どの言語を足しますか？"))
        XCTAssertNil(MenuTabs.parse("← 戻る →"))
        XCTAssertNil(MenuTabs.parse("✔ Submit"))
        // 矢印が無いのは問いが 1 つの単一選択だけ。
        XCTAssertNil(MenuTabs.parse("☐ 言語  ☐ 範囲"))
        XCTAssertNil(MenuTabs.parse("☐ 言語  ✔ Submit"))
        XCTAssertNil(MenuTabs.parse("←  ☐ 言語  ✔ Done  →"))
    }

    func testMoveAvailability() {
        var tabs = MenuTabs(tabs: [.init(title: "a", answered: false), .init(title: "b", answered: false)], hasSubmit: true, hasArrows: true)
        XCTAssertTrue(tabs.canMoveNext)
        XCTAssertTrue(tabs.canMovePrevious)
        tabs.current = 0
        XCTAssertFalse(tabs.canMovePrevious)
        tabs.current = 2
        XCTAssertTrue(tabs.isOnSubmit)
        XCTAssertFalse(tabs.canMoveNext)
    }
}

final class MultiSelectMenuTests: XCTestCase {
    /// 実機のスクリーンショットの画面。Submit を選択肢の説明と読まず、折り返した問いを 1 つにまとめる。
    func testScreenshotScreen() throws {
        let menu = try XCTUnwrap(ChoiceMenu.parse(screen: Fixture.multiSelect()))
        XCTAssertEqual(menu.question, Fixture.question)
        XCTAssertEqual(menu.context, [])
        XCTAssertEqual(menu.options.map(\.label), ["iOS アプリ", "LP サイト", "App Store Connect", "Type something", "Submit", "Chat about this"])
        XCTAssertEqual(menu.options.map(\.number), [1, 2, 3, 4, nil, 5])
        XCTAssertEqual(menu.options.map(\.checked), [true, true, true, false, nil, nil])
        XCTAssertEqual(menu.options.map(\.isSubmit), [false, false, false, false, true, false])
        XCTAssertEqual(menu.options.map(\.isFreeText), [false, false, false, true, false, false])
        XCTAssertEqual(menu.options[3].detail, [])
        XCTAssertEqual(menu.options[2].detail, ["nl-NL のストアページ（説明文・キーワード等）を追加。外部への書き込みなので実行前に文面を確認します"])
        XCTAssertEqual(menu.cursor, 2)
        XCTAssertTrue(menu.isMultiSelect)
        XCTAssertFalse(menu.isReview)
        XCTAssertEqual(menu.tabs?.tabs.map(\.title), ["対応範囲"])
        XCTAssertEqual(menu.tabs?.hasSubmit, true)
    }

    func testCurrentTabFromHighlight() throws {
        let screen = Fixture.multiSelect()
        let menu = try XCTUnwrap(ChoiceMenu.parse(screen: screen, highlight: Fixture.highlight(row: 5, line: Fixture.tabLine, text: "☒ 対応範囲")))
        XCTAssertEqual(menu.tabs?.current, 0)
        // 今のタブは照合に使わない（読めた時と読めなかった時で同じメニュー）。
        XCTAssertTrue(menu.sameMenu(as: try XCTUnwrap(ChoiceMenu.parse(screen: screen))))
    }

    /// ❯ が Submit の行にある時も読める。
    func testCursorOnSubmitRow() throws {
        let screen = Fixture.multiSelect(cursorRow: "  3. [✔] App Store Connect", submitRow: "❯    Submit")
        let menu = try XCTUnwrap(ChoiceMenu.parse(screen: screen))
        XCTAssertEqual(menu.cursor, 4)
        XCTAssertTrue(menu.options[4].isSubmit)
        XCTAssertTrue(menu.sameMenu(as: try XCTUnwrap(ChoiceMenu.parse(screen: Fixture.multiSelect()))))
    }

    /// ❯ が自由入力の行に乗ると例文が消えてチェック欄だけになる。その行は選べない。
    func testCursorOnEmptyFreeTextRow() throws {
        let screen = Fixture.multiSelect(cursorRow: "  3. [✔] App Store Connect", typeRow: "❯ 4. [ ]")
        let menu = try XCTUnwrap(ChoiceMenu.parse(screen: screen))
        XCTAssertEqual(menu.cursor, 3)
        XCTAssertTrue(menu.options[3].isFreeText)
        XCTAssertTrue(menu.options[4].isSubmit)
        XCTAssertNil(MenuTabMover(expected: menu, direction: .next))
    }

    /// 3 番目から Submit へ。自由入力の行を通り抜け、着いたのを確かめてから Enter。
    func testNavigatesToSubmitThroughFreeText() throws {
        let start = try XCTUnwrap(ChoiceMenu.parse(screen: Fixture.multiSelect()))
        var nav = try XCTUnwrap(MenuNavigator(expected: start, target: 4))
        XCTAssertEqual(nav.next(start), .press(.down))
        let onFree = ChoiceMenu.parse(screen: Fixture.multiSelect(cursorRow: "  3. [✔] App Store Connect", typeRow: "❯ 4. [ ]"))
        XCTAssertEqual(nav.next(onFree), .press(.down))
        let onSubmit = ChoiceMenu.parse(screen: Fixture.multiSelect(cursorRow: "  3. [✔] App Store Connect", submitRow: "❯    Submit"))
        XCTAssertEqual(nav.next(onSubmit), .wait)
        XCTAssertEqual(nav.next(onSubmit), .confirm)
    }

    /// 「Chat about this」へは Submit の行を挟んで 1 行ずつ進む。
    func testNavigatesPastSubmitRow() throws {
        let onSubmit = try XCTUnwrap(ChoiceMenu.parse(screen: Fixture.multiSelect(cursorRow: "  3. [✔] App Store Connect", submitRow: "❯    Submit")))
        var nav = try XCTUnwrap(MenuNavigator(expected: onSubmit, target: 5))
        XCTAssertEqual(nav.next(onSubmit), .press(.down))
        var screen = Fixture.multiSelect(cursorRow: "  3. [✔] App Store Connect")
        screen[20] = "❯ 5. Chat about this"
        let onChat = ChoiceMenu.parse(screen: screen)
        XCTAssertEqual(onChat?.cursor, 5)
        XCTAssertEqual(nav.next(onChat), .wait)
        XCTAssertEqual(nav.next(onChat), .confirm)
    }

    func testTwoQuestions() throws {
        let first = try XCTUnwrap(ChoiceMenu.parse(screen: Fixture.twoQuestionsFirst()))
        XCTAssertEqual(first.question, "どの言語を足しますか？")
        XCTAssertFalse(first.isMultiSelect)
        XCTAssertEqual(first.options.map(\.label), ["オランダ語", "ドイツ語", "Type something.", "Chat about this"])
        XCTAssertEqual(first.tabs?.tabs.map(\.title), ["言語", "範囲"])
        XCTAssertEqual(first.footer, "Enter to select · Tab/Arrow keys to navigate · Esc to cancel")

        let second = try XCTUnwrap(ChoiceMenu.parse(screen: Fixture.twoQuestionsSecond))
        XCTAssertEqual(second.options.map(\.label), ["iOS アプリ", "LP サイト", "Type something", "Submit", "Chat about this"])
        XCTAssertTrue(second.options[3].isSubmit)
        XCTAssertEqual(second.tabs?.tabs.map(\.answered), [true, false])

        var next = Fixture.twoQuestionsSecond
        next[8] = "     Next"
        XCTAssertEqual(try XCTUnwrap(ChoiceMenu.parse(screen: next)).options[3], .init(number: nil, label: "Next", isSubmit: true))
    }

    /// Submit タブの確認は通常の選択肢として読める。
    func testReviewScreen() throws {
        let menu = try XCTUnwrap(ChoiceMenu.parse(screen: Fixture.review))
        XCTAssertEqual(menu.question, "Ready to submit your answers?")
        XCTAssertEqual(menu.options.map(\.label), ["Submit answers", "Cancel"])
        XCTAssertEqual(menu.context, ["Review your answers", "どの言語を足しますか？", "→ オランダ語", "どこまで対応しますか？", "→ iOS アプリ, LP サイト"])
        XCTAssertTrue(menu.isReview)
        XCTAssertEqual(menu.tabs?.current, 2)
        XCTAssertFalse(menu.isMultiSelect)
        XCTAssertNotNil(MenuNavigator(expected: menu, target: 0))
        XCTAssertNil(MenuTabMover(expected: menu, direction: .next))
        XCTAssertNotNil(MenuTabMover(expected: menu, direction: .previous))
    }

    /// 英語の問いの折り返しは空白を戻してつなぐ。
    func testWrappedEnglishQuestion() throws {
        let screen = [
            Fixture.rule,
            "←  ☐ Scope  ✔ Submit  →",
            "",
            "│ Which parts of the Dutch localization should be included in this release,",
            "│ given that the store page needs review?",
            "",
            "❯ 1. [ ] iOS app",
            "  2. [ ] Type something",
            "     Submit",
            Fixture.rule,
            "  3. Chat about this",
            "",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ]
        let menu = try XCTUnwrap(ChoiceMenu.parse(screen: screen))
        XCTAssertEqual(menu.question, "Which parts of the Dutch localization should be included in this release, given that the store page needs review?")
        XCTAssertEqual(menu.context, [])
    }

    /// 本文の「☐ …」は問いのすぐ上でなければタブと読まない。
    func testCheckboxInBodyIsNotTabs() throws {
        let screen = [
            Fixture.rule,
            " ☐ まだ済んでいない作業",
            " 次に進めますか？の前置き",
            " 次に進めますか？",
            "",
            "❯ 1. はい",
            "  2. いいえ",
            "",
            "Enter to select · Esc to cancel",
        ]
        let menu = try XCTUnwrap(ChoiceMenu.parse(screen: screen))
        XCTAssertNil(menu.tabs)
        XCTAssertEqual(menu.context, ["☐ まだ済んでいない作業", "次に進めますか？の前置き"])
    }
}

final class MenuTabMoverTests: XCTestCase {
    private func first(cursor: Int = 0) -> MenuPrompt { ChoiceMenu.parse(screen: Fixture.twoQuestionsFirst(cursor: cursor))! }
    private var second: MenuPrompt { ChoiceMenu.parse(screen: Fixture.twoQuestionsSecond)! }

    func testMovesOnceAndConfirmsByQuestionChange() throws {
        var mover = try XCTUnwrap(MenuTabMover(expected: first(), direction: .next))
        XCTAssertEqual(mover.next(first()), .press(.next))
        XCTAssertTrue(mover.hasPendingKey)
        // 反映を待つ間は再送しない。
        XCTAssertEqual(mover.next(first()), .wait)
        XCTAssertEqual(mover.next(nil), .wait)
        XCTAssertEqual(mover.next(second), .moved)
        XCTAssertFalse(mover.hasPendingKey)
    }

    /// ❯ の位置やチェックが動いただけでは移ったと見なさない。
    func testCursorMoveIsNotTabMove() throws {
        var mover = try XCTUnwrap(MenuTabMover(expected: first(), direction: .next))
        XCTAssertEqual(mover.next(first()), .press(.next))
        XCTAssertEqual(mover.next(first(cursor: 1)), .wait)
    }

    func testGivesUpWithoutResend() throws {
        var mover = try XCTUnwrap(MenuTabMover(expected: first(), direction: .previous))
        XCTAssertEqual(mover.next(first()), .press(.previous))
        var action = MenuTabMover.Action.wait
        for _ in 0...MenuTabMover.maxWaits {
            action = mover.next(first())
            XCTAssertNotEqual(action, .press(.previous))
        }
        XCTAssertEqual(action, .abort(.stuck))
        XCTAssertEqual(PendingArrowHold.after(mover, now: Date(timeIntervalSince1970: 3)),
                       PendingArrowHold(since: Date(timeIntervalSince1970: 3), cursor: nil))
    }

    func testRejectsChangedOrMissingMenuAtStart() throws {
        var changed = try XCTUnwrap(MenuTabMover(expected: first(), direction: .next))
        XCTAssertEqual(changed.next(second), .abort(.changed))
        XCTAssertNil(PendingArrowHold.after(changed, now: Date()))
        var gone = try XCTUnwrap(MenuTabMover(expected: first(), direction: .next))
        XCTAssertEqual(gone.next(nil), .abort(.gone))
    }

    func testVanishedWhileWaiting() throws {
        var mover = try XCTUnwrap(MenuTabMover(expected: first(), direction: .next))
        XCTAssertEqual(mover.next(first()), .press(.next))
        var action = MenuTabMover.Action.wait
        for _ in 0..<11 { action = mover.next(nil) }
        XCTAssertEqual(action, .abort(.vanished))
    }

    func testNoMoveBeforeFirstTab() throws {
        var tabbed = first()
        tabbed.tabs?.current = 0
        XCTAssertNil(MenuTabMover(expected: tabbed, direction: .previous))
        XCTAssertNotNil(MenuTabMover(expected: tabbed, direction: .next))
    }

    func testTabKeys() {
        XCTAssertEqual(PTYInput.tabKey(.next, applicationCursor: false), "\u{1b}[C")
        XCTAssertEqual(PTYInput.tabKey(.previous, applicationCursor: true), "\u{1b}OD")
    }
}

final class MenuScreenLogTests: XCTestCase {
    func testEntryAndRotation() {
        let date = Date(timeIntervalSince1970: 0)
        let one = MenuScreenLog.entry(kind: .menu, date: date, columns: 160, screen: ["=== looks like a header", "❯ 1. a", "", ""])
        XCTAssertEqual(one, "=== 1970-01-01T00:00:00Z menu cols=160\n| === looks like a header\n| ❯ 1. a\n")
        var log = ""
        for index in 0..<8 {
            log = MenuScreenLog.appending(MenuScreenLog.entry(kind: .unreadable, date: date, columns: index, screen: ["x"]), to: log, keep: 3)
        }
        XCTAssertEqual(log.components(separatedBy: "\n").filter { $0.hasPrefix("=== ") }.map { $0.components(separatedBy: "cols=").last! }, ["5", "6", "7"])
        XCTAssertTrue(log.hasSuffix("| x\n"))
    }

    func testWritesPrivateFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("menu-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("menu-screens.log")
        try MenuScreenLog.write("=== a\n| 1\n", to: url)
        try MenuScreenLog.write("=== b\n| 2\n", to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "=== a\n| 1\n=== b\n| 2\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["menu-screens.log"])
    }
}
