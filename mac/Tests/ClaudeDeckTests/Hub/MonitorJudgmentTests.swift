import XCTest
@testable import MonitorKit

final class AttentionTests: XCTestCase {
    func testNeedsAttention() {
        XCTAssertTrue(Attention.needsAttention(.permission))
        XCTAssertTrue(Attention.needsAttention(.waiting))
        XCTAssertTrue(Attention.needsAttention(.error))
        XCTAssertFalse(Attention.needsAttention(.working))
        XCTAssertFalse(Attention.needsAttention(.idle))
        XCTAssertFalse(Attention.needsAttention(nil))
    }

    func testPermissionDetail() {
        func d(_ t: String?, _ m: String?, _ ct: String?, _ ca: String?) -> String? {
            Attention.permissionDetail(toolName: t, message: m, currentTool: ct, currentAction: ca)
        }
        XCTAssertEqual(d("Bash", nil, "Bash", "テストを実行"), "Bash: テストを実行", "同じツールなら説明を添える")
        XCTAssertEqual(d("Bash", nil, "Bash", nil), "Bash")
        XCTAssertEqual(d("Edit", nil, "Bash", "テストを実行"), "Edit", "別のツールの説明は添えない")
        XCTAssertEqual(d(nil, "Claude needs your permission", "Bash", "テストを実行"), "Claude needs your permission")
        XCTAssertEqual(d(nil, "Claude needs your permission to use Bash", "Bash", "テストを実行"),
                       "Claude needs your permission to use Bash: テストを実行")
        XCTAssertEqual(d(nil, "Claude needs your permission to use Edit", "Bash", "テストを実行"),
                       "Claude needs your permission to use Edit")
        XCTAssertEqual(d(nil, "Claude needs your permission", nil, nil), "Claude needs your permission")
        XCTAssertEqual(d("Write", "Claude needs your permission", nil, nil), "Write", "ツール名を通知文より優先する")
        XCTAssertNil(d(nil, nil, "Bash", "テストを実行"))
        XCTAssertNil(d(nil, nil, nil, nil))
        XCTAssertEqual(d("", "通知文", nil, nil), "通知文", "空文字のツール名は無いものとして扱う")
    }

    func testToolFromMessage() {
        XCTAssertEqual(Attention.toolFromMessage("Claude needs your permission to use Bash"), "Bash")
        XCTAssertEqual(Attention.toolFromMessage("Claude needs your permission to use mcp__ai-manager__add_pin"), "mcp__ai-manager__add_pin")
        XCTAssertNil(Attention.toolFromMessage("Claude needs your permission"))
        XCTAssertNil(Attention.toolFromMessage(nil))
    }

    func testAttentionSince() {
        func n(_ p: SessionStatus?, _ ps: Double?, _ next: SessionStatus?, _ now: Double) -> Double? {
            Attention.nextAttentionSince(prevStatus: p, prevSince: ps, nextStatus: next, now: now)
        }
        XCTAssertEqual(n(.working, nil, .permission, 1000), 1000)
        XCTAssertEqual(n(nil, nil, .waiting, 1000), 1000)
        XCTAssertEqual(n(.permission, 1000, .waiting, 5000), 1000, "要対応どうしの移り変わりは引き継ぐ")
        XCTAssertEqual(n(.permission, 1000, .permission, 5000), 1000)
        XCTAssertNil(n(.permission, 1000, .working, 5000))
        XCTAssertNil(n(.waiting, 1000, .idle, 5000))
        XCTAssertEqual(n(.permission, nil, .permission, 5000), 5000)
        XCTAssertEqual(n(.working, 1000, .error, 9000), 9000)
    }

    func testHeldStatus() {
        XCTAssertEqual(Attention.heldStatus(.permission, hookAt: 1000, lastActivityAt: 900), .permission)
        XCTAssertEqual(Attention.heldStatus(.permission, hookAt: 1000, lastActivityAt: 1000), .permission)
        XCTAssertNil(Attention.heldStatus(.permission, hookAt: 1000, lastActivityAt: 2000))
        XCTAssertNil(Attention.heldStatus(nil, hookAt: 1000, lastActivityAt: 0))
    }

    /// 権限待ち #1 に答えてツールが動いた後、次の権限待ち #2 がツール行の読み取りより先に届く順。
    func testNextPermissionAfterAnswerStartsOver() {
        var hookStatus: SessionStatus?
        var hookAt: Double = 0
        var since: Double?
        func hook(_ now: Double, _ lastActivityAt: Double) {
            since = Attention.nextAttentionSince(prevStatus: Attention.heldStatus(hookStatus, hookAt: hookAt, lastActivityAt: lastActivityAt),
                                                 prevSince: since, nextStatus: .permission, now: now)
            hookStatus = .permission
            hookAt = now
        }
        hook(1000, 500)
        hook(3000, 2000)
        XCTAssertEqual(since, 3000, "答えた後の次の権限待ちは引き継がない")
        hook(4000, 2000)
        XCTAssertEqual(since, 3000, "動きが無いまま届き直せば引き継ぐ")
    }
}

final class UsageReaderTests: XCTestCase {
    private func parse(_ json: String) -> UsageSnapshot? { UsageReader.parse(Data(json.utf8)) }

    func testParsesWindows() {
        let full = parse(#"{"fetchedAt":1750000000000,"fiveHour":{"usedPercentage":42.7,"resetsAt":1750007325000},"sevenDay":{"usedPercentage":61.2,"resetsAt":null}}"#)
        XCTAssertEqual(full, UsageSnapshot(fetchedAt: 1750000000000, fiveHour: UsageWindow(usedPercentage: 42.7, resetsAt: 1750007325000),
                                           sevenDay: UsageWindow(usedPercentage: 61.2, resetsAt: nil)))
        XCTAssertEqual(parse(#"{"fetchedAt":1,"sevenDay":{"usedPercentage":30,"resetsAt":99}}"#)?.sevenDay, UsageWindow(usedPercentage: 30, resetsAt: 99))
        XCTAssertEqual(parse(#"{"fetchedAt":1,"fiveHour":{"usedPercentage":8}}"#)?.fiveHour, UsageWindow(usedPercentage: 8, resetsAt: nil))
        XCTAssertNil(parse(#"{"fetchedAt":1,"fiveHour":{"usedPercentage":8}}"#)?.sevenDay)
    }

    func testRejectsBrokenInput() {
        XCTAssertNil(parse("not json"))
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("[]"))
        XCTAssertNil(parse("{}"))
        XCTAssertNil(parse(#"{"fiveHour":{"usedPercentage":8}}"#), "取得時刻が無ければ nil")
        XCTAssertNil(parse(#"{"fetchedAt":1,"fiveHour":null,"sevenDay":null}"#))
        XCTAssertNil(parse(#"{"fetchedAt":1,"fiveHour":{"usedPercentage":"42"},"sevenDay":{"usedPercentage":5}}"#)?.fiveHour)
        XCTAssertNil(parse(#"{"fetchedAt":true,"fiveHour":{"usedPercentage":8}}"#), "真偽値は数値として読まない")
    }

    func testReadsFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("claude-usage.json")
        XCTAssertNil(UsageReader.read(url))
        XCTAssertNil(UsageReader.read(nil))
        try Data(#"{"fetchedAt":1,"fiveHour":{"usedPercentage":42.7}}"#.utf8).write(to: url)
        XCTAssertEqual(UsageReader.read(url)?.fiveHour?.usedPercentage, 42.7)
        try Data("{ half written".utf8).write(to: url)
        XCTAssertNil(UsageReader.read(url))
    }
}

final class LoopbackGuardTests: XCTestCase {
    let port = 8766

    func testSplitHostPort() {
        XCTAssertTrue(LoopbackGuard.splitHostPort("localhost:8766") == ("localhost", "8766"))
        XCTAssertTrue(LoopbackGuard.splitHostPort("[::1]:8766") == ("[::1]", "8766"))
        XCTAssertTrue(LoopbackGuard.splitHostPort("[::1:8766") == ("[::1:8766", ""))
        XCTAssertTrue(LoopbackGuard.splitHostPort("[::1]x8766") == ("[::1]x8766", ""))
        XCTAssertTrue(LoopbackGuard.splitHostPort("localhost") == ("localhost", ""))
    }

    func testHost() {
        XCTAssertTrue(LoopbackGuard.isAllowedHost("localhost:8766", port: port))
        XCTAssertTrue(LoopbackGuard.isAllowedHost("127.0.0.1:8766", port: port))
        XCTAssertTrue(LoopbackGuard.isAllowedHost("[::1]:8766", port: port))
        XCTAssertTrue(LoopbackGuard.isAllowedHost("LocalHost:8766", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedHost(nil, port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedHost("", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedHost("evil.example.com:8766", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedHost("localhost.evil.com:8766", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedHost("evil-localhost:8766", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedHost("localhost:9999", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedHost("localhost", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedHost("localhost.:8766", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedHost("::1:8766", port: port))
        XCTAssertTrue(LoopbackGuard.isAllowedHost("localhost", port: 80))
        XCTAssertFalse(LoopbackGuard.isAllowedHost("evil.com", port: 80))
        XCTAssertTrue(LoopbackGuard.isAllowedHost("localhost:49152", port: 49152), "OS が割り当てた実ポートで判定できる")
        XCTAssertFalse(LoopbackGuard.isAllowedHost("192.168.0.11:8766", port: port))
    }

    func testOrigin() {
        XCTAssertTrue(LoopbackGuard.isAllowedOrigin("http://localhost:8766", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedOrigin("http://localhost:5174", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedOrigin("http://localhost", port: port))
        XCTAssertTrue(LoopbackGuard.isAllowedOrigin("http://localhost", port: 80))
        XCTAssertFalse(LoopbackGuard.isAllowedOrigin("https://localhost:8766", port: port))
        XCTAssertTrue(LoopbackGuard.isAllowedOrigin("http://127.0.0.1:8766", port: port))
        XCTAssertTrue(LoopbackGuard.isAllowedOrigin("http://[::1]:8766", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedOrigin("https://evil.example.com", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedOrigin("http://localhost@evil.com", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedOrigin("http://localhost.evil.com", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedOrigin("null", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedOrigin("", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedOrigin("chrome-extension://abcdef", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedOrigin("file:///etc/passwd", port: port))
        XCTAssertFalse(LoopbackGuard.isAllowedOrigin("http://192.168.0.11:8766", port: port))
    }

    func testLoopbackAddress() {
        XCTAssertTrue(LoopbackGuard.isLoopbackAddress("127.0.0.1"))
        XCTAssertTrue(LoopbackGuard.isLoopbackAddress("127.1.2.3"))
        XCTAssertTrue(LoopbackGuard.isLoopbackAddress("::1"))
        XCTAssertTrue(LoopbackGuard.isLoopbackAddress("::ffff:127.0.0.1"))
        XCTAssertFalse(LoopbackGuard.isLoopbackAddress("192.168.0.11"))
        XCTAssertFalse(LoopbackGuard.isLoopbackAddress("::ffff:192.168.0.11"))
        XCTAssertFalse(LoopbackGuard.isLoopbackAddress("203.0.113.9"))
        XCTAssertFalse(LoopbackGuard.isLoopbackAddress("1270.0.0.1"))
        XCTAssertFalse(LoopbackGuard.isLoopbackAddress(nil))
        XCTAssertFalse(LoopbackGuard.isLoopbackAddress(""))
    }
}
