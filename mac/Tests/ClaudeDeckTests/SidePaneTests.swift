import XCTest
@testable import MonitorKit

/// 右に差分パネルが出ている 162 桁の画面（v2.1.286 の実画面の配置をなぞり、文章はダミー）。
/// 左の会話は 90 桁で、91 桁目の縦線（│）から右がパネル。入力欄から下はパネルが無く全幅。
private enum PaneFixture {
    static let paneRows: [String] = [
        "  - 画面の説明: 棒を押すと、グラフの下に内訳が出ます。内訳は色・名前・時間と合計です。・  │                                                                      ✕",
        "    何も無い期間は「なし」と表示されます。                                                │4 files changed                                      source: Current ▾ ",
        "  - 選択の解除: 同じ棒をもう一度押す、外を押す、閉じるボタンを押す、のいずれかです。      │                                                                       ",
        "    週・月を切り替えたときも解除されます。                                                │docs/drafts/alpha/                                                     ",
        "  - 翻訳: 三つの言語に文言を足しました。                                                  │docs/drafts/beta/                                                      ",
        "                                                                                          │docs/drafts/gamma/                                                     ",
        "  確認してほしい点: 一覧の中でスクロールの邪魔にならないかを実機で見てください。          │                                                                       ",
        "                                                                                          │────────────────────────────────────────────────────────────────────── ",
        " ⏺ Agent \"chart breakdown\" finished · 5m 2s                                               │docs/drafts/alpha/ (untracked)                                         ",
        "                                                                                          │────────────────────────────────────────────────────────────────────── ",
        " ⏺ エージェントが終了しました。報告済みの内容から変わりはありません。                     │New file not yet staged.                                               ",
        "                                                                                          │Run `git add :/docs/drafts/alpha/` to see line                         ",
        "   残りの二件は、まだ裏で実装中です。二点への返事も待っています。                         │counts.                                                                ",
        "                                                                                          │                                                                       ",
        " ✻ Waiting for 2 background agents to finish                                              │                                                                       ",
        "                                                                                          │                                                                       ",
    ]

    static let fullRule = String(repeating: "─", count: 162)

    /// 入力欄に番号付きの文を入れたまま（選択メニューではない）。下に statusLine・モード・サブエージェントの一覧が続く。
    static let numberedInputBox: [String] = [
        fullRule,
        "❯ 1. 一案目で進めて良い",
        "  2. このままで良い",
        fullRule,
        "  セッション: 49% (リセット: 10分後) | 週間: 51%",
        "  ⏵⏵ auto mode on · 1 shell",
        "",
        "  ⏺ main",
        "  ◯ general-purpose               Listing schemes in Sample.xcodeproj                                                    5m 38s · ↓ 85.2k tokens",
        "  ◯ general-purpose               Renaming a symbol in DetailView.swift                                                  5m 38s · ↓ 120.6k tokens",
    ]

    static let rule = String(repeating: "─", count: 60)

    static let askMenu: [String] = [
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

    static let permissionMenu: [String] = [
        rule,
        " Bash command",
        "",
        "   touch hello.txt",
        "   Create empty hello.txt",
        "",
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   2. Yes, and always allow access to work/ from this project",
        "   3. No",
        "",
        " Esc to cancel · Tab to amend · ctrl+e to explain",
    ]

    static let planMenu: [String] = [
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

    /// 英数字だけの行を 90 桁にそろえ、右にパネルの欄を付ける（メニューの行の横にもパネルが出ている場合）。
    static func besidePane(_ left: [String]) -> [String] {
        left.enumerated().map { offset, line in
            let right = offset % 3 == 0 ? "docs/drafts/alpha/ (untracked)" : (offset % 3 == 1 ? String(repeating: "─", count: 70) : "")
            return line.padding(toLength: 90, withPad: " ", startingAt: 0) + "│" + right
        }
    }

    static func trimmedRight(_ lines: [String]) -> [String] {
        lines.map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
    }
}

final class NumberedInputBoxTests: XCTestCase {
    /// 入力欄の「❯ 1. …」「  2. …」は、番号付きでも選択メニューではない（送信も止めない）。
    func testNumberedTextInInputBoxIsNotMenu() {
        for screen in [PaneFixture.paneRows + PaneFixture.numberedInputBox, PaneFixture.numberedInputBox] {
            for candidate in [screen, TerminalScreen.mainPane(screen)] {
                XCTAssertNil(InputBlock.detect(screen: candidate))
                XCTAssertFalse(ChoiceMenu.isShowing(screen: candidate))
                XCTAssertNil(ChoiceMenu.parse(screen: candidate))
                XCTAssertNil(ChoiceMenu.unreadable(screen: candidate))
                XCTAssertEqual(InputBox.text(screen: candidate), "1. 一案目で進めて良い\n2. このままで良い")
            }
        }
    }

    /// 入力欄の 2 行目以降に ❯ 付きの番号行があっても、欄の中ではメニューを探さない。
    func testCursorShapedLinesInsideInputBoxAreIgnored() {
        let rule = PaneFixture.rule
        let screen = ["⏺ done", rule, "❯ 1. 一つ目", "❯ 2. 二つ目", "  3. 三つ目", rule, "  ⏵⏵ auto mode on"]
        XCTAssertNil(InputBlock.detect(screen: screen))
    }

    /// 罫線の直下の ❯ 行でも、下を罫線で閉じていなければメニュー（AskUserQuestion で「Chat about this」を選んでいる）。
    func testCursorOnChatAboutThisIsStillMenu() throws {
        var screen = PaneFixture.askMenu
        screen[5] = "  1. Red"
        screen[11] = "❯ 4. Chat about this"
        XCTAssertNil(InputBox.promptIndex(screen))
        let menu = try XCTUnwrap(ChoiceMenu.parse(screen: screen))
        XCTAssertEqual(menu.cursor, 3)
        XCTAssertEqual(menu.options.map(\.label), ["Red", "Blue", "Type something.", "Chat about this"])

        // 罫線で閉じていても、その下に操作案内が続くならメニュー。
        let closed = [PaneFixture.rule, "❯ 1. Red", "  2. Blue", PaneFixture.rule, "  3. Chat about this", "", "Enter to select · Esc to cancel"]
        XCTAssertNil(InputBox.promptIndex(closed))
        XCTAssertEqual(InputBlock.detect(screen: closed), .menu)
    }
}

final class SidePaneTests: XCTestCase {
    /// パネルの欄を落とし、全幅の罫線・入力欄・下の行はそのまま残す。
    func testMainPaneDropsRightPane() {
        let screen = PaneFixture.paneRows + PaneFixture.numberedInputBox
        XCTAssertTrue(PaneFixture.paneRows.allSatisfy { TerminalScreen.barColumns($0) == [90] })
        let pane = TerminalScreen.mainPane(screen)
        XCTAssertEqual(pane.count, screen.count)
        XCTAssertFalse(pane.prefix(PaneFixture.paneRows.count).contains { $0.contains("│") })
        XCTAssertFalse(pane.contains { $0.contains("files changed") || $0.contains("untracked") || $0.contains("counts.") })
        XCTAssertEqual(pane[1], "    何も無い期間は「なし」と表示されます。")
        XCTAssertEqual(pane[7], "")
        XCTAssertEqual(pane[14], " ✻ Waiting for 2 background agents to finish")
        XCTAssertEqual(Array(pane.suffix(PaneFixture.numberedInputBox.count)), PaneFixture.numberedInputBox)
    }

    /// パネルが会話の横に出ていても、本物の選択メニュー・権限プロンプトは従来どおり読める。
    func testMenusAreReadWithPaneAbove() throws {
        for (menu, expected) in [(PaneFixture.askMenu, InputBlock.menu), (PaneFixture.planMenu, .menu), (PaneFixture.permissionMenu, .permission)] {
            let screen = PaneFixture.paneRows + [PaneFixture.fullRule] + menu
            XCTAssertEqual(InputBlock.detect(screen: TerminalScreen.mainPane(screen)), expected)
            XCTAssertEqual(InputBlock.detect(screen: menu), expected)
        }
        let ask = try XCTUnwrap(ChoiceMenu.parse(screen: TerminalScreen.mainPane(PaneFixture.paneRows + PaneFixture.askMenu)))
        XCTAssertEqual(ask, ChoiceMenu.parse(screen: PaneFixture.askMenu))
        let permission = TerminalScreen.mainPane(PaneFixture.paneRows + PaneFixture.permissionMenu)
        XCTAssertEqual(PermissionPrompt.parse(screen: permission), PermissionPrompt.parse(screen: PaneFixture.permissionMenu))
    }

    /// メニューの行の横にもパネルが出ている時は、切り出せば区切りの無い画面と同じに読める。
    func testMenusBesidePaneMatchPlainMenus() throws {
        for menu in [PaneFixture.askMenu, PaneFixture.planMenu] {
            let screen = PaneFixture.besidePane(menu)
            let pane = TerminalScreen.mainPane(screen)
            XCTAssertEqual(pane, PaneFixture.trimmedRight(menu))
            let parsed = try XCTUnwrap(ChoiceMenu.parse(screen: pane))
            XCTAssertEqual(parsed, ChoiceMenu.parse(screen: menu))
            // 切り出さないとパネルの文字が選択肢・罫線に混ざって読み違える。
            XCTAssertNotEqual(ChoiceMenu.parse(screen: screen), parsed)
        }
        let permission = TerminalScreen.mainPane(PaneFixture.besidePane(PaneFixture.permissionMenu))
        XCTAssertEqual(PermissionPrompt.parse(screen: permission), PermissionPrompt.parse(screen: PaneFixture.permissionMenu))
        XCTAssertEqual(InputBlock.detect(screen: permission), .permission)
    }

    /// 会話の表・枠付きの問いの縦線は区切りと読まない。
    func testTablesAndQuestionGutterAreKept() {
        var table = ["⏺ 比較です。", "  ┌────────────────────────┬──────────────────────────┬──────────┐"]
        for index in 0..<10 {
            table.append("  │ 項目 \(index)                 │ 説明の文                 │ 値       │")
        }
        table.append("  └────────────────────────┴──────────────────────────┴──────────┘")
        XCTAssertEqual(TerminalScreen.mainPane(table), table)

        let gutter = Array(repeating: "│ 長い問いを折り返した行です。とても長い問いを折り返した行です。とても長い問いです。", count: 10)
        XCTAssertEqual(TerminalScreen.mainPane(gutter), gutter)

        // 区切りの最小行数に満たない縦線の並びも残す。
        let short = PaneFixture.besidePane(["a", "b", "c"])
        XCTAssertEqual(TerminalScreen.mainPane(short), short)
    }

    /// 区切りの無い画面は変わらない。
    func testScreensWithoutPaneAreUnchanged() {
        for screen in [PaneFixture.askMenu, PaneFixture.planMenu, PaneFixture.permissionMenu, PaneFixture.numberedInputBox] {
            XCTAssertEqual(TerminalScreen.mainPane(screen), screen)
        }
    }

    func testDisplayWidth() {
        XCTAssertEqual(TerminalScreen.displayWidth(of: "abc"), 3)
        XCTAssertEqual(TerminalScreen.displayWidth(of: "日本語"), 6)
        XCTAssertEqual(TerminalScreen.displayWidth(of: "（・）"), 6)
        XCTAssertEqual(TerminalScreen.displayWidth(of: "⏺✻❯│─…"), 6)
    }
}
