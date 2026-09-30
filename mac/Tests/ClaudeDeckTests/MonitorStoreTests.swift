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

    private func makeStore(registryDir: URL? = nil) -> MonitorStore {
        let dir = registryDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)")
        return MonitorStore(client: MonitorClient(configuration: MonitorConfiguration()),
                            registry: ClaudeSessionRegistry(directory: dir))
    }

    func testConnectionLifecycle() {
        let store = makeStore()
        XCTAssertEqual(store.connection, .idle)
        store.apply(.connecting(attempt: 0))
        XCTAssertEqual(store.connection, .connecting(attempt: 0))
        store.apply(.connected)
        XCTAssertTrue(store.connection.isConnected)
        XCTAssertEqual(store.connectionEpoch, 1)
        store.apply(.event(.permissions([permission("k1")])))
        store.apply(.disconnected(reason: "down", retryIn: 1))
        XCTAssertFalse(store.connection.isConnected)
        XCTAssertTrue(store.permissions.isEmpty, "切れている間は答えられないので空にする")
        store.apply(.connected)
        XCTAssertEqual(store.connectionEpoch, 2)
    }

    func testSnapshotEventsFillStore() {
        let store = makeStore()
        store.apply(.event(.sessions([session("s1", pid: 1), session("s2", pid: 2)])))
        store.apply(.event(.usage(UsageSnapshot(fetchedAt: 0, fiveHour: UsageWindow(usedPercentage: 10, resetsAt: nil), sevenDay: nil))))
        store.apply(.event(.permissions([permission("k1")])))
        XCTAssertEqual(store.sessions.map(\.sessionId), ["s1", "s2"])
        XCTAssertEqual(store.usage?.fiveHour?.remainingPercentage, 90)
        XCTAssertEqual(store.permissions(forSessionId: "s1").map(\.key), ["k1"])
        XCTAssertNotNil(store.lastEventAt)
    }

    func testFeedBatchReplacesAndFeedAppendsWithoutDuplicates() {
        let store = makeStore()
        store.feedLimit = 3
        store.apply(.event(.feed(feed(100))))
        store.apply(.event(.feedBatch([feed(2), feed(1)])))
        XCTAssertEqual(store.feed.map(\.id), [1, 2], "再接続時のバッチは手元を置き換える")
        store.apply(.event(.feed(feed(3))))
        store.apply(.event(.feed(feed(3))))
        store.apply(.event(.feed(feed(4))))
        XCTAssertEqual(store.feed.map(\.id), [2, 3, 4])
    }

    func testTranscriptIsForwarded() {
        let store = makeStore()
        var received: [String] = []
        store.onTranscript = { received.append($0.sessionId) }
        store.apply(.event(.transcript(TranscriptEvent(sessionId: "s1", items: []))))
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
        store.apply(.event(.sessions([session("s-hosted", pid: 777), session("s-ext", pid: 888)])))
        XCTAssertEqual(store.sessionId(forHostedPid: 777), "s-hosted")
        XCTAssertEqual(store.session(forHostedPid: 777)?.sessionId, "s-hosted")
        XCTAssertEqual(store.externalSessions.map(\.sessionId), ["s-ext"])

        // /clear で sessionId が替わっても次の sessions で追従する。
        try Data(#"{"pid":777,"sessionId":"s-new"}"#.utf8).write(to: dir.appendingPathComponent("777.json"))
        store.apply(.event(.sessions([session("s-new", pid: 777)])))
        XCTAssertEqual(store.sessionId(forHostedPid: 777), "s-new")

        store.unregisterHostedProcess(pid: 777)
        XCTAssertNil(store.sessionId(forHostedPid: 777))
    }

    func testHostedProcessFallsBackToMonitorPid() {
        let store = makeStore()
        store.registerHostedProcess(pid: 55)
        store.apply(.event(.sessions([session("dead", pid: 55, alive: false), session("live", pid: 55)])))
        XCTAssertEqual(store.sessionId(forHostedPid: 55), "live")
    }
}
