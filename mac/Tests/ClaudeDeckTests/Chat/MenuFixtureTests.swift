import XCTest
@testable import MonitorKit

/// 本物の Claude Code の画面の写し（`Fixtures/ClaudeCode-<版>/*.txt`。行頭の「| 」の後ろが端末の 1 行）。
enum ScreenFixture {
    static func load(_ name: String, version: String = "2.1.300") throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "txt",
                                                  subdirectory: "Fixtures/ClaudeCode-\(version)"), "fixture \(name)")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            guard line.hasPrefix("|") else { return nil }
            return String(line.dropFirst(line.hasPrefix("| ") ? 2 : 1))
        }
    }

    /// 実機ではタブ行の背景色で今のタブを読むので、`current` 番目のタブ（Submit は tabs.count）にだけ色を付けた読み取りを作る。
    static func highlight(_ screen: [String], current: Int) -> (Int) -> [Bool]? {
        { row in
            guard screen.indices.contains(row), let (_, ranges) = MenuTabs.parse(screen[row]), ranges.indices.contains(current) else { return nil }
            var flags = Array(repeating: false, count: screen[row].count)
            for index in ranges[current] where index < flags.count { flags[index] = true }
            return flags
        }
    }

    /// ❯ を `label` の選択肢の行へ移した画面（矢印を 1 回送った後の描き直しの写し）。
    static func movingCursor(_ screen: [String], to label: String) -> [String] {
        var result = screen
        guard let from = result.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") && !$0.contains("AskUserQuestion") }),
              let to = result.lastIndex(where: { $0.contains(label) }), from != to else { return screen }
        result[from] = result[from].replacingOccurrences(of: "❯", with: " ")
        var characters = Array(result[to])
        let indent = characters.prefix { $0 == " " }.count
        guard indent >= 2 else { return screen }
        characters[indent - 2] = "❯"
        result[to] = String(characters)
        return result
    }
}

final class MenuFixture2_1_300Tests: XCTestCase {
    private func parse(_ name: String, tab: Int? = nil) throws -> MenuPrompt {
        let screen = try ScreenFixture.load(name)
        XCTAssertEqual(InputBlock.detect(screen: screen), .menu, name)
        XCTAssertNil(PermissionPrompt.parse(screen: screen), name)
        // 2.1.300 の画面は右のパネルが無いので、切り出しで変わらない。
        XCTAssertEqual(TerminalScreen.mainPane(screen), screen, name)
        let highlight = tab.map { ScreenFixture.highlight(screen, current: $0) }
        return try XCTUnwrap(ChoiceMenu.parse(screen: screen, highlight: highlight), name)
    }

    // MARK: - trust 確認

    /// 問いの下に説明とリンク（Security guide）が入っても、問いは「?」までの文。
    func testTrustDialogQuestionSkipsSecurityGuide() throws {
        for (name, cursor, context) in [
            ("r1-app-01", 0, ["Accessing workspace:", "/tmp/menurepro/work/r1-app"]),
            ("r2-app-02", 0, ["Accessing workspace:", "/tmp/menurepro/work/r2-app"]),
            ("r3-long-07", 0, ["Accessing workspace:", "/tmp/menurepro/work/r3-long"]),
            ("r3-long-08", 1, ["Accessing workspace:", "/tmp/menurepro/work/r3-long"]),
            ("r4-wait-13", 0, ["Accessing workspace:", "/tmp/menurepro/work", "/r4-wait"]),
            ("r4-wait-14", 1, ["Accessing workspace:", "/tmp/menurepro/work", "/r4-wait"]),
            ("r5-combo-19", 0, ["Accessing workspace:", "/tmp/menurepro/work/r5-combo"]),
        ] {
            let menu = try parse(name)
            XCTAssertEqual(menu.question, "Quick safety check: Is this a project you created or one you trust?", name)
            XCTAssertEqual(menu.context, context, name)
            XCTAssertEqual(menu.options, [.init(number: nil, label: "No, exit"), .init(number: nil, label: "Yes, I trust this folder")], name)
            XCTAssertEqual(menu.cursor, cursor, name)
            XCTAssertNil(menu.tabs, name)
            XCTAssertEqual(menu.footer, "Enter to confirm · Esc to cancel", name)
            XCTAssertTrue(menu.isTrust, name)
            XCTAssertTrue(menu.cancelExits, name)
            // 「No, exit」を押すと claude が終わるので、Esc と同じく確かめる。
            XCTAssertTrue(menu.choiceExits(0), name)
            XCTAssertFalse(menu.choiceExits(1), name)
        }
    }

    /// ❯ の位置だけが違う trust 確認は同じカード（identity が同じ）。
    func testTrustDialogIdentityIgnoresCursor() throws {
        let first = try parse("r3-long-07")
        let moved = try parse("r3-long-08")
        XCTAssertEqual(first.identity, moved.identity)
        XCTAssertEqual(PromptCardIdentity.menu(first), PromptCardIdentity.menu(moved))
        XCTAssertTrue(first.sameMenu(as: moved))
    }

    func testNavigatesTrustDialog() throws {
        let screen = try ScreenFixture.load("r1-app-01")
        let expected = try XCTUnwrap(ChoiceMenu.parse(screen: screen))
        let moved = try XCTUnwrap(ChoiceMenu.parse(screen: ScreenFixture.movingCursor(screen, to: "Yes, I trust this folder")))
        XCTAssertEqual(moved.cursor, 1)
        var navigator = try XCTUnwrap(MenuNavigator(expected: expected, target: 1))
        XCTAssertEqual(navigator.next(expected), .press(.down))
        XCTAssertEqual(navigator.next(moved), .wait)
        XCTAssertEqual(navigator.next(moved), .confirm)
    }

    // MARK: - AskUserQuestion（3 問）

    func testThreeQuestionsAndReview() throws {
        let titles = ["作業内容", "進め方", "完了時"]
        let q1 = try parse("r2-app-03", tab: 0)
        XCTAssertEqual(q1.question, "このリポジトリ（r2-app）で次に取り組みたい作業はどれですか？")
        XCTAssertEqual(q1.context, [])
        XCTAssertEqual(q1.options.map(\.label), ["新機能の実装", "既存コードの修正", "ドキュメント整備", "Type something.", "Chat about this"])
        XCTAssertEqual(q1.options.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(q1.options.map(\.detail.count), [1, 1, 1, 0, 0])
        XCTAssertEqual(q1.options.map(\.isFreeText), [false, false, false, true, false])
        XCTAssertEqual(q1.cursor, 0)
        XCTAssertEqual(q1.footer, "Enter to select · Tab/Arrow keys to navigate · Esc to cancel")
        XCTAssertEqual(q1.tabs, MenuTabs(tabs: titles.map { .init(title: $0, answered: false) }, hasSubmit: true, hasArrows: true, current: 0))
        XCTAssertFalse(q1.isReview)
        XCTAssertFalse(q1.isMultiSelect)
        XCTAssertFalse(q1.cancelExits)
        XCTAssertFalse(q1.choiceExits(0))

        let q2 = try parse("r2-app-04", tab: 1)
        XCTAssertEqual(q2.question, "作業の進め方はどれがよいですか？")
        XCTAssertEqual(q2.options.map(\.label), ["計画を立ててから着手", "すぐに着手", "調査のみ", "Type something.", "Chat about this"])
        XCTAssertEqual(q2.tabs?.tabs.map(\.answered), [true, false, false])
        XCTAssertEqual(q2.tabs?.current, 1)

        let q3 = try parse("r2-app-05", tab: 2)
        XCTAssertEqual(q3.question, "完了時の扱いはどうしますか？")
        XCTAssertEqual(q3.options.map(\.label), ["コミットまで", "PR 作成まで", "変更のみ", "Type something.", "Chat about this"])
        XCTAssertEqual(q3.tabs?.tabs.map(\.answered), [true, true, false])
        XCTAssertEqual(q3.tabs?.current, 2)

        // 確認画面は背景色が無くても Submit タブと読む。
        let review = try parse("r2-app-06")
        XCTAssertEqual(review.question, "Ready to submit your answers?")
        XCTAssertEqual(review.context.first, "Review your answers")
        XCTAssertEqual(review.options.map(\.label), ["Submit answers", "Cancel"])
        XCTAssertEqual(review.tabs?.tabs.map(\.answered), [true, true, true])
        XCTAssertEqual(review.tabs?.current, 3)
        XCTAssertTrue(review.isReview)
        XCTAssertEqual(review.footer, "")

        // 問いごとに別のカード（identity が替わる）。
        let identities = [q1, q2, q3, review].map(PromptCardIdentity.menu)
        XCTAssertEqual(Set(identities).count, 4)
        XCTAssertFalse(q1.sameMenu(as: q2))
        XCTAssertFalse(q2.samePage(as: q3))
    }

    /// 問いの文が長く折り返しても 1 つの問いとして読み、問いごとに別のカードになる。
    func testLongWrappedQuestions() throws {
        let first = try parse("r3-long-09", tab: 0)
        XCTAssertEqual(first.question, "このリポジトリで最初に取り組む作業はどれにしますか？")
        let second = try parse("r3-long-10", tab: 1)
        XCTAssertTrue(second.question.hasPrefix("README.md だけが未追跡の状態で置かれている現在のリポジトリについて、"), second.question)
        XCTAssertTrue(second.question.hasSuffix("主に使いたい技術スタックはどれに最も近いでしょうか？"), second.question)
        XCTAssertFalse(second.question.contains("│"))
        XCTAssertEqual(second.options.map(\.label), ["TypeScript / Node", "Go", "Swift / iOS", "Type something.", "Chat about this"])
        let third = try parse("r3-long-11", tab: 2)
        XCTAssertTrue(third.question.hasPrefix("開発の進め方についても、"), third.question)
        XCTAssertTrue(third.question.hasSuffix("現時点で想定している進め方に最も近いのはどれですか？"), third.question)
        XCTAssertEqual(third.options.map(\.label), ["都度検証して PR", "main に直接コミット", "Issue 起点で進行", "Type something.", "Chat about this"])
        let review = try parse("r3-long-12")
        XCTAssertTrue(review.isReview)
        XCTAssertEqual(Set([first, second, third, review].map(PromptCardIdentity.menu)).count, 4)
    }

    /// 狭い端末（121 桁）でも同じに読める。
    func testNarrowTerminal() throws {
        let first = try parse("r4-wait-15", tab: 0)
        XCTAssertEqual(first.question, "新しいプロジェクトで主に使いたいプログラミング言語はどれですか？")
        XCTAssertEqual(first.options.map(\.label), ["TypeScript", "Python", "Go", "Swift", "Type something.", "Chat about this"])
        let second = try parse("r4-wait-16", tab: 1)
        XCTAssertTrue(second.question.hasSuffix("あなたが最も重視したいと考えている開発方針はどれに近いでしょうか？"), second.question)
        XCTAssertEqual(second.options.map(\.label), ["品質最優先", "速度最優先", "バランス型", "段階的に強化", "Type something.", "Chat about this"])
        let third = try parse("r4-wait-17", tab: 2)
        XCTAssertEqual(third.question, "作業の進捗はどのように報告してほしいですか？")
        XCTAssertEqual(third.tabs?.tabs.map(\.title), ["言語", "方針", "報告"])
        let review = try parse("r4-wait-18")
        XCTAssertTrue(review.isReview)
        XCTAssertEqual(review.tabs?.current, 3)
    }

    /// 複数選択（チェック欄と Next）と単一選択を混ぜた 2 問。
    func testMultiSelectThenSingle() throws {
        let unchecked = try parse("r5-combo-20", tab: 0)
        XCTAssertEqual(unchecked.question, "マーカーファイル作成後に確認したい項目はどれですか？（複数選択可）")
        XCTAssertEqual(unchecked.options.map(\.label), ["存在確認", "タイムスタンプ", "Git 状態", "Type something", "Next", "Chat about this"])
        XCTAssertEqual(unchecked.options.map(\.checked), [false, false, false, false, nil, nil])
        XCTAssertEqual(unchecked.options.map(\.isSubmit), [false, false, false, false, true, false])
        XCTAssertTrue(unchecked.isMultiSelect)
        XCTAssertEqual(unchecked.tabs?.tabs.map(\.title), ["確認項目", "優先度"])

        // チェックを切り替えると中身が替わるので、別のカードになる（切り替え前のカードの送信中を持ち越さない）。
        let checked = try parse("r5-combo-21", tab: 0)
        XCTAssertEqual(checked.options.map(\.checked), [true, false, false, false, nil, nil])
        XCTAssertNotEqual(PromptCardIdentity.menu(unchecked), PromptCardIdentity.menu(checked))

        let single = try parse("r5-combo-22", tab: 1)
        XCTAssertEqual(single.question, "今回の再現テストの優先度はどれですか？")
        XCTAssertEqual(single.options.map(\.label), ["高", "中", "低", "Type something.", "Chat about this"])
        XCTAssertFalse(single.isMultiSelect)

        let review = try parse("r5-combo-23")
        XCTAssertTrue(review.isReview)
        XCTAssertEqual(review.tabs?.current, 2)
    }

    // MARK: - 操作の手

    func testNavigatorHandsOnFirstQuestion() throws {
        let screen = try ScreenFixture.load("r2-app-03")
        let highlight = ScreenFixture.highlight(screen, current: 0)
        let expected = try XCTUnwrap(ChoiceMenu.parse(screen: screen, highlight: highlight))
        let second = ScreenFixture.movingCursor(screen, to: "2. 既存コードの修正")
        let third = ScreenFixture.movingCursor(second, to: "3. ドキュメント整備")
        let atSecond = try XCTUnwrap(ChoiceMenu.parse(screen: second, highlight: highlight))
        let atThird = try XCTUnwrap(ChoiceMenu.parse(screen: third, highlight: highlight))
        XCTAssertEqual([atSecond.cursor, atThird.cursor], [1, 2])
        // ❯ の位置が違っても同じカード。
        XCTAssertEqual(Set([expected, atSecond, atThird].map(PromptCardIdentity.menu)).count, 1)

        var navigator = try XCTUnwrap(MenuNavigator(expected: expected, target: 2))
        XCTAssertEqual(navigator.next(expected), .press(.down))
        XCTAssertEqual(navigator.next(expected), .wait)
        XCTAssertEqual(navigator.next(atSecond), .press(.down))
        XCTAssertEqual(navigator.next(atThird), .wait)
        XCTAssertEqual(navigator.next(atThird), .confirm)

        // 確定した後に出る次の問いは、押した時のカードと別のメニュー（古いカードの操作を続けない）。
        let next = try XCTUnwrap(ChoiceMenu.parse(screen: ScreenFixture.load("r2-app-04"), highlight: ScreenFixture.highlight(screen, current: 1)))
        var late = try XCTUnwrap(MenuNavigator(expected: expected, target: 1))
        XCTAssertEqual(late.next(next), .abort(.changed))

        // 文字入力の選択肢は押させない。
        XCTAssertNil(MenuNavigator(expected: expected, target: 3))
    }

    func testTabMoverHandsBetweenQuestions() throws {
        let q1Screen = try ScreenFixture.load("r2-app-03")
        let q2Screen = try ScreenFixture.load("r2-app-04")
        let q1 = try XCTUnwrap(ChoiceMenu.parse(screen: q1Screen, highlight: ScreenFixture.highlight(q1Screen, current: 0)))
        let q2 = try XCTUnwrap(ChoiceMenu.parse(screen: q2Screen, highlight: ScreenFixture.highlight(q2Screen, current: 1)))
        XCTAssertNil(MenuTabMover(expected: q1, direction: .previous))
        var mover = try XCTUnwrap(MenuTabMover(expected: q1, direction: .next))
        XCTAssertEqual(mover.next(q1), .press(.next))
        XCTAssertTrue(mover.hasPendingKey)
        XCTAssertEqual(mover.next(q1), .wait)
        XCTAssertEqual(mover.next(nil), .wait)
        XCTAssertEqual(mover.next(q2), .moved)
        XCTAssertFalse(mover.hasPendingKey)
    }
}
