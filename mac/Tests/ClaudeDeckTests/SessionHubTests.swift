import XCTest
@testable import MonitorKit

/// 実況層の読み取り（移植元: monitor/src/transcript.ts）。
final class TranscriptTailTests: XCTestCase {
    typealias F = FakeClaudeHome

    private func parse(_ line: String) -> ParsedEvent { TranscriptTail.parseLine(Array(line.utf8))! }

    func testUserLineKinds() {
        XCTAssertEqual(parse(F.user("u", "やって")).userKind, .prompt)
        XCTAssertEqual(parse(F.user("u", "/review")).userKind, .prompt)
        XCTAssertEqual(parse(F.user("u", "<command-name>/review</command-name>")).userKind, .prompt, "スラッシュコマンドは指示")
        XCTAssertEqual(parse(F.user("u", "<task-notification>x</task-notification>")).userKind, .toolResult, "仕組み側の注入")
        XCTAssertEqual(parse(F.user("u", [["type": "text", "text": "  <ide_opened_file>a</ide_opened_file>"]])).userKind, .toolResult)
        XCTAssertEqual(parse(F.user("u", [["type": "tool_result", "content": "ok"]])).userKind, .toolResult)
        XCTAssertEqual(parse(F.user("u", "x", extra: ["isMeta": true])).userKind, .toolResult)
        XCTAssertEqual(parse(F.user("u", "a < b")).userKind, .prompt, "タグで始まらなければ指示")
    }

    func testAssistantLine() {
        let ev = parse(F.assistant("a", [
            ["type": "tool_use", "name": "Skill", "input": ["skill": "developer-plugin:dev-done"]],
            ["type": "tool_use", "name": "Bash", "input": ["description": "テスト"]],
            ["type": "text", "text": "  進めます "],
        ], extra: ["gitBranch": "feature/111", "message": ["role": "assistant", "content": [
            ["type": "tool_use", "name": "Skill", "input": ["skill": "developer-plugin:dev-done"]],
            ["type": "tool_use", "name": "Bash", "input": ["description": "テスト"]],
            ["type": "text", "text": "  進めます "],
        ], "usage": ["input_tokens": 10, "output_tokens": 20, "cache_read_input_tokens": 30]]]))
        XCTAssertEqual(ev.tools, ["Skill", "Bash"])
        XCTAssertEqual(ev.toolDetail?.skill, "developer-plugin:dev-done", "skill 付きを優先する")
        XCTAssertEqual(ev.text, "進めます")
        XCTAssertEqual(ev.branch, "feature/111")
        XCTAssertEqual(ev.usage, TokenUsage(input: 10, output: 20, cacheRead: 30))
        XCTAssertEqual(ev.at, millis(F.timestamp))

        let last = parse(F.assistant("a", [["type": "tool_use", "name": "Read", "input": [:] as [String: Any]],
                                           ["type": "tool_use", "name": "Bash", "input": ["description": "後勝ち"]]]))
        XCTAssertEqual(last.toolDetail?.name, "Bash")
        XCTAssertEqual(last.toolDetail?.description, "後勝ち")
        XCTAssertNil(TranscriptTail.parseLine(Array("{broken".utf8)))
        XCTAssertEqual(parse(F.json(["type": "ai-title", "aiTitle": "作業"])).title, "作業")
        XCTAssertEqual(parse(F.json(["type": "last-prompt", "lastPrompt": "前回"])).lastPrompt, "前回")
    }

    func testReaderBootstrapsFromTailAndReadsAppends() throws {
        let home = try FakeClaudeHome()
        defer { home.remove() }
        let url = home.root.appendingPathComponent("big.jsonl")
        // 先頭に ai-title、続けて 512KB を超える詰め物。末尾読みでは title を取りこぼすので primeMeta で拾う。
        var text = F.json(["type": "ai-title", "aiTitle": "大きな作業"]) + "\n"
        let filler = F.json(["type": "attachment", "x": String(repeating: "y", count: 1000)]) + "\n"
        while text.utf8.count < TranscriptTail.bootstrapBytes + 10_000 { text += filler }
        text += F.assistant("a1", [["type": "tool_use", "name": "Bash", "input": [:] as [String: Any]]]) + "\n"
        try home.appendRaw(Data(text.utf8), to: url)

        let reader = TranscriptReader(path: url.path)
        let first = reader.read()
        XCTAssertFalse(first.contains { $0.title != nil }, "末尾だけを読む")
        XCTAssertEqual(first.last?.tools, ["Bash"])
        XCTAssertTrue(first.allSatisfy { $0.type == "attachment" || $0.type == "assistant" }, "途中で切れた先頭の行は捨てる")
        XCTAssertEqual(TranscriptTail.primeMeta(path: url.path).title, "大きな作業")
        XCTAssertTrue(reader.read().isEmpty)

        let line = Data((F.user("u1", "絵文字 🎉") + "\n").utf8)
        let cut = line.range(of: Data("🎉".utf8))!.lowerBound + 1
        try home.appendRaw(line.prefix(cut), to: url)
        XCTAssertTrue(reader.read().isEmpty)
        try home.appendRaw(line.suffix(from: cut), to: url)
        XCTAssertEqual(reader.read().map(\.userKind), [.prompt])

        // 切り詰められたら読み直す。
        try Data((F.user("u9", "新しい") + "\n").utf8).write(to: url)
        XCTAssertEqual(reader.read().map(\.type), ["user"])
    }
}

/// 在庫層（移植元: monitor/src/inventory.ts）。
final class SessionInventoryTests: XCTestCase {
    func testScanSkipsBrokenAndIncomplete() throws {
        let home = try FakeClaudeHome()
        defer { home.remove() }
        try home.writeSession(pid: 4242, sessionId: "s1", cwd: "/a", extra: ["name": "n", "entrypoint": "cli", "kind": "interactive",
                                                                           "messagingSocketPath": "~/x.sock", "version": "2.1.286"])
        try Data("{ half".utf8).write(to: home.root.appendingPathComponent("sessions/1.json"))
        try Data(#"{"pid":2,"sessionId":"","cwd":"/b"}"#.utf8).write(to: home.root.appendingPathComponent("sessions/2.json"))
        try Data(#"{"pid":0,"sessionId":"s0","cwd":"/b"}"#.utf8).write(to: home.root.appendingPathComponent("sessions/0.json"))
        try Data("x".utf8).write(to: home.root.appendingPathComponent("sessions/readme.txt"))
        let list = SessionInventory.scan(directory: home.home.sessionsDirectory, isAlive: { $0 == 4242 })
        XCTAssertEqual(list, [RawSession(pid: 4242, sessionId: "s1", cwd: "/a", startedAt: 1000, name: "n", version: "2.1.286",
                                         entrypoint: "cli", kind: "interactive", messagingSocketPath: "~/x.sock", alive: true)])
        XCTAssertEqual(SessionInventory.scan(directory: home.root.appendingPathComponent("missing")), [])
        XCTAssertTrue(SessionInventory.processAlive(getpid()))
    }

    func testSlugAndSubagentDirectory() {
        XCTAssertEqual(ClaudeHome.slug(forCwd: "/Users/x/my_proj.v2"), "-Users-x-my-proj-v2")
        XCTAssertEqual(ClaudeHome.slug(forCwd: "/a/日本"), "-a---")
        XCTAssertEqual(ClaudeHome.subagentDirectory(forTranscript: "/p/s1.jsonl"), "/p/s1/subagents")
    }

    func testXcodeFinderPrefersShallowWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("ios/App.xcodeproj/project.xcworkspace"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("ios/App.xcworkspace"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("node_modules/x/Bad.xcworkspace"), withIntermediateDirectories: true)
        let found = XcodeFinder.find(in: root.path)
        XCTAssertEqual(found.map { URL(fileURLWithPath: $0).lastPathComponent }, "App.xcworkspace")
        try fm.createDirectory(at: root.appendingPathComponent("Top.xcodeproj"), withIntermediateDirectories: true)
        XCTAssertEqual(XcodeFinder.find(in: root.path).map { URL(fileURLWithPath: $0).lastPathComponent }, "Top.xcodeproj", "浅い方を選ぶ")
        XCTAssertNil(XcodeFinder.find(in: root.appendingPathComponent("node_modules").path.appending("/none")))
    }

    func testEditorOpenRejectsRelativeTargets() async {
        let reason = await EditorOpen.open(.vscode, target: "-a Terminal")
        XCTAssertEqual(reason, "開く先が絶対パスではありません")
        XCTAssertEqual(EditorOpen.failureReason(timedOut: true, stderr: "x", fallback: "y"), "応答がありません（確認ダイアログが出ているかもしれません）")
        XCTAssertEqual(EditorOpen.failureReason(timedOut: false, stderr: "  やられた  ", fallback: "y"), "やられた")
        XCTAssertEqual(EditorOpen.failureReason(timedOut: false, stderr: "", fallback: "boom"), "boom")
    }
}

/// 状態の合成・フック・要対応・権限の中継（移植元: monitor/src/hub.ts）。
final class SessionHubTests: XCTestCase {
    typealias F = FakeClaudeHome
    let sessionId = "11111111-2222-3333-4444-555555555555"
    let cwd = "/tmp/proj-a"
    let pid: Int32 = 4242
    var home: FakeClaudeHome!
    var clock: TestClock!
    var alive: Box<Set<Int32>>!

    override func setUpWithError() throws {
        home = try FakeClaudeHome()
        clock = TestClock(millis(F.timestamp) + 1_000)
        alive = Box([pid])
    }

    override func tearDown() {
        home.remove()
    }

    private func makeHub(usageFile: URL? = nil) -> (SessionHub, Box<[MonitorEvent]>) {
        let clock = clock!
        let alive = alive!
        let hub = SessionHub(home: home.home, usageFile: usageFile, now: { clock.now }, isAlive: { alive.value.contains($0) })
        let events = Box<[MonitorEvent]>([])
        return (hub, events)
    }

    private func started(usageFile: URL? = nil) async throws -> (SessionHub, Box<[MonitorEvent]>) {
        let (hub, events) = makeHub(usageFile: usageFile)
        await hub.setSink { e in events.mutate { $0.append(e) } }
        await hub.scanInventory()
        await hub.pollTranscripts()
        return (hub, events)
    }

    private func snap(_ hub: SessionHub) async -> SessionSnapshot? {
        await hub.snapshot().first { $0.sessionId == sessionId }
    }

    private func required(_ hub: SessionHub) async throws -> SessionSnapshot {
        let value = await snap(hub)
        return try XCTUnwrap(value)
    }

    private func feedTexts(_ events: Box<[MonitorEvent]>) -> [String] {
        events.value.compactMap { if case .feed(let f) = $0 { return f.text } else { return nil } }
    }

    private func append(_ lines: String...) throws {
        try home.appendTranscript(sessionId: sessionId, cwd: cwd, lines: lines)
    }

    func testInventoryAndTranscriptStatus() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd, extra: ["entrypoint": "cli"])
        try append(F.json(["type": "ai-title", "aiTitle": "移植"]),
                   F.user("u1", "やって", extra: ["gitBranch": "feature/111"]),
                   F.assistant("a1", [["type": "tool_use", "name": "Bash", "input": ["description": "テストを実行"]]]))
        let (hub, events) = try await started()

        var s = try await required(hub)
        XCTAssertEqual(s.project, "proj-a")
        XCTAssertEqual(s.name, "proj-a")
        XCTAssertEqual(s.title, "移植")
        XCTAssertEqual(s.branch, "feature/111")
        XCTAssertEqual(s.status, .working, "ツール実行中で終わっていれば稼働中")
        XCTAssertEqual(s.statusSource, .transcript)
        XCTAssertEqual(s.currentTool, "Bash")
        XCTAssertEqual(s.currentAction, "テストを実行")
        XCTAssertEqual(s.entrypoint, "cli")
        XCTAssertNil(s.attentionSince)
        XCTAssertTrue(feedTexts(events).contains("セッション検出: proj-a"))
        XCTAssertFalse(feedTexts(events).contains("Bash"), "起動前に書かれた行は新着としてフィードに積まない")

        // 無音が 10 分を超えたら稼働中とみなさない（中断の保険）。
        clock.advance(SessionHub.staleBusy)
        s = try await required(hub)
        XCTAssertEqual(s.status, .idle)
        XCTAssertNil(s.currentTool, "稼働中でなければ道具は出さない")

        clock.set(millis(F.timestamp) + 2_000)
        try append(F.assistant("a2", [["type": "text", "text": "終わりました"]]))
        await hub.pollTranscripts()
        s = try await required(hub)
        XCTAssertEqual(s.status, .idle, "テキストだけの応答で終われば待機")
        XCTAssertTrue(feedTexts(events).contains("終わりました"))
    }

    func testHooksDriveAttention() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        try append(F.assistant("a1", [["type": "tool_use", "name": "Bash", "input": ["description": "テストを実行"]]]))
        let (hub, events) = try await started()

        let hookAt = clock.now + 5_000
        clock.set(hookAt)
        let applied = await hub.applyHook(HookPayload(sessionId: sessionId, hookEventName: "Notification", toolName: "Bash",
                                                      notificationType: "permission_prompt"))
        XCTAssertTrue(applied)
        var s = try await required(hub)
        XCTAssertEqual(s.status, .permission)
        XCTAssertEqual(s.statusSource, .hook)
        XCTAssertEqual(s.statusDetail, "Bash: テストを実行", "同じツールなら説明を添える")
        XCTAssertEqual(s.attentionSince, hookAt)
        XCTAssertTrue(feedTexts(events).contains("権限の確認待ち: Bash: テストを実行"))

        // 要対応どうしの移り変わりは待ち始めを引き継ぐ。
        clock.advance(1_000)
        await hub.applyHook(HookPayload(sessionId: sessionId, hookEventName: "Notification", notificationType: "idle_prompt",
                                        notificationMessage: "Claude is waiting for your input"))
        s = try await required(hub)
        XCTAssertEqual(s.status, .waiting)
        XCTAssertEqual(s.statusDetail, "Claude is waiting for your input")
        XCTAssertEqual(s.attentionSince, hookAt)

        // 未知の通知はフィードに出す（フック層が効いていないことに気づけるように）。状態は変えない。
        await hub.applyHook(HookPayload(sessionId: sessionId, hookEventName: "Notification", notificationType: "brand_new"))
        XCTAssertTrue(feedTexts(events).contains("通知: brand_new"))
        let unchanged = await snap(hub)
        XCTAssertEqual(unchanged?.status, .waiting)

        // フックより新しいログ行（ツール）を読んだら待ちを解く。
        let later = iso(clock.now + 1_000)
        clock.advance(2_000)
        try append(F.assistant("a2", [["type": "tool_use", "name": "Edit", "input": [:] as [String: Any]]], timestamp: later))
        await hub.pollTranscripts()
        s = try await required(hub)
        XCTAssertEqual(s.status, .working)
        XCTAssertNil(s.attentionSince)

        await hub.applyHook(HookPayload(sessionId: sessionId, hookEventName: "StopFailure", errorType: "rate_limit"))
        s = try await required(hub)
        XCTAssertEqual(s.status, .error)
        XCTAssertEqual(s.statusDetail, "rate_limit")

        await hub.applyHook(HookPayload(sessionId: sessionId, hookEventName: "UserPromptSubmit"))
        do { let v = await snap(hub); XCTAssertEqual(v?.status, .working) }
        await hub.applyHook(HookPayload(sessionId: sessionId, hookEventName: "SubagentStart", agentType: "Explore"))
        XCTAssertTrue(feedTexts(events).contains("サブエージェント開始: Explore"))

        let unknown = await hub.applyHook(HookPayload(sessionId: "nope", hookEventName: "Stop"))
        XCTAssertFalse(unknown, "知らないセッションは反映しない")
        let empty = await hub.applyHook(HookPayload())
        XCTAssertFalse(empty)
    }

    func testOldLinesDoNotClearNewerHook() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        let (hub, _) = try await started()
        clock.advance(10_000)
        await hub.applyHook(HookPayload(sessionId: sessionId, hookEventName: "Notification", toolName: "Bash",
                                        notificationType: "permission_prompt"))
        // フックより古い時刻のツール行が後から読まれても権限待ちは消さない。
        try append(F.assistant("a1", [["type": "tool_use", "name": "Bash", "input": [:] as [String: Any]]]))
        await hub.pollTranscripts()
        do { let v = await snap(hub); XCTAssertEqual(v?.status, .permission) }
    }

    func testStoppedSessionsAreKeptForFiveMinutes() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        let (hub, events) = try await started()
        alive.mutate { $0.remove(pid) }
        await hub.scanInventory()
        var s = try await required(hub)
        XCTAssertEqual(s.status, .stopped)
        XCTAssertEqual(s.statusSource, .inventory)
        XCTAssertTrue(feedTexts(events).contains("セッション終了"))

        home.removeSession(pid: pid)
        await hub.scanInventory()
        s = try await required(hub)
        XCTAssertEqual(s.status, .stopped)
        clock.advance(SessionHub.stoppedRetention + 1)
        await hub.scanInventory()
        let gone = await snap(hub)
        XCTAssertNil(gone)
    }

    func testSubagentsKeepParentWorking() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        try append(F.assistant("a1", [["type": "text", "text": "裏で調べます"]]))
        let transcript = home.transcriptURL(sessionId: sessionId, cwd: cwd)
        let subagents = URL(fileURLWithPath: ClaudeHome.subagentDirectory(forTranscript: transcript.path))
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: subagents.appendingPathComponent("agent-abc.jsonl"))
        try Data(#"{"agentType":"Explore"}"#.utf8).write(to: subagents.appendingPathComponent("agent-abc.meta.json"))
        clock.set(Date().timeIntervalSince1970 * 1000)
        let (hub, _) = try await started()
        let s = try await required(hub)
        XCTAssertEqual(s.agents.map(\.id), ["abc"])
        XCTAssertEqual(s.agents.first?.type, "Explore")
        XCTAssertEqual(s.status, .working, "親が応答を終えていても子が動いていれば稼働中")
    }

    func testUsageIsReadAndOnlyEmittedOnChange() async throws {
        let usageURL = home.root.appendingPathComponent("claude-usage.json")
        try Data(#"{"fetchedAt":1,"fiveHour":{"usedPercentage":40}}"#.utf8).write(to: usageURL)
        let (hub, events) = makeHub(usageFile: usageURL)
        await hub.setSink { e in events.mutate { $0.append(e) } }
        await hub.pollUsage()
        await hub.pollUsage()
        let usages = events.value.compactMap { if case .usage(let u) = $0 { return u } else { return nil } }
        XCTAssertEqual(usages.count, 1)
        XCTAssertEqual(usages.first?.fiveHour?.usedPercentage, 40)
        let current = await hub.usageSnapshot()
        XCTAssertEqual(current?.fiveHour?.usedPercentage, 40)
    }

    func testPermissionRelayThroughHub() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        let (hub, events) = try await started()
        let input = PermissionRequestInput(requestId: "abcde", toolName: "Bash", description: "ls", inputPreview: "ls",
                                           pid: pid, cwd: "/elsewhere")
        let waiting = Task { await hub.awaitPermission(input, waitMillis: 5_000) }
        var pending: [PendingPermission] = []
        for _ in 0..<100 where pending.isEmpty {
            pending = await hub.pendingPermissions()
            if pending.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(pending.first?.sessionId, sessionId, "親 PID でセッションを引く")
        XCTAssertEqual(pending.first?.project, "proj-a")
        XCTAssertTrue(events.value.contains { if case .permissions(let l) = $0 { return l.count == 1 } else { return false } })
        let decided = await hub.decidePermission(key: input.key, decision: .allow)
        XCTAssertNotNil(decided)
        let outcome = await waiting.value
        XCTAssertEqual(outcome, .allow)
        XCTAssertTrue(feedTexts(events).contains("許可しました: Bash"))
        let again = await hub.decidePermission(key: input.key, decision: .deny)
        XCTAssertNil(again, "答えた後はもう待っていない")

        // 判断が出なければ timeout（チャネルが取り直す）。
        var other = input
        other.requestId = "fghij"
        let timedOut = await hub.awaitPermission(other, waitMillis: 30)
        XCTAssertEqual(timedOut, .timeout)
        let stillPending = await hub.pendingPermissions()
        XCTAssertEqual(stillPending.map(\.requestId), ["fghij"])

        // 預かった後のログ行で、端末側で答えられたとみなして落とす。
        clock.advance(1_000)
        let later = iso(clock.now)
        try append(F.user("u1", [["type": "tool_result", "content": "ok"]], timestamp: later))
        await hub.pollTranscripts()
        let afterLog = await hub.pendingPermissions()
        XCTAssertTrue(afterLog.isEmpty)
        XCTAssertTrue(feedTexts(events).contains("権限の確認は端末側で答えられたようです: Bash"))
    }

    /// 起動後に書かれた行は、初回の末尾読みでもフィードに積む（ログの時刻で見分ける）。
    func testInitialTailOnlyFeedsLinesWrittenAfterStart() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        try append(F.assistant("a0", [["type": "text", "text": "起動前の応答"]]),
                   F.assistant("a1", [["type": "text", "text": "起動後の応答"]], timestamp: iso(clock.now + 500)))
        let (hub, events) = try await started()
        let texts = feedTexts(events)
        XCTAssertFalse(texts.contains("起動前の応答"))
        XCTAssertTrue(texts.contains("起動後の応答"))
        let feed = await hub.recentFeed()
        XCTAssertEqual(feed.filter { $0.kind == .message }.count, 1, "未読数の元になる応答は起動後の分だけ")
    }

    /// フックは届いた順に反映する（待ち行列）。
    func testQueuedHooksAreAppliedInOrder() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        let (hub, _) = try await started()
        hub.enqueueHook(HookPayload(sessionId: sessionId, hookEventName: "UserPromptSubmit"))
        hub.enqueueHook(HookPayload(sessionId: sessionId, hookEventName: "Notification", toolName: "Bash",
                                    notificationType: "permission_prompt"))
        hub.enqueueHook(HookPayload(sessionId: sessionId, hookEventName: "Stop"))
        await hub.flushHooks()
        do { let v = await snap(hub); XCTAssertEqual(v?.status, .idle) }
        hub.enqueueHook(HookPayload(sessionId: sessionId, hookEventName: "Stop"))
        hub.enqueueHook(HookPayload(sessionId: sessionId, hookEventName: "Notification", toolName: "Bash",
                                    notificationType: "permission_prompt"))
        await hub.flushHooks()
        do { let v = await snap(hub); XCTAssertEqual(v?.status, .permission) }
    }

    /// メタ読み込みを止めておける監視（新しいセッションの検出直後を再現する）。
    private func gatedMetaHub(hookBufferLimit: Int = SessionHub.hookBufferLimit,
                              isAlive: (@Sendable (Int32) -> Bool)? = nil) -> (SessionHub, MetaGate) {
        let gate = MetaGate()
        let clock = clock!
        let alive = alive!
        let hub = SessionHub(home: home.home, usageFile: nil, now: { clock.now },
                             isAlive: isAlive ?? { alive.value.contains($0) },
                             hookBufferLimit: hookBufferLimit,
                             metaLoader: { cwd, path in
                                 gate.pass()
                                 return SessionHub.loadMetaFromDisk(cwd: cwd, transcriptPath: path)
                             })
        return (hub, gate)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 初回走査の await 中に start が重なっても、止めても、ループを二重に立てない・止めた後に立てない。
    func testStartIsNotReentrantAndStopWins() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        let (hub, gate) = gatedMetaHub()
        gate.close()
        let first = Task { await hub.start() }
        try await waitUntil { gate.waiting }
        // 初回走査のメタ読み込みを待っている間に、2 回目の start と stop を順に呼ぶ。
        await hub.start()
        await hub.stop()
        gate.open()
        await first.value
        let loops = await hub.loopCount
        XCTAssertEqual(loops, 0, "止めた後に初回走査が終わってもループを立てない")

        await hub.start()
        await hub.start()
        let restarted = await hub.loopCount
        XCTAssertEqual(restarted, 3, "二重に立てない")
        await hub.stop()
    }

    /// 初回走査の間に stop → start と呼ばれたら、最後の start が効いてループが立つ。
    func testStopThenStartDuringInitialScanKeepsRunning() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        let (hub, gate) = gatedMetaHub()
        gate.close()
        let first = Task { await hub.start() }
        try await waitUntil { gate.waiting }
        await hub.stop()
        await hub.start()
        gate.open()
        await first.value
        let loops = await hub.loopCount
        XCTAssertEqual(loops, 3)
        await hub.stop()
    }

    /// 未知のセッションのフックがメタ読み込みを待っても、後ろの既知のセッションのフックは待たされない。
    func testUnknownSessionHookDoesNotHoldBackOthers() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        let (hub, gate) = gatedMetaHub()
        await hub.scanInventory()
        gate.close()
        defer { gate.open() }

        let other = "99999999-2222-3333-4444-555555555555"
        let otherPid: Int32 = 4343
        alive.mutate { $0.insert(otherPid) }
        try home.writeSession(pid: otherPid, sessionId: other, cwd: "/tmp/proj-b")
        hub.enqueueHook(HookPayload(sessionId: other, hookEventName: "Stop"))
        hub.enqueueHook(HookPayload(sessionId: sessionId, hookEventName: "Notification", toolName: "Bash",
                                    notificationType: "permission_prompt"))
        let flushed = Box(false)
        let flushing = Task {
            await hub.flushHooks()
            flushed.mutate { $0 = true }
        }
        try await waitUntil { flushed.value && gate.waiting }
        XCTAssertTrue(gate.waiting, "未知のセッションのメタ読み込みは止めたまま")
        XCTAssertTrue(flushed.value, "メタ読み込みの完了を待たずに後ろのフックまで反映する")
        let statuses = await hub.snapshot().reduce(into: [String: SessionStatus]()) { $0[$1.sessionId] = $1.status }
        XCTAssertEqual(statuses[sessionId], .permission)
        XCTAssertEqual(statuses[other], .idle, "未知のセッションも在庫から取り込んで反映する")

        gate.open()
        if flushed.value { await flushing.value }
    }

    /// 検出直後で Xcode プロジェクトを探している間は「無い」と答えず、探し終わるのを待つ。
    func testXcodeProjectWaitsForMetaLoad() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: root.path)
        let (hub, gate) = gatedMetaHub()
        gate.close()
        defer { gate.open() }
        // フック経由の取り込みはメタ読み込みを待たない。
        await hub.applyHook(HookPayload(sessionId: sessionId, hookEventName: "Stop"))
        try await waitUntil { gate.waiting }
        let before = await snap(hub)
        XCTAssertNil(before?.xcodeProject, "まだ探し終わっていない")
        let resolving = Task { await hub.resolvedXcodeProject(sessionId: sessionId) }
        try await Task.sleep(for: .milliseconds(50))
        gate.open()
        let found = await resolving.value
        XCTAssertEqual(found.map { URL(fileURLWithPath: $0).lastPathComponent }, "App.xcodeproj")
    }

    /// 反映が遅れても、フックの時刻は受け口に届いた時刻で数える（その後に書かれたログ行で待ちが解ける）。
    func testDelayedHookIsJudgedByReceiptTime() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        let gate = DispatchSemaphore(value: 0)
        let blocking = Box(false)
        let entered = Box(false)
        let alive = alive!
        let clock = clock!
        let hub = SessionHub(home: home.home, usageFile: nil, now: { clock.now }, isAlive: {
            if blocking.value {
                entered.mutate { $0 = true }
                gate.wait()
            }
            return alive.value.contains($0)
        })
        await hub.scanInventory()
        await hub.pollTranscripts()
        blocking.mutate { $0 = true }
        let scanning = Task { await hub.scanInventory() }
        try await waitUntil { entered.value }

        let received = clock.now
        hub.enqueueHook(HookPayload(sessionId: sessionId, hookEventName: "Notification", toolName: "Bash",
                                    notificationType: "permission_prompt"))
        // 監視が塞がっている間に時間が過ぎ、その間にログ行が書かれる。
        clock.advance(5_000)
        try append(F.assistant("a1", [["type": "tool_use", "name": "Edit", "input": [:] as [String: Any]]],
                               timestamp: iso(received + 1_000)))
        blocking.mutate { $0 = false }
        gate.signal()
        await scanning.value
        await hub.flushHooks()
        var s = try await required(hub)
        XCTAssertEqual(s.status, .permission)
        XCTAssertEqual(s.attentionSince, received, "要対応の始まりも届いた時刻")

        await hub.pollTranscripts()
        s = try await required(hub)
        XCTAssertEqual(s.status, .working, "届いた後に書かれたログ行で権限待ちが解ける")
    }

    /// 待ち行列が溢れたら、押し出したフックの数を知らせ、押し出した flush の待ち手は起こす。
    func testHookOverflowIsReportedAndFlushIsNotLost() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        let gate = DispatchSemaphore(value: 0)
        let blocking = Box(false)
        let entered = Box(false)
        let alive = alive!
        let clock = clock!
        let hub = SessionHub(home: home.home, usageFile: nil, now: { clock.now }, isAlive: {
            if blocking.value {
                entered.mutate { $0 = true }
                gate.wait()
            }
            return alive.value.contains($0)
        }, hookBufferLimit: 2)
        let events = Box<[MonitorEvent]>([])
        await hub.setSink { e in events.mutate { $0.append(e) } }
        await hub.scanInventory()
        blocking.mutate { $0 = true }
        let scanning = Task { await hub.scanInventory() }
        try await waitUntil { entered.value }

        let prompt = HookPayload(sessionId: sessionId, hookEventName: "UserPromptSubmit")
        // 1 件目は流す側が取り出し、塞がった監視の前で待つ。
        hub.enqueueHook(prompt)
        try await Task.sleep(for: .milliseconds(50))
        let flushed = Box(false)
        let flushing = Task {
            await hub.flushHooks()
            flushed.mutate { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(50))
        hub.enqueueHook(prompt) // [flush, h2]
        hub.enqueueHook(prompt) // flush を押し出す
        try await waitUntil { flushed.value }
        XCTAssertTrue(flushed.value, "押し出された flush の待ち手も戻る")
        XCTAssertEqual(hub.pendingDroppedHookCount, 0)
        hub.enqueueHook(prompt) // h2 を押し出す
        XCTAssertEqual(hub.pendingDroppedHookCount, 1)

        blocking.mutate { $0 = false }
        gate.signal()
        await scanning.value
        // ここで flush を積むと残りの 2 件を押し出すので、流れ切るのを待つ。
        let texts = { events.value.compactMap { if case .feed(let f) = $0 { return f.text } else { return nil } } }
        try await waitUntil { texts().filter { $0 == "指示を受け取りました" }.count == 3 }
        XCTAssertEqual(texts().filter { $0.hasPrefix("フックの反映が追い付かず") }, ["フックの反映が追い付かず 1 件を取りこぼしました"])
        XCTAssertEqual(hub.pendingDroppedHookCount, 0)
        if flushed.value { await flushing.value }
    }

    /// 時刻の無い行は、起動前から動いていたセッションの初回読みでだけ古いとみなす（切り詰め後の読み直しは新着）。
    func testTimelessLinesAreJudgedBySessionDiscovery() async throws {
        func timeless(_ text: String) -> String {
            F.json(["type": "assistant", "uuid": UUID().uuidString,
                    "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
        }
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        try append(timeless("起動前の応答（切り詰めを確かめるため長めにしておく）"))
        let (hub, events) = try await started()
        XCTAssertFalse(feedTexts(events).contains("起動前の応答（切り詰めを確かめるため長めにしておく）"))

        let other = "99999999-2222-3333-4444-555555555555"
        let otherPid: Int32 = 4343
        alive.mutate { $0.insert(otherPid) }
        try home.writeSession(pid: otherPid, sessionId: other, cwd: "/tmp/proj-b")
        try home.appendTranscript(sessionId: other, cwd: "/tmp/proj-b", lines: [timeless("起動後のセッションの応答")])
        await hub.scanInventory()
        await hub.pollTranscripts()
        XCTAssertTrue(feedTexts(events).contains("起動後のセッションの応答"), "起動後に見つけたセッションの行は新着")

        try Data((timeless("切り詰め後") + "\n").utf8).write(to: home.transcriptURL(sessionId: sessionId, cwd: cwd))
        await hub.pollTranscripts()
        XCTAssertTrue(feedTexts(events).contains("切り詰め後"), "切り詰め後に読み直した行は新着")
    }

    /// 届いた後のログ行を先に読み終えてから遅れて反映した権限待ちは、応答が落ち着いても出さない（答え済み）。
    func testLateHookAfterNewerLogIsTreatedAsAnswered() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        let (hub, events) = try await started()
        let received = clock.now
        clock.advance(5_000)
        try append(F.assistant("a1", [["type": "tool_use", "name": "Edit", "input": [:] as [String: Any]]],
                               timestamp: iso(received + 1_000)))
        await hub.pollTranscripts()
        await hub.applyHook(HookPayload(sessionId: sessionId, hookEventName: "Notification", toolName: "Bash",
                                        notificationType: "permission_prompt"), receivedAt: received)
        var s = try await required(hub)
        XCTAssertEqual(s.status, .working)

        try append(F.assistant("a2", [["type": "text", "text": "終わりました"]], timestamp: iso(received + 2_000)))
        await hub.pollTranscripts()
        s = try await required(hub)
        XCTAssertEqual(s.status, .idle, "落ち着いた後に答え済みの権限待ちを戻さない")
        XCTAssertNil(s.attentionSince)
        XCTAssertTrue(feedTexts(events).contains("終わりました"))
    }

    /// 後から反映したフックの受信時刻が古くても、フックの時刻を逆戻りさせない。
    func testHookTimeDoesNotGoBackwards() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        let (hub, _) = try await started()
        let base = clock.now
        clock.advance(10_000)
        await hub.applyHook(HookPayload(sessionId: sessionId, hookEventName: "Stop"), receivedAt: base + 2_000)
        await hub.applyHook(HookPayload(sessionId: sessionId, hookEventName: "Notification", toolName: "Bash",
                                        notificationType: "permission_prompt"), receivedAt: base + 1_000)
        // 最後のフックより前に書かれたツール行では待ちを解かない。
        try append(F.assistant("a1", [["type": "tool_use", "name": "Bash", "input": [:] as [String: Any]]],
                               timestamp: iso(base + 1_500)))
        await hub.pollTranscripts()
        let s = try await required(hub)
        XCTAssertEqual(s.status, .permission)
    }

    /// 受信時刻の順と待ち行列の順は食い違わない（先に時刻を取った方が先に積まれる）。
    func testHookQueueOrderFollowsReceiptTime() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        let gating = Box(false)
        let calls = Box(0)
        let firstInside = DispatchSemaphore(value: 0)
        let secondCalled = DispatchSemaphore(value: 0)
        let clock = clock!
        let alive = alive!
        let hub = SessionHub(home: home.home, usageFile: nil, now: {
            var index = 0
            calls.mutate { $0 += 1; index = $0 }
            let value = clock.now + Double(index)
            guard gating.value else { return value }
            gating.mutate { $0 = false }
            firstInside.signal()
            // 2 つ目が時刻を取りに来られるなら、それが積み終わるまで 1 つ目の積み込みを遅らせる。
            if secondCalled.wait(timeout: .now() + 0.3) == .success { Thread.sleep(forTimeInterval: 0.1) }
            return value
        }, isAlive: { alive.value.contains($0) })
        await hub.scanInventory()
        await hub.pollTranscripts()
        clock.advance(10_000)

        let sessionId = sessionId
        gating.mutate { $0 = true }
        let first = Thread {
            hub.enqueueHook(HookPayload(sessionId: sessionId, hookEventName: "Stop"))
        }
        first.start()
        firstInside.wait()
        let second = Thread {
            secondCalled.signal()
            hub.enqueueHook(HookPayload(sessionId: sessionId, hookEventName: "Notification", toolName: "Bash",
                                        notificationType: "permission_prompt"))
        }
        second.start()
        try await waitUntil { first.isFinished && second.isFinished }
        await hub.flushHooks()
        let s = try await required(hub)
        XCTAssertEqual(s.status, .permission, "後に時刻を取った権限待ちが後に反映される")
    }

    /// 起動後に見つけた --resume のセッションは、初回読みの古いメタ情報（時刻なし）をフィードに積まない。
    func testResumedSessionDoesNotFeedOldMeta() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        let clock = clock!
        let alive = alive!
        // 遡り読みが先に題を埋めると末尾読みの判定を確かめられないので、メタ読み込みは空にする。
        let hub = SessionHub(home: home.home, usageFile: nil, now: { clock.now }, isAlive: { alive.value.contains($0) },
                             metaLoader: { _, _ in (nil, nil) })
        let events = Box<[MonitorEvent]>([])
        await hub.setSink { e in events.mutate { $0.append(e) } }
        await hub.scanInventory()
        await hub.pollTranscripts()

        let other = "99999999-2222-3333-4444-555555555555"
        let otherPid: Int32 = 4343
        let otherCwd = "/tmp/proj-b"
        alive.mutate { $0.insert(otherPid) }
        try home.writeSession(pid: otherPid, sessionId: other, cwd: otherCwd)
        let later = clock.now + 500
        try home.appendTranscript(sessionId: other, cwd: otherCwd, lines: [
            F.json(["type": "ai-title", "aiTitle": "古い題"]),
            F.user("u0", "古い指示"),
            F.assistant("a0", [["type": "text", "text": "古い応答"]]),
            F.json(["type": "last-prompt", "lastPrompt": "古い指示"]),
            F.assistant("a1", [["type": "text", "text": "再開後の応答"]], timestamp: iso(later)),
            F.json(["type": "last-prompt", "lastPrompt": "再開後の指示"]),
        ])
        await hub.scanInventory()
        await hub.pollTranscripts()
        let texts = feedTexts(events)
        XCTAssertFalse(texts.contains("作業内容: 古い題"))
        XCTAssertFalse(texts.contains("古い指示"))
        XCTAssertFalse(texts.contains("古い応答"))
        XCTAssertTrue(texts.contains("再開後の応答"), "起動後に書かれた行は新着")
        XCTAssertTrue(texts.contains("再開後の指示"), "起動後の行に続く時刻の無い行は新着")
        let s = await hub.snapshot().first { $0.sessionId == other }
        XCTAssertEqual(s?.title, "古い題", "フィードに積まなくても状態は更新する")
        XCTAssertEqual(s?.lastPrompt, "再開後の指示")
    }

    /// セッションの分からないフックは、どのルームにも数えず合計にだけ入れる。
    func testDroppedHooksWithoutSessionAreOnlyCountedInTotal() {
        let counter = HookDropCounter()
        counter.add(sessionId: nil)
        counter.add(sessionId: "")
        counter.add(sessionId: "s1")
        XCTAssertEqual(counter.total, 3)
        let taken = counter.take()
        XCTAssertEqual(taken.bySession, ["s1": 1])
        XCTAssertEqual(taken.total, 3)
        XCTAssertEqual(counter.total, 0)
    }

    /// 長ポーリングの呼び手が居なくなったら待ち手を外し、判断は取り直しに渡せるよう取り置く。
    func testCancelledPermissionWaitIsRemoved() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        let (hub, _) = try await started()
        let input = PermissionRequestInput(requestId: "abcde", toolName: "Bash", description: "ls", inputPreview: "ls",
                                           pid: pid, cwd: cwd)
        let waiting = Task { await hub.awaitPermission(input, waitMillis: 60_000) }
        var count = 0
        for _ in 0..<200 where count == 0 {
            count = await hub.waiterCount(input.key)
            if count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        XCTAssertEqual(count, 1)
        waiting.cancel()
        let outcome = await waiting.value
        XCTAssertEqual(outcome, .timeout)
        for _ in 0..<200 where count > 0 {
            count = await hub.waiterCount(input.key)
            if count > 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        XCTAssertEqual(count, 0)
        await hub.decidePermission(key: input.key, decision: .allow)
        let retried = await hub.awaitPermission(input, waitMillis: 1_000)
        XCTAssertEqual(retried, .allow, "待ち手が残っていないので判断は取り置かれ、取り直しに渡る")

        let cancelledEarly = Task { () -> PermissionOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await hub.awaitPermission(input, waitMillis: 60_000)
        }
        let early = await cancelledEarly.value
        XCTAssertEqual(early, .timeout, "取り消し済みなら待ち手を登録しない")
        let left = await hub.waiterCount(input.key)
        XCTAssertEqual(left, 0)
    }

    func testSendMessageFailuresAndDelivery() async throws {
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd)
        let (hub, events) = try await started()
        do {
            try await hub.sendMessage(sessionId: "nope", text: "x")
            XCTFail()
        } catch let failure as HubFailure {
            XCTAssertEqual(failure.code, "not_found")
        }
        do {
            try await hub.sendMessage(sessionId: sessionId, text: "x")
            XCTFail()
        } catch let failure as HubFailure {
            XCTAssertEqual(failure.code, "no_socket")
        }

        // 受信箱ソケットに行区切りの JSON が 1 行届く。
        let socketDir = URL(fileURLWithPath: "/tmp/cdk-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: socketDir) }
        let socketPath = socketDir.appendingPathComponent("in.sock").path
        let inbox = try UnixInbox(path: socketPath)
        try home.writeSession(pid: pid, sessionId: sessionId, cwd: cwd, extra: ["messagingSocketPath": socketPath])
        await hub.scanInventory()
        do { let v = await snap(hub); XCTAssertEqual(v?.canReceive, true) }
        try await hub.sendMessage(sessionId: sessionId, text: "別セッションから")
        let received = try XCTUnwrap(inbox.readLine())
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(received.utf8)) as? [String: Any])
        XCTAssertEqual(o["type"] as? String, "user")
        XCTAssertEqual((o["message"] as? [String: Any])?["content"] as? String, "別セッションから")
        XCTAssertTrue(feedTexts(events).contains("伝言を送信: 別セッションから"))

        alive.mutate { $0.remove(pid) }
        await hub.scanInventory()
        do {
            try await hub.sendMessage(sessionId: sessionId, text: "x")
            XCTFail()
        } catch let failure as HubFailure {
            XCTAssertEqual(failure.code, "not_alive")
        }
    }
}

/// 試験用の受信箱（Unix ソケットで 1 接続だけ受けて 1 行読む）。
final class UnixInbox {
    private let fd: Int32

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
    }

    deinit { close(fd) }

    func readLine() -> String? {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return nil }
        defer { close(client) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
    }
}

/// メタ読み込みを止めておく関所。
final class MetaGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var closed = false
    private var waiters = 0

    func close() { condition.withLock { closed = true } }

    func open() {
        condition.withLock {
            closed = false
            condition.broadcast()
        }
    }

    var waiting: Bool { condition.withLock { waiters > 0 } }

    func pass() {
        condition.withLock {
            waiters += 1
            while closed { condition.wait() }
            waiters -= 1
        }
    }
}
