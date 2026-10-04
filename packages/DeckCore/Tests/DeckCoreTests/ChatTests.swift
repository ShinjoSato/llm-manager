import XCTest
@testable import DeckCore

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

    func testEntriesFlattenWithStableRowIds() {
        let before = RoomGrouping.entries(RoomGrouping.group([room("a", .idle, at: 1), room("b", .working, at: 2)]))
        XCTAssertEqual(before, [.header(.active, count: 1), .row("b"), .header(.idle, count: 1), .row("a")])
        XCTAssertEqual(Set(before.map(\.id)).count, before.count)
        // 待機 → 稼働中 に移っても行の id は変わらず、置き場所だけが変わる。
        let after = RoomGrouping.entries(RoomGrouping.group([room("a", .working, at: 3), room("b", .working, at: 2)]))
        XCTAssertEqual(after, [.header(.active, count: 2), .row("a"), .row("b")])
        XCTAssertEqual(after[1].id, before[3].id)
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
        XCTAssertEqual(RoomGrouping.unreadCounts(feed: feed, since: ["s1": 20], defaultSince: 0)["s1"], 1)
        XCTAssertEqual(RoomGrouping.unreadCounts(feed: feed, since: [:], defaultSince: 0)["s1"], 2)
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
    typealias B = ChatMarkdown.Block

    func testSplitsFencedCode() {
        let blocks = ChatMarkdown.blocks("前置き\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n後書き")
        XCTAssertEqual(blocks, [.paragraph("前置き"), .code(language: "swift", "let a = 1\n\nlet b = 2"), .paragraph("後書き")])
    }

    func testFencedCodeKeepsTabs() {
        XCTAssertEqual(ChatMarkdown.blocks("```go\nfunc f() {\n\treturn\t1\n}\n```"),
                       [.code(language: "go", "func f() {\n\treturn\t1\n}")])
        XCTAssertEqual(ChatMarkdown.blocks("- a\n  ```\n  \tx\ty\n  ```"),
                       [.list(ordered: false, start: 0, items: [.init([.paragraph("a"), .code(language: nil, "\tx\ty")])])])
    }

    func testTabsCountAsIndent() {
        XCTAssertEqual(ChatMarkdown.blocks("- a\n\t- b"), [
            .list(ordered: false, start: 0, items: [
                .init([.paragraph("a"), .list(ordered: false, start: 0, items: [.init([.paragraph("b")])])]),
            ]),
        ])
        XCTAssertEqual(ChatMarkdown.blocks("-\tx"), [.list(ordered: false, start: 0, items: [.init([.paragraph("x")])])])
    }

    func testOnlyWebLinksOpen() {
        for s in ["http://example.com", "https://example.com/a?b=c", "HTTPS://EXAMPLE.COM"] {
            XCTAssertTrue(ChatMarkdown.isOpenableLink(URL(string: s)!), s)
        }
        for s in ["file:///etc/passwd", "vscode://file/x", "javascript:alert(1)", "mailto:a@example.com", "relative/path"] {
            XCTAssertFalse(ChatMarkdown.isOpenableLink(URL(string: s)!), s)
        }
    }

    func testUnclosedFenceRunsToEnd() {
        XCTAssertEqual(ChatMarkdown.blocks("a\n```\nx"), [.paragraph("a"), .code(language: nil, "x")])
    }

    func testMarkdownInsideCodeIsNotInterpreted() {
        let src = "```md\n# 見出しではない\n| a | b |\n|---|---|\n- リストではない\n> 引用ではない\n---\n```"
        XCTAssertEqual(ChatMarkdown.blocks(src),
                       [.code(language: "md", "# 見出しではない\n| a | b |\n|---|---|\n- リストではない\n> 引用ではない\n---")])
    }

    func testTildeFenceAndLongerClosingFence() {
        XCTAssertEqual(ChatMarkdown.blocks("~~~\n```\n~~~"), [.code(language: nil, "```")])
        XCTAssertEqual(ChatMarkdown.blocks("````\n```\n````\nafter"), [.code(language: nil, "```"), .paragraph("after")])
    }

    func testParagraphKeepsLineBreaks() {
        XCTAssertEqual(ChatMarkdown.blocks("一行目\n二行目\n\n次の段落"), [.paragraph("一行目\n二行目"), .paragraph("次の段落")])
    }

    func testHeadings() {
        XCTAssertEqual(ChatMarkdown.blocks("# 大\n## 中 ##\n### 小\n#ハッシュタグ\n## C#"),
                       [.heading(level: 1, "大"), .heading(level: 2, "中"), .heading(level: 3, "小"),
                        .paragraph("#ハッシュタグ"), .heading(level: 2, "C#")])
        XCTAssertEqual(ChatMarkdown.blocks("####### 七つ"), [.paragraph("####### 七つ")])
    }

    func testRules() {
        XCTAssertEqual(ChatMarkdown.blocks("a\n\n---\n\n***\n- - -\nb"), [.paragraph("a"), .rule, .rule, .rule, .paragraph("b")])
        XCTAssertEqual(ChatMarkdown.blocks("--"), [.paragraph("--")])
    }

    func testBulletAndOrderedLists() {
        XCTAssertEqual(ChatMarkdown.blocks("- a\n- b\n\n3. c\n4. d"), [
            .list(ordered: false, start: 0, items: [.init([.paragraph("a")]), .init([.paragraph("b")])]),
            .list(ordered: true, start: 3, items: [.init([.paragraph("c")]), .init([.paragraph("d")])]),
        ])
        XCTAssertEqual(ChatMarkdown.blocks("**太字**の段落"), [.paragraph("**太字**の段落")])
    }

    func testNestedLists() {
        let src = "- 親1\n  - 子1\n    - 孫\n  - 子2\n- 親2\n1. 番号\n   - 下の箇条"
        XCTAssertEqual(ChatMarkdown.blocks(src), [
            .list(ordered: false, start: 0, items: [
                .init([.paragraph("親1"), .list(ordered: false, start: 0, items: [
                    .init([.paragraph("子1"), .list(ordered: false, start: 0, items: [.init([.paragraph("孫")])])]),
                    .init([.paragraph("子2")]),
                ])]),
                .init([.paragraph("親2")]),
            ]),
            .list(ordered: true, start: 1, items: [
                .init([.paragraph("番号"), .list(ordered: false, start: 0, items: [.init([.paragraph("下の箇条")])])]),
            ]),
        ])
    }

    func testListItemContinuationAndLooseItems() {
        let src = "- 一行目\n続き\n\n- 二つ目\n\n  二つ目の段落\n\n本文"
        XCTAssertEqual(ChatMarkdown.blocks(src), [
            .list(ordered: false, start: 0, items: [
                .init([.paragraph("一行目\n続き")]),
                .init([.paragraph("二つ目"), .paragraph("二つ目の段落")]),
            ]),
            .paragraph("本文"),
        ])
    }

    func testCodeInsideListItem() {
        XCTAssertEqual(ChatMarkdown.blocks("1. 実行:\n   ```sh\n   # コメント\n   ls\n   ```"), [
            .list(ordered: true, start: 1, items: [.init([.paragraph("実行:"), .code(language: "sh", "# コメント\nls")])]),
        ])
    }

    func testQuote() {
        XCTAssertEqual(ChatMarkdown.blocks("> 引用\n> - 項目\n>\n> > 入れ子\n本文"), [
            .quote([.paragraph("引用"), .list(ordered: false, start: 0, items: [.init([.paragraph("項目")])]),
                    .quote([.paragraph("入れ子")])]),
            .paragraph("本文"),
        ])
    }

    func testTableWithAlignment() {
        let src = "前置き\n| Issue | 内容 | 数 | 中央 |\n|---|:---|---:|:-:|\n| #1 | **太字** | 3 | x |\n| #2 | 短い |\n\n後書き"
        XCTAssertEqual(ChatMarkdown.blocks(src), [
            .paragraph("前置き"),
            .table(.init(header: ["Issue", "内容", "数", "中央"],
                         alignments: [.leading, .leading, .trailing, .center],
                         rows: [["#1", "**太字**", "3", "x"], ["#2", "短い", "", ""]])),
            .paragraph("後書き"),
        ])
    }

    func testTableWithoutOuterPipesAndExtraCells() {
        XCTAssertEqual(ChatMarkdown.blocks("a | b\n--- | ---\n1 | 2 | 3"),
                       [.table(.init(header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", "2"]]))])
    }

    func testTableEscapedPipeAndBreaks() {
        XCTAssertEqual(ChatMarkdown.splitRow(#"| `a \| b` | x\|y | 1<br>2 | \* |"#), ["`a | b`", "x|y", "1\n2", "\\*"])
        XCTAssertEqual(ChatMarkdown.splitRow("| `a | b` |"), ["`a", "b`"])
    }

    func testMismatchedDelimiterIsNotATable() {
        XCTAssertEqual(ChatMarkdown.blocks("| a | b |\n|---|\n| 1 | 2 |"), [.paragraph("| a | b |\n|---|\n| 1 | 2 |")])
        XCTAssertEqual(ChatMarkdown.blocks("見出し\n---"), [.paragraph("見出し"), .rule])
    }

    func testMalformedInputDoesNotCrash() {
        let inputs = ["", "\n\n", "|", "||", "|-|", "| a |\n|", ">", "> ", "-", "- ", "1.", "1)", "#", "```", "~~~~",
                      "\t- tab\n\t\t- deep", "\r\n- crlf\r\n", String(repeating: ">", count: 500) + " deep",
                      String(repeating: "  ", count: 300) + "- x", (0..<200).map { String(repeating: "  ", count: $0) + "- n" }.joined(separator: "\n"),
                      "| a | b |\n|:-:|:-:|", "- a\n\n\n", "1. a\n- b\n2. c", "\\", "| \\"]
        for input in inputs {
            _ = ChatMarkdown.blocks(input)
        }
        XCTAssertEqual(ChatMarkdown.blocks(""), [])
        XCTAssertEqual(ChatMarkdown.blocks("| a | b |\n|:-:|:-:|"),
                       [.table(.init(header: ["a", "b"], alignments: [.center, .center], rows: []))])
    }

    func testInlineBoldCodeAndNewlines() {
        let s = ChatMarkdown.inline("**太字** と `code`\n次の行")
        XCTAssertEqual(String(s.characters), "太字 と code\n次の行")
        let bold = s.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertEqual(bold.map { String(s[$0.range].characters) }, "太字")
        let code = s.runs.first { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertEqual(code.map { String(s[$0.range].characters) }, "code")
    }

    func testInlineLinkAndItalic() {
        let s = ChatMarkdown.inline("[PR](https://github.com/x/y/pull/1) と *斜体*")
        let link = s.runs.first { $0.link != nil }
        XCTAssertEqual(link?.link, URL(string: "https://github.com/x/y/pull/1"))
        XCTAssertEqual(link.map { String(s[$0.range].characters) }, "PR")
        XCTAssertNotNil(s.runs.first { $0.inlinePresentationIntent?.contains(.emphasized) == true })
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
