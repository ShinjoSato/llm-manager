import XCTest
@testable import MonitorKit

/// 右のパネルが縦線ではなく空白の桁だけで区切られている画面（10/12 の発生時の形をなぞり、文章はダミー）。
/// 左の欄は 90 桁（0〜89）、90 桁目が全行で空白、パネルは 91 桁目（字下げで 92 桁目）から。左の欄の罫線は 90 桁で切れる。
private enum BlankPaneFixture {
    static let leftRule = String(repeating: "─", count: 90)
    static let rightRule = String(repeating: "─", count: 70)

    static let left: [String] = [
        "  │ 項目                │ a/123  │ 単体の確認はまだ                                  │",
        "  └─────────────────────┴────────┴───────────────────────────────────────────────────┘",
        "",
        "  新しく起票した課題:",
        "  - #101（重要）: 構成によっては、配信と接続の切断が重なると閉じた口への送信で落ちます。",
        "    コードで確かめた段階で、まだ再現はしていません。",
        "  - #102: 手元の設定で値がそのまま渡り、ログインが失敗します。",
        "",
        "  次は各ブランチで確認から提出までを回します。その前に決めたいことがあります。",
        leftRule,
        "←  ☒ 確認  ☐ 記載  ☐ 所在  ☐ 広告  ✔ Submit  →",
        "",
        "│ #103: 記載の扱いがポリシーと実装で食い違っています。",
        "│ どちらに合わせますか？",
        "",
        "❯ 1. 実装に合わせる (Recommended)",
        "     ポリシーの文を実装に合わせて書き直す",
        "  2. ポリシーに合わせる",
        "     実装を直して、ポリシーの書き方どおりにする",
        "  3. Type something.",
        leftRule,
        "  4. Chat about this",
        "",
        "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
    ]

    /// 行ごとの右の欄（nil は空。先頭の空白は 91 桁目からの字下げ）。
    static let right: [String?] = [
        nil, "a stash +1 -1", nil, ".claude/worktrees/agent-a1/", ".claude/worktrees/agent-a2/", ".claude/worktrees/agent-a3/",
        rightRule, ".claude/worktrees/agent-a1/ (untracked)", rightRule, "New file not yet staged.",
        "Run `git add :/.claude/worktrees/agent-a1/` to see line", "counts.", rightRule, " 12        let value = compute()",
        " 13        <Header>", " 14 -          title = \"old\"", " 15 +          title = \"new\"", rightRule,
        ".claude/worktrees/agent-a2/ (untracked)", "New file not yet staged.", "Run `git add :/.claude/worktrees/agent-a2/` to see line",
        "counts.", nil, rightRule,
    ]

    static var screen: [String] {
        zip(left, right).map { line, pane in
            guard let pane else { return line }
            return pad(line, to: 91) + pane
        }
    }

    static func pad(_ line: String, to column: Int) -> String {
        line + String(repeating: " ", count: max(0, column - TerminalScreen.displayWidth(of: line)))
    }
}

final class BlankPaneTests: XCTestCase {
    func testFixtureShape() {
        XCTAssertEqual(BlankPaneFixture.left.count, BlankPaneFixture.right.count)
        XCTAssertTrue(BlankPaneFixture.left.allSatisfy { TerminalScreen.displayWidth(of: $0) <= 90 })
        // 縦線の区切りは無い。
        XCTAssertNil(TerminalScreen.paneDivider(BlankPaneFixture.screen))
    }

    /// 空白の帯で区切られた右のパネルを外すと、左の欄だけが残る。
    func testMainPaneDropsBlankSeparatedPane() {
        let pane = TerminalScreen.mainPane(BlankPaneFixture.screen)
        XCTAssertEqual(pane.count, BlankPaneFixture.screen.count)
        XCTAssertEqual(pane, BlankPaneFixture.left)
        XCTAssertEqual(TerminalScreen.blankDivider(BlankPaneFixture.screen)?.column, 90)
    }

    /// 外せばカードの問い・選択肢・タブにパネルの文字が混ざらない。外さないと読み違える（10/12 の発生の形）。
    func testMenuBesideBlankPaneIsReadLikePlainMenu() throws {
        let menu = try XCTUnwrap(ChoiceMenu.parse(screen: TerminalScreen.mainPane(BlankPaneFixture.screen)))
        XCTAssertEqual(menu.question, "#103: 記載の扱いがポリシーと実装で食い違っています。どちらに合わせますか？")
        XCTAssertEqual(menu.options.map(\.label), ["実装に合わせる (Recommended)", "ポリシーに合わせる", "Type something.", "Chat about this"])
        XCTAssertEqual(menu.options.map(\.detail), [["ポリシーの文を実装に合わせて書き直す"], ["実装を直して、ポリシーの書き方どおりにする"], [], []])
        XCTAssertEqual(menu.cursor, 0)
        XCTAssertEqual(menu.tabs?.tabs.map(\.title), ["確認", "記載", "所在", "広告"])
        XCTAssertEqual(menu.tabs?.hasSubmit, true)
        XCTAssertEqual(menu.tabs?.hasArrows, true)
        XCTAssertEqual(menu.footer, "Enter to select · Tab/Arrow keys to navigate · Esc to cancel")
        XCTAssertEqual(menu, ChoiceMenu.parse(screen: BlankPaneFixture.left))
        XCTAssertFalse(([menu.question] + menu.options.flatMap { [$0.label] + $0.detail }).contains { $0.contains("untracked") || $0.contains("counts.") })
        XCTAssertNotEqual(ChoiceMenu.parse(screen: BlankPaneFixture.screen), menu)
    }

    /// 全幅の行（入力欄・メニューの罫線）がある画面は区切らない。
    func testFullWidthRowPreventsBlankDivider() {
        var screen = BlankPaneFixture.screen
        screen.append(String(repeating: "─", count: 162))
        XCTAssertNil(TerminalScreen.blankDivider(screen))
        XCTAssertEqual(TerminalScreen.mainPane(screen), screen)
    }

    /// 左の欄の罫線が区切りの手前で切れていなければ、桁をそろえた文の並びを 2 つの欄と読まない。
    func testAlignedColumnsWithoutLeftRuleAreKept() {
        let rows = (0..<12).map { index in
            BlankPaneFixture.pad("  file_\(index).swift で見つけた箇所の説明", to: 60) + "\(index * 10) lines"
        }
        XCTAssertNil(TerminalScreen.blankDivider(rows))
        XCTAssertEqual(TerminalScreen.mainPane(rows), rows)
    }

    /// 縦線で始まる表の列は右の欄と読まない。
    func testTableColumnsAreKept() {
        var table = [String(repeating: "─", count: 40)]
        for index in 0..<10 {
            table.append(BlankPaneFixture.pad("  項目 \(index) の説明", to: 30) + "│ 値 \(index)")
        }
        XCTAssertNil(TerminalScreen.blankDivider(table))
    }

    /// 既存の縦線の区切りは今どおり縦線で切る。
    func testVerticalDividerStillWins() {
        let left = ["  本文の行です。", String(repeating: "─", count: 40)] + Array(repeating: "  会話の行", count: 10)
        let screen = left.map { BlankPaneFixture.pad($0, to: 50) + "│ パネル" }
        XCTAssertEqual(TerminalScreen.paneDivider(screen)?.column, 50)
        XCTAssertFalse(TerminalScreen.mainPane(screen).contains { $0.contains("パネル") })
    }
}
