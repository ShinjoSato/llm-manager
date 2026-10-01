import XCTest
@testable import MonitorKit

/// 実際の monitor に繋ぐ確認。`MONITOR_TEST_URL=http://127.0.0.1:8799 swift test` の時だけ走る。
final class MonitorLiveTests: XCTestCase {
    private func liveClient() throws -> MonitorClient {
        guard let raw = ProcessInfo.processInfo.environment["MONITOR_TEST_URL"], let url = URL(string: raw) else {
            throw XCTSkip("MONITOR_TEST_URL が未設定")
        }
        return MonitorClient(configuration: MonitorConfiguration(baseURL: url))
    }

    func testStreamDeliversSnapshots() async throws {
        let client = try liveClient()
        var connected = false
        var gotSessions = false
        var gotFeedBatch = false
        var gotPermissions = false
        let deadline = Date().addingTimeInterval(10)
        for await event in client.events() {
            switch event {
            case .connected: connected = true
            case .event(.sessions): gotSessions = true
            case .event(.feedBatch): gotFeedBatch = true
            case .event(.permissions): gotPermissions = true
            case .decodingFailed(let name, let message): XCTFail("\(name): \(message)")
            default: break
            }
            if (connected && gotSessions && gotFeedBatch && gotPermissions) || Date() > deadline { break }
        }
        XCTAssertTrue(connected)
        XCTAssertTrue(gotSessions)
        XCTAssertTrue(gotFeedBatch)
        XCTAssertTrue(gotPermissions, "ループバック接続には permissions が届く")
    }

    /// 疑似の権限確認（`MONITOR_TEST_PERMISSION_KEY` の鍵）が SSE に載り、拒否を返せることを見る。
    @MainActor
    func testPermissionRoundTrip() async throws {
        let client = try liveClient()
        guard let key = ProcessInfo.processInfo.environment["MONITOR_TEST_PERMISSION_KEY"] else {
            throw XCTSkip("MONITOR_TEST_PERMISSION_KEY が未設定")
        }
        let store = MonitorStore(client: client)
        store.start()
        defer { store.stop() }
        let deadline = Date().addingTimeInterval(10)
        while store.permissions.first(where: { $0.key == key }) == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let pending = try XCTUnwrap(store.permissions.first { $0.key == key })
        try await store.decide(pending, .deny)
        XCTAssertFalse(store.permissions.contains { $0.key == key })
    }

    func testRestEndpoints() async throws {
        let client = try liveClient()
        let healthy = try await client.health()
        XCTAssertTrue(healthy)
        _ = try await client.fetchSessions()
        _ = try await client.fetchFeed()
        _ = try await client.fetchUsage()
        _ = try await client.fetchPermissions()

        // 書き込み系は存在しない宛先に送り、content-type が通って 404 まで届くことを見る（実セッションには送らない）。
        do {
            try await client.decidePermission(key: "0:zzzzz", decision: .deny)
            XCTFail("404 のはず")
        } catch MonitorError.http(let status, _, _) {
            XCTAssertEqual(status, 404)
        }
        do {
            try await client.sendMessage(sessionId: "00000000-0000-0000-0000-000000000000", text: "test")
            XCTFail("404 のはず")
        } catch MonitorError.http(let status, let code, _) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(code, "not_found")
        }
    }
}
