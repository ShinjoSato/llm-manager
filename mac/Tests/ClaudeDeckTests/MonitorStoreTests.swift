import XCTest
@testable import MonitorKit

@MainActor
final class MonitorStoreTests: XCTestCase {
    private func session(_ id: String, pid: Int32, alive: Bool = true) -> SessionSnapshot {
        SessionSnapshot(sessionId: id, pid: pid, alive: alive, name: id, project: "p", cwd: "/", branch: nil, title: nil,
                        lastPrompt: nil, status: .idle, statusSource: .inventory, statusDetail: nil, entrypoint: nil,
                        version: nil, startedAt: 0, lastActivityAt: nil, currentTool: nil, currentSkill: nil,
                        currentAction: nil, tokens: nil, agents: [], canReceive: true, xcodeProject: nil)
    }

    private func feed(_ id: Int) -> FeedItem {
        FeedItem(id: id, sessionId: "s", project: "p", at: 0, kind: .status, text: "\(id)", tool: nil, local: nil)
    }

    private func permission(_ key: String) -> PendingPermission {
        PendingPermission(key: key, requestId: "r", sessionId: "s1", project: "p", toolName: "Bash",
                          description: "", inputPreview: "", askedAt: 0)
    }

    private func makeStore(home: URL? = nil, registryDir: URL? = nil) -> MonitorStore {
        let root = home ?? FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)")
        let config = MonitorConfiguration(claudeHome: ClaudeHome(root: root), usageFile: nil, serverPort: nil)
        return MonitorStore(configuration: config, registry: registryDir.map { ClaudeSessionRegistry(directory: $0) })
    }

    func testSnapshotEventsFillStore() {
        let store = makeStore()
        store.apply(.sessions([session("s1", pid: 1), session("s2", pid: 2)]))
        store.apply(.usage(UsageSnapshot(fetchedAt: 0, fiveHour: UsageWindow(usedPercentage: 10, resetsAt: nil), sevenDay: nil)))
        store.apply(.permissions([permission("k1")]))
        XCTAssertEqual(store.sessions.map(\.sessionId), ["s1", "s2"])
        XCTAssertEqual(store.usage?.fiveHour?.remainingPercentage, 90)
        XCTAssertEqual(store.permissions(forSessionId: "s1").map(\.key), ["k1"])
        XCTAssertNotNil(store.lastEventAt)
    }

    func testFeedBatchReplacesAndFeedAppendsWithoutDuplicates() {
        let store = makeStore()
        store.feedLimit = 3
        store.apply(.feed(feed(100)))
        store.apply(.feedBatch([feed(2), feed(1)]))
        XCTAssertEqual(store.feed.map(\.id), [1, 2])
        store.apply(.feed(feed(3)))
        store.apply(.feed(feed(3)))
        store.apply(.feed(feed(4)))
        XCTAssertEqual(store.feed.map(\.id), [2, 3, 4])
    }

    func testTranscriptIsForwarded() {
        let store = makeStore()
        var received: [String] = []
        store.onTranscript = { received.append($0.sessionId) }
        store.apply(.transcript(TranscriptEvent(sessionId: "s1", items: [])))
        XCTAssertEqual(received, ["s1"])
    }

    func testHostedProcessResolvesViaRegistryFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(registryDir: dir)

        store.registerHostedProcess(pid: 777)
        XCTAssertNil(store.sessionId(forHostedPid: 777), "起動直後はまだレジストリが無い")

        try Data(#"{"pid":777,"sessionId":"s-hosted"}"#.utf8).write(to: dir.appendingPathComponent("777.json"))
        store.apply(.sessions([session("s-hosted", pid: 777), session("s-ext", pid: 888)]))
        XCTAssertEqual(store.sessionId(forHostedPid: 777), "s-hosted")
        XCTAssertEqual(store.session(forHostedPid: 777)?.sessionId, "s-hosted")
        XCTAssertEqual(store.externalSessions.map(\.sessionId), ["s-ext"])

        // /clear で sessionId が替わっても次の sessions で追従する。
        try Data(#"{"pid":777,"sessionId":"s-new"}"#.utf8).write(to: dir.appendingPathComponent("777.json"))
        store.apply(.sessions([session("s-new", pid: 777)]))
        XCTAssertEqual(store.sessionId(forHostedPid: 777), "s-new")

        store.unregisterHostedProcess(pid: 777)
        XCTAssertNil(store.sessionId(forHostedPid: 777))
    }

    func testHostedProcessFallsBackToSnapshotPid() {
        let store = makeStore()
        store.registerHostedProcess(pid: 55)
        store.apply(.sessions([session("dead", pid: 55, alive: false), session("live", pid: 55)]))
        XCTAssertEqual(store.sessionId(forHostedPid: 55), "live")
    }

    /// monitor を起動しなくても、アプリ内の監視だけで一覧・会話・画像・追記が揃う。
    func testInAppMonitorFillsStoreFromClaudeHome() async throws {
        let home = try FakeClaudeHome()
        defer { home.remove() }
        let sessionId = "11111111-2222-3333-4444-555555555555"
        let cwd = "/tmp/proj-a"
        try home.writeSession(pid: getpid(), sessionId: sessionId, cwd: cwd)
        try home.appendTranscript(sessionId: sessionId, cwd: cwd, lines: [
            FakeClaudeHome.user("u1", [["type": "text", "text": "これ見て"], FakeClaudeHome.pngBlock]),
            FakeClaudeHome.assistant("a1", [["type": "text", "text": "はい"]]),
        ])

        let store = makeStore(home: home.root)
        store.setTranscriptSubscription(.all)
        var appended: [TranscriptEvent] = []
        store.onTranscript = { appended.append($0) }
        store.start()
        defer { store.stop() }

        try await waitUntil { store.connection.isConnected && store.session(id: sessionId) != nil }
        XCTAssertEqual(store.serverState, .stopped, "ポート未指定なら待ち受けない")
        XCTAssertEqual(store.connectionEpoch, 1)
        let snapshot = try XCTUnwrap(store.session(id: sessionId))
        XCTAssertEqual(snapshot.project, "proj-a")
        XCTAssertTrue(snapshot.alive)
        XCTAssertTrue(store.feed.contains { $0.text == "セッション検出: proj-a" })

        let transcript = await store.fetchTranscript(sessionId: sessionId)
        XCTAssertEqual(transcript?.items.map(\.id), ["u1:0", "a1:0"])
        XCTAssertEqual(transcript?.items.first?.images.map(\.index), [0])
        let image = await store.imageSource(sessionId, "u1:0", 0)
        XCTAssertEqual(image, FakeClaudeHome.png)
        let missing = await store.fetchTranscript(sessionId: "99999999-0000-0000-0000-000000000000")
        XCTAssertNil(missing)

        try home.appendTranscript(sessionId: sessionId, cwd: cwd, lines: [FakeClaudeHome.user("u2", "次")])
        try await waitUntil { appended.contains { $0.items.map(\.id) == ["u2:0"] } }
        XCTAssertFalse(appended.contains { $0.items.contains { $0.id == "u1:0" } }, "購読前の分は追記として流さない")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("時間内に揃いませんでした") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
