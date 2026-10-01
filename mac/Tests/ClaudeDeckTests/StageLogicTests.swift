import XCTest
@testable import MonitorKit

final class StageLogicTests: XCTestCase {
    private func session(status: SessionStatus = .working, tool: String? = nil, skill: String? = nil,
                         action: String? = nil, agents: [AgentInfo] = []) -> SessionSnapshot {
        SessionSnapshot(sessionId: "s", pid: 1, alive: true, name: "s", project: "p", cwd: "/", branch: nil, title: nil,
                        lastPrompt: nil, status: status, statusSource: .hook, statusDetail: nil, entrypoint: nil,
                        version: nil, startedAt: 0, lastActivityAt: nil, currentTool: tool, currentSkill: skill,
                        currentAction: action, tokens: nil, agents: agents, canReceive: true, xcodeProject: nil)
    }

    private func feedItem(_ id: Int, _ sessionId: String) -> FeedItem {
        FeedItem(id: id, sessionId: sessionId, project: "p", at: 0, kind: .tool, text: "\(id)", tool: nil, local: nil)
    }

    // MARK: - いまの動き

    func testActionLinePrefersSkillThenActionThenTool() {
        XCTAssertEqual(StageLogic.actionLine(session(tool: "Bash", skill: "developer-plugin:dev-done", action: "テスト実行")),
                       "巻物『dev-done』を広げている")
        XCTAssertEqual(StageLogic.actionLine(session(tool: "Bash", action: "テスト実行")), "テスト実行")
        XCTAssertEqual(StageLogic.actionLine(session(tool: "Bash")), "端末を叩いている")
        XCTAssertEqual(StageLogic.actionLine(session(tool: "mcp__x__y")), "手を動かしている")
    }

    func testActionLineIsNilUnlessWorkingOrForAgentTool() {
        XCTAssertNil(StageLogic.actionLine(session(status: .idle, tool: "Bash")))
        XCTAssertNil(StageLogic.actionLine(session(tool: "Agent")))
        XCTAssertNil(StageLogic.actionLine(session(tool: "Task")))
        XCTAssertNil(StageLogic.actionLine(session(tool: nil)))
    }

    func testSkillLabelDropsPluginPrefix() {
        XCTAssertEqual(StageLogic.skillLabel("developer-plugin:dev-done"), "dev-done")
        XCTAssertEqual(StageLogic.skillLabel("loop"), "loop")
    }

    // MARK: - サブエージェント

    func testJobAndEscortLine() {
        XCTAssertEqual(StageLogic.job(for: "Explore").label, "斥候")
        XCTAssertEqual(StageLogic.job(for: "developer-plugin:code-reviewer").label, "監査役")
        XCTAssertEqual(StageLogic.job(for: nil).label, "従者")
        XCTAssertEqual(StageLogic.job(for: "unknown").label, "従者")

        let agents = [AgentInfo(id: "b", type: "Plan", lastActivityAt: 2), AgentInfo(id: "a", type: "Explore", lastActivityAt: 1)]
        XCTAssertEqual(StageLogic.escortLine(agents), "斥候 ほか1名が随伴")
        XCTAssertEqual(StageLogic.escortLine([agents[0]]), "軍師が随伴")
        XCTAssertNil(StageLogic.escortLine([]))
        XCTAssertEqual(StageLogic.sortedAgents(agents).map(\.id), ["a", "b"])
    }

    func testAgentActivity() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(StageLogic.activity(of: AgentInfo(id: "a", type: nil, lastActivityAt: 995_000), now: now), .active)
        XCTAssertEqual(StageLogic.activity(of: AgentInfo(id: "a", type: nil, lastActivityAt: 940_000), now: now), .quiet(seconds: 60))
    }

    // MARK: - 時間

    func testAgoAndDuration() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(StageLogic.ago(nil, now: now), "—")
        XCTAssertEqual(StageLogic.ago(now.addingTimeInterval(-12), now: now), "12秒前")
        XCTAssertEqual(StageLogic.ago(now.addingTimeInterval(-125), now: now), "2分前")
        XCTAssertEqual(StageLogic.ago(now.addingTimeInterval(-7200), now: now), "2時間前")
        XCTAssertEqual(StageLogic.duration(since: now.addingTimeInterval(-300), now: now), "5分")
        XCTAssertEqual(StageLogic.duration(since: now.addingTimeInterval(-3900), now: now), "1時間5分")
    }

    // MARK: - ライブフィード

    func testFeedFiltersBySessionNewestFirstWithLimit() {
        let items = [feedItem(1, "s"), feedItem(2, "x"), feedItem(3, "s"), feedItem(4, "s")]
        XCTAssertEqual(StageLogic.feed(items, sessionId: "s").map(\.id), [4, 3, 1])
        XCTAssertEqual(StageLogic.feed(items, sessionId: "s", limit: 2).map(\.id), [4, 3])
        XCTAssertEqual(StageLogic.feed(items, sessionId: nil), [])
    }

    // MARK: - 埋め込み URL

    func testEmbedURL() {
        let base = URL(string: "http://127.0.0.1:8799")!
        let url = StageLogic.embedURL(base: base, sessionId: "abc-123", mode: .solid, background: 0x0b111d)
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:8799/?embed=stage&session=abc-123&mode=3d&bg=0b111d")
        let clear = StageLogic.embedURL(base: URL(string: "http://127.0.0.1:8766/x?y=1#z")!, sessionId: "s", mode: .flat, background: nil)
        XCTAssertEqual(clear.absoluteString, "http://127.0.0.1:8766/?embed=stage&session=s&mode=2d&bg=transparent")
        let plus = StageLogic.embedURL(base: base, sessionId: "a+b", mode: .flat, background: nil)
        XCTAssertTrue(plus.absoluteString.contains("session=a%2Bb"))
    }

    func testToolVerbIgnoresEmptyTool() {
        XCTAssertNil(StageLogic.toolVerb(""))
        XCTAssertNil(StageLogic.toolVerb(nil))
        XCTAssertNotNil(StageLogic.toolVerb("Bash"))
    }

    // MARK: - プレースホルダー

    func testContentPlaceholders() {
        func content(connected: Bool = true, phase: MonitorLaunchPhase = .usingExisting, room: Bool = true,
                     id: String? = "s", known: Bool = true) -> StageContent {
            StageLogic.content(connected: connected, launchPhase: phase, hasRoom: room, sessionId: id, sessionKnown: known)
        }
        XCTAssertEqual(content(), .stage(sessionId: "s"))
        XCTAssertEqual(content(connected: false, phase: .building), .placeholder("monitor を準備しています（UI をビルド中）…"))
        XCTAssertEqual(content(connected: false, phase: .starting(pid: 1)), .placeholder("monitor を起動しています…"))
        XCTAssertEqual(content(connected: false, phase: .failed(.nodeNotFound)), .placeholder("monitor を起動できませんでした"))
        XCTAssertEqual(content(connected: false), .placeholder("monitor に接続していません（自動で再接続します）"))
        XCTAssertEqual(content(room: false), .placeholder("ルームを選ぶとステージを表示します"))
        XCTAssertEqual(content(id: nil), .placeholder("セッションを確認しています…"))
        XCTAssertEqual(content(known: false), .placeholder("monitor がこのセッションをまだ見つけていません"))
    }

    // MARK: - 開閉

    func testExpandedFollowsPreferenceAndWindowWidth() {
        XCTAssertFalse(StageLogic.isExpanded(preference: false, windowWidth: 1600, openedWhileNarrow: false))
        XCTAssertTrue(StageLogic.isExpanded(preference: true, windowWidth: 1600, openedWhileNarrow: false))
        XCTAssertTrue(StageLogic.isExpanded(preference: true, windowWidth: nil, openedWhileNarrow: false))
        XCTAssertFalse(StageLogic.isExpanded(preference: true, windowWidth: 900, openedWhileNarrow: false))
        XCTAssertTrue(StageLogic.isExpanded(preference: true, windowWidth: 900, openedWhileNarrow: true))
    }
}
