import XCTest
@testable import MonitorKit

final class TranscriptBufferTests: XCTestCase {
    private func item(_ id: String, _ kind: TranscriptItemKind = .assistant, parent: String? = nil) -> TranscriptItem {
        TranscriptItem(id: id, kind: kind, at: nil, text: id, tool: kind == .tool ? TranscriptTool(name: "Bash", description: nil, target: "ls") : nil,
                       parentId: parent)
    }

    private func response(_ ids: [String], reset: Bool = false) -> TranscriptResponse {
        TranscriptResponse(sessionId: "s", items: ids.map { item($0) }, reset: reset)
    }

    func testFullFetchThenSSEDeduplicates() {
        var buffer = TranscriptBuffer()
        buffer.beginFetch()
        buffer.apply(response(["a", "b"]), fullReplace: true)
        buffer.append([item("b"), item("c")])
        XCTAssertEqual(buffer.items.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(buffer.lastId, "c")
    }

    func testSSEDuringFetchIsKeptAfterResponseOrder() {
        var buffer = TranscriptBuffer()
        buffer.beginFetch()
        // GET の応答より先に SSE が届いた（d は GET に含まれない新しい分、c は両方に含まれる）。
        buffer.append([item("c"), item("d")])
        buffer.apply(response(["a", "b", "c"]), fullReplace: true)
        XCTAssertEqual(buffer.items.map(\.id), ["a", "b", "c", "d"])
    }

    func testDeltaFetchAppendsAfterExisting() {
        var buffer = TranscriptBuffer()
        buffer.apply(response(["a", "b"]), fullReplace: true)
        buffer.beginFetch()
        buffer.append([item("d")])
        buffer.apply(response(["c", "d"]), fullReplace: false)
        XCTAssertEqual(buffer.items.map(\.id), ["a", "b", "c", "d"])
    }

    func testResetReplacesEverything() {
        var buffer = TranscriptBuffer()
        buffer.apply(response(["a", "b"]), fullReplace: true)
        buffer.beginFetch()
        buffer.apply(response(["x", "y"], reset: true), fullReplace: false)
        XCTAssertEqual(buffer.items.map(\.id), ["x", "y"])
        buffer.append([item("a")])
        XCTAssertEqual(buffer.items.map(\.id), ["x", "y", "a"], "置き換え後は古い id を重複扱いしない")
    }
}

final class ChatTimelineTests: XCTestCase {
    private func item(_ id: String, _ kind: TranscriptItemKind, parent: String? = nil) -> TranscriptItem {
        TranscriptItem(id: id, kind: kind, at: nil, text: kind == .tool ? nil : "t-\(id)",
                       tool: kind == .tool ? TranscriptTool(name: "Bash", description: nil, target: id) : nil, parentId: parent)
    }

    func testToolsFoldUnderParent() {
        let items = [item("u1", .user), item("a1", .assistant), item("t1", .tool, parent: "a1"),
                     item("t2", .tool, parent: "a1"), item("a2", .assistant), item("t3", .tool, parent: "u1")]
        let entries = ChatTimeline.entries(from: items)
        XCTAssertEqual(entries.map(\.id), ["u1", "a1", "a2"])
        XCTAssertEqual(entries[1].tools.map(\.id), ["t1", "t2"])
        XCTAssertEqual(entries[0].tools.map(\.id), ["t3"])
        XCTAssertEqual(entries[0].role, .user)
    }

    func testOrphanToolsAttachToPreviousOrPlaceholder() {
        let items = [item("t0", .tool), item("u1", .user), item("t1", .tool, parent: "missing")]
        let entries = ChatTimeline.entries(from: items)
        XCTAssertEqual(entries.map(\.role), [.toolsOnly, .user])
        XCTAssertEqual(entries[1].tools.map(\.id), ["t1"])
    }

    func testRunningTool() {
        let items = [item("u1", .user), item("t1", .tool, parent: "u1")]
        XCTAssertEqual(ChatTimeline.runningToolId(items: items, status: .working), "t1")
        XCTAssertNil(ChatTimeline.runningToolId(items: items, status: .idle))
        XCTAssertNil(ChatTimeline.runningToolId(items: items + [item("a1", .assistant)], status: .working))
    }
}

final class RoomGroupingTests: XCTestCase {
    private func room(_ id: String, _ status: SessionStatus, at: Double?, search: String = "") -> RoomKey {
        RoomKey(id: id, name: id, status: status, activityAt: at, searchText: search)
    }

    func testGroupsAndOrder() {
        let rooms = [room("idle1", .idle, at: 5), room("work-old", .working, at: 1), room("perm", .permission, at: 2),
                     room("work-new", .working, at: 9), room("wait", .waiting, at: 7), room("stopped", .stopped, at: nil),
                     room("err", .error, at: 3)]
        let groups = RoomGrouping.group(rooms)
        XCTAssertEqual(groups.map(\.phase), [.attention, .active, .idle])
        XCTAssertEqual(groups[0].ids, ["wait", "perm"])
        XCTAssertEqual(groups[1].ids, ["work-new", "work-old"])
        XCTAssertEqual(groups[2].ids, ["idle1", "err", "stopped"])
    }

    func testSameTimeSortsByName() {
        let groups = RoomGrouping.group([room("b", .idle, at: 1), room("a", .idle, at: 1)])
        XCTAssertEqual(groups[0].ids, ["a", "b"])
    }

    func testSearchMatchesAllTerms() {
        let rooms = [room("mirio", .idle, at: 1, search: "feature/68 チャット"), room("sandora", .idle, at: 1, search: "develop")]
        XCTAssertEqual(RoomGrouping.group(rooms, query: "MIRIO ﾁｬｯﾄ").flatMap(\.ids), ["mirio"])
        XCTAssertEqual(RoomGrouping.group(rooms, query: "  ").flatMap(\.ids).count, 2)
        XCTAssertTrue(RoomGrouping.group(rooms, query: "nothing").isEmpty)
    }

    func testUnreadCountsOnlyNewMessagesOfThatSession() {
        func f(_ id: Int, _ s: String, _ kind: FeedKind, _ at: Double) -> FeedItem {
            FeedItem(id: id, sessionId: s, project: "p", at: at, kind: kind, text: "", tool: nil, local: nil)
        }
        let feed = [f(1, "s1", .message, 10), f(2, "s1", .message, 30), f(3, "s1", .tool, 40), f(4, "s2", .message, 50)]
        XCTAssertEqual(RoomGrouping.unreadCount(feed: feed, sessionId: "s1", since: 20), 1)
        XCTAssertEqual(RoomGrouping.unreadCount(feed: feed, sessionId: "s1", since: 0), 2)
    }

    func testColorIndexIsDeterministic() {
        let a = RoomGrouping.colorIndex(for: "mirio", paletteSize: 8)
        XCTAssertEqual(a, RoomGrouping.colorIndex(for: "mirio", paletteSize: 8))
        XCTAssertTrue((0..<8).contains(a))
        // FNV-1a("a") = 0xe40c292c
        XCTAssertEqual(RoomGrouping.colorIndex(for: "a", paletteSize: 1 << 16), Int(0xe40c292c as UInt32 % (1 << 16)))
        XCTAssertEqual(RoomGrouping.initial(of: "mirio"), "M")
        XCTAssertEqual(RoomGrouping.initial(of: "あいう"), "あ")
    }
}

final class ChatMarkdownTests: XCTestCase {
    func testSplitsFencedCode() {
        let blocks = ChatMarkdown.blocks("前置き\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n後書き")
        XCTAssertEqual(blocks, [.text("前置き"), .code(language: "swift", "let a = 1\n\nlet b = 2"), .text("後書き")])
    }

    func testUnclosedFenceRunsToEnd() {
        XCTAssertEqual(ChatMarkdown.blocks("a\n```\nx"), [.text("a"), .code(language: nil, "x")])
    }

    func testInlineBoldCodeAndNewlines() {
        let s = ChatMarkdown.inline("**太字** と `code`\n次の行")
        XCTAssertEqual(String(s.characters), "太字 と code\n次の行")
        let bold = s.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertEqual(bold.map { String(s[$0.range].characters) }, "太字")
        let code = s.runs.first { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertEqual(code.map { String(s[$0.range].characters) }, "code")
    }
}

final class PTYInputTests: XCTestCase {
    func testBracketedPasteKeepsNewlines() {
        XCTAssertEqual(PTYInput.messageBody("一行目\r\n二行目\n", bracketedPaste: true), "\u{1b}[200~一行目\n二行目\u{1b}[201~")
    }

    func testEscapeIsStrippedAndEmptyIsNil() {
        XCTAssertEqual(PTYInput.messageBody("a\u{1b}[201~b", bracketedPaste: true), "\u{1b}[200~a[201~b\u{1b}[201~")
        XCTAssertNil(PTYInput.messageBody(" \n ", bracketedPaste: true))
    }

    func testWithoutBracketedPasteFoldsLines() {
        XCTAssertEqual(PTYInput.messageBody("a\n  b", bracketedPaste: false), "a b")
    }

    func testParsesPermissionPromptFromScreen() {
        let screen = [
            "❯ Run this exact bash command: touch hello.txt",
            "────────────────────────────────────────",
            " Bash command",
            "",
            "   touch hello.txt",
            "   Create empty hello.txt",
            "",
            " Tip: auto mode handles these prompts for you",
            " Do you want to proceed?",
            " ❯ 1. Yes",
            "   2. Yes, and always allow access to work/ from this project",
            "   4. No",
            "",
            " Esc to cancel · Tab to amend · ctrl+e to explain",
        ]
        let prompt = PermissionPrompt.parse(screen: screen)
        XCTAssertEqual(prompt, PermissionPrompt(title: "Bash command", lines: ["touch hello.txt", "Create empty hello.txt"]))
    }

    func testParsesPromptWithDashedCommandFrame() {
        // v2.1.286 はコマンドを破線で囲む。
        let screen = [
            "  ⎿  $ touch deny.txt",
            "──────────────────────────────",
            " Bash command",
            " Tip: auto mode handles these prompts for you — choose \"switch to auto mode\" below",
            " Create empty file deny.txt",
            "╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌",
            " touch deny.txt",
            "╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌",
            " Do you want to proceed?",
            " ❯ 1. Yes",
            "   4. No",
        ]
        XCTAssertEqual(PermissionPrompt.parse(screen: screen),
                       PermissionPrompt(title: "Bash command", lines: ["Create empty file deny.txt", "touch deny.txt"]))
    }

    func testNoPromptWithoutChoices() {
        XCTAssertNil(PermissionPrompt.parse(screen: ["Do you want to proceed?", "sure"]))
        XCTAssertNil(PermissionPrompt.parse(screen: ["❯ hello"]))
    }
}

final class PTYSanitizeTests: XCTestCase {
    func testControlCharactersAreDroppedExceptNewlineAndTab() {
        let input = "a\u{0}b\u{3}c\u{7}d\u{8}e\u{1b}f\u{7f}g\u{85}h\u{9b}i\tj\nk"
        XCTAssertEqual(PTYInput.sanitize(input), "abcdefghi\tj\nk")
    }

    func testBothPathsDropControlCharacters() {
        XCTAssertEqual(PTYInput.messageBody("x\u{3}\u{9b}201~y\nz", bracketedPaste: true), "\u{1b}[200~x201~y\nz\u{1b}[201~")
        XCTAssertEqual(PTYInput.messageBody("x\u{15}y\n\u{7f}z", bracketedPaste: false), "xy z")
    }

    func testOnlyControlCharactersIsEmpty() {
        XCTAssertNil(PTYInput.messageBody("\u{3}\u{1b}\u{9b}", bracketedPaste: true))
    }

    func testNonControlUnicodeIsKept() {
        XCTAssertEqual(PTYInput.sanitize("日本語 🙂 é"), "日本語 🙂 é")
    }
}

final class ChoiceMenuTests: XCTestCase {
    private let rule = String(repeating: "─", count: 40)

    /// 新しいフォルダで初回起動した時の trust 確認（番号の無いメニュー。v2.1.286 の実画面）。
    func testTrustDialogWithoutNumbersIsMenu() {
        let screen = [
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
        XCTAssertTrue(ChoiceMenu.isShowing(screen: screen))
        XCTAssertEqual(InputBlock.detect(screen: screen), .menu)
    }

    /// AskUserQuestion（説明行を挟む番号付きメニュー）。
    func testAskUserQuestionIsMenu() {
        let screen = [
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
        XCTAssertEqual(InputBlock.detect(screen: screen), .menu)
        // 操作案内の行が無くても番号付きの選択肢だけで分かる。
        XCTAssertTrue(ChoiceMenu.hasNumberedChoices(screen.map { $0.trimmingCharacters(in: .whitespaces) }))
    }

    /// plan モードの承認（操作案内の行が無い）。
    func testPlanApprovalIsMenu() {
        let screen = [
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
        XCTAssertEqual(InputBlock.detect(screen: screen), .menu)
    }

    func testPermissionPromptWins() {
        let screen = [
            rule,
            " Bash command",
            "   touch hello.txt",
            " Do you want to proceed?",
            " ❯ 1. Yes",
            "   2. No",
            "",
            " Esc to cancel · Tab to amend",
        ]
        XCTAssertEqual(InputBlock.detect(screen: screen), .permission)
    }

    /// 番号付きリストを送った後の通常画面。入力欄より上は履歴なのでメニュー扱いしない。
    func testNumberedListInHistoryIsNotMenu() {
        let screen = [
            "❯ 1. まずテストを書く",
            "  2. 次に実装する",
            "",
            "⏺ 了解しました。",
            "",
            "✻ Cooked for 2s",
            rule,
            "❯ ",
            rule,
            "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents",
        ]
        XCTAssertNil(InputBlock.detect(screen: screen))
    }

    func testIdleScreenIsNotMenu() {
        let screen = [
            "⏺ User declined to answer questions",
            "  ⎿  · Pick a color? (Red / Blue)",
            rule,
            "❯ Try \"fix lint errors\"",
            rule,
            "  ⏵⏵ auto mode on (shift+tab to cycle)",
        ]
        XCTAssertNil(InputBlock.detect(screen: screen))
    }

    func testSingleNumberedLineIsNotMenu() {
        XCTAssertFalse(ChoiceMenu.isShowing(screen: ["❯ 1. only one", "text"]))
        XCTAssertFalse(ChoiceMenu.isShowing(screen: ["❯ 1. one", "  3. three"]))
    }
}

final class TerminalScreenTests: XCTestCase {
    func testLineCountFindsBoundary() {
        for count in [0, 1, 5, 40, 41, 79, 80, 81, 539, 1000] {
            var calls = 0
            let found = TerminalScreen.lineCount(rows: 40) { calls += 1; return $0 < count }
            XCTAssertEqual(found, count, "count \(count)")
            XCTAssertLessThan(calls, 45, "count \(count)")
        }
    }
}

final class UnreadCountsTests: XCTestCase {
    func testCountsAllSessionsInOnePass() {
        func f(_ id: Int, _ s: String, _ kind: FeedKind, _ at: Double) -> FeedItem {
            FeedItem(id: id, sessionId: s, project: "p", at: at, kind: kind, text: "", tool: nil, local: nil)
        }
        let feed = [f(1, "s1", .message, 10), f(2, "s1", .message, 30), f(3, "s1", .tool, 40), f(4, "s2", .message, 50),
                    f(5, "s3", .message, 5)]
        let counts = RoomGrouping.unreadCounts(feed: feed, since: ["s1": 20], defaultSince: 8)
        XCTAssertEqual(counts["s1"], 1)
        XCTAssertEqual(counts["s2"], 1)
        XCTAssertNil(counts["s3"])
    }
}
