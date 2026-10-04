import XCTest
@testable import MonitorKit

// 移植元: 旧 monitor（削除済み）の test/permissions.test.ts と同じ観点。承認が手元以外に漏れると任意のコマンドを許可できてしまう。
final class PermissionRelayTests: XCTestCase {
    let raw: [String: Any] = ["requestId": "abcde", "toolName": "Bash", "description": "ls を実行する",
                              "inputPreview": #"{"command":"ls"}"#, "pid": 1234, "cwd": "/Users/me/project"]
    var input: PermissionRequestInput { PermissionRelay.parseRequest(raw)! }

    private func with(_ changes: [String: Any]) -> [String: Any] { raw.merging(changes) { _, new in new } }

    func testDecisionValues() {
        XCTAssertEqual(PermissionDecision(rawValue: "allow"), .allow)
        XCTAssertEqual(PermissionDecision(rawValue: "deny"), .deny)
        XCTAssertNil(PermissionDecision(rawValue: "always"))
        XCTAssertNil(PermissionDecision(rawValue: "ALLOW"))
        XCTAssertNil(PermissionDecision(rawValue: ""))
    }

    func testParseRequest() {
        XCTAssertEqual(input, PermissionRequestInput(requestId: "abcde", toolName: "Bash", description: "ls を実行する",
                                                      inputPreview: #"{"command":"ls"}"#, pid: 1234, cwd: "/Users/me/project"))
        XCTAssertEqual(PermissionRelay.parseRequest(["requestId": "abcde", "toolName": "Bash"])?.description, "")
        XCTAssertNil(PermissionRelay.parseRequest(["requestId": "abcde", "toolName": "Bash"])?.pid)
        XCTAssertNil(PermissionRelay.parseRequest(with(["toolName": "  "])))
        XCTAssertNil(PermissionRelay.parseRequest(with(["requestId": ""])))
        XCTAssertNil(PermissionRelay.parseRequest(with(["requestId": "../x"])))
        XCTAssertNil(PermissionRelay.parseRequest(with(["requestId": String(repeating: "a", count: 65)])))
        XCTAssertNil(PermissionRelay.parseRequest(nil))
        XCTAssertNil(PermissionRelay.parseRequest(with(["pid": -1]))?.pid)
        XCTAssertNil(PermissionRelay.parseRequest(with(["pid": true]))?.pid, "真偽値は pid にしない")
        XCTAssertEqual(PermissionRelay.parseRequest(with(["inputPreview": String(repeating: "x", count: 5000)]))?.inputPreview.count, 4001)
    }

    func testMatchSessionByPidOnly() {
        func raw(_ id: String, _ pid: Int32, _ cwd: String, _ alive: Bool) -> RawSession {
            RawSession(pid: pid, sessionId: id, cwd: cwd, startedAt: 0, alive: alive)
        }
        let sessions = [raw("s1", 1234, "/a", true), raw("s2", 5678, "/b", true), raw("s3", 4321, "/b", true), raw("s4", 9999, "/c", false)]
        XCTAssertEqual(PermissionRelay.matchSession(pid: 1234, sessions: sessions), "s1")
        XCTAssertNil(PermissionRelay.matchSession(pid: 9999, sessions: sessions), "終了済みは引かない")
        XCTAssertNil(PermissionRelay.matchSession(pid: nil, sessions: sessions))
        XCTAssertNil(PermissionRelay.matchSession(pid: 1, sessions: sessions), "知らない PID は cwd に落ちない")
    }

    func testPendingKey() {
        XCTAssertEqual(PermissionRelay.pendingKey(pid: 1234, requestId: "abcde"), "1234-abcde")
        XCTAssertEqual(PermissionRelay.pendingKey(pid: nil, requestId: "abcde"), "x-abcde")
        XCTAssertNotEqual(PermissionRelay.pendingKey(pid: 1, requestId: "abcde"), PermissionRelay.pendingKey(pid: 2, requestId: "abcde"))
    }

    func testRegisterDecideAndWait() {
        let reg = PermissionRegistry()
        XCTAssertTrue(reg.register(input, sessionId: "s1", project: "project", now: 1_000).created)
        XCTAssertEqual(reg.list(), [PendingPermission(key: "1234-abcde", requestId: "abcde", sessionId: "s1", project: "project",
                                                     toolName: "Bash", description: "ls を実行する",
                                                     inputPreview: #"{"command":"ls"}"#, askedAt: 1_000)])
        XCTAssertFalse(reg.register(input, sessionId: nil, project: nil, now: 2_000).created)
        XCTAssertEqual(reg.list().first?.sessionId, "s1", "取り直しでセッションは消えない")
        XCTAssertFalse(reg.register(input, sessionId: "s1", project: "project", now: 2_000).changed)
        XCTAssertNil(reg.decide("1234-zzzzz", .allow, now: 2_000))

        var got: [PermissionOutcome] = []
        XCTAssertNotNil(reg.addWaiter("1234-abcde") { got.append($0) })
        XCTAssertEqual(reg.decide("1234-abcde", .allow, now: 2_000)?.toolName, "Bash")
        XCTAssertEqual(got, [.allow], "待っていた側に判断が返る")
        XCTAssertEqual(reg.list(), [])
        XCTAssertNil(reg.addWaiter("1234-abcde") { _ in }, "知らない鍵は待てない（dropped）")

        // 判断が出なければ timeout。保留は残したままなので、チャネルが取り直せる。
        _ = reg.register(input, sessionId: "s1", project: "project", now: 3_000)
        var timedOut: [PermissionOutcome] = []
        let id = reg.addWaiter("1234-abcde") { timedOut.append($0) }!
        reg.expireWaiter("1234-abcde", id: id)
        XCTAssertEqual(timedOut, [.timeout])
        XCTAssertEqual(reg.count, 1)
    }

    func testLateLinkAndTwins() {
        let late = PermissionRegistry()
        XCTAssertFalse(late.register(input, sessionId: nil, project: "p", now: 1_000).linked)
        let linked = late.register(input, sessionId: "s1", project: "p", now: 2_000)
        XCTAssertTrue(linked.changed)
        XCTAssertTrue(linked.linked)
        XCTAssertFalse(late.register(input, sessionId: "s1", project: "p", now: 3_000).linked)

        let twins = PermissionRegistry()
        var a = input; a.pid = 1111
        var b = input; b.pid = 2222
        _ = twins.register(a, sessionId: "sA", project: "A", now: 1_000)
        _ = twins.register(b, sessionId: "sB", project: "B", now: 1_000)
        XCTAssertEqual(twins.count, 2)
        var gotB: [PermissionOutcome] = []
        _ = twins.addWaiter(b.key) { gotB.append($0) }
        _ = twins.decide(a.key, .allow, now: 1_000)
        XCTAssertEqual(twins.count, 1)
        XCTAssertEqual(gotB, [], "相手の待ち手には判断が配られない")
        XCTAssertEqual(twins.list().first?.sessionId, "sB")
    }

    func testDecisionPutAsideBetweenPolls() {
        let gap = PermissionRegistry()
        _ = gap.register(input, sessionId: "s1", project: "project", now: 1_000)
        XCTAssertEqual(gap.decide(input.key, .deny, now: 1_000)?.toolName, "Bash")
        XCTAssertEqual(gap.takeDecision(input.key, toolName: "Bash", inputPreview: input.inputPreview, now: 1_100), .deny)
        XCTAssertNil(gap.takeDecision(input.key, toolName: "Bash", inputPreview: input.inputPreview, now: 1_100), "一度きり")
        _ = gap.register(input, sessionId: "s1", project: "project", now: 2_000)
        _ = gap.decide(input.key, .allow, now: 2_000)
        XCTAssertNil(gap.takeDecision(input.key, toolName: "Bash", inputPreview: input.inputPreview, now: 2_000 + PermissionRelay.decidedTTL))

        let reused = PermissionRegistry()
        _ = reused.register(input, sessionId: "s1", project: "project", now: 1_000)
        _ = reused.decide(input.key, .allow, now: 1_000)
        XCTAssertNil(reused.takeDecision(input.key, toolName: "Bash", inputPreview: #"{"command":"rm -rf /"}"#, now: 1_100),
                     "中身が違えば取り置きは渡さない")

        let delivered = PermissionRegistry()
        _ = delivered.register(input, sessionId: "s1", project: "project", now: 1_000)
        var got: [PermissionOutcome] = []
        _ = delivered.addWaiter(input.key) { got.append($0) }
        _ = delivered.decide(input.key, .allow, now: 1_000)
        XCTAssertEqual(got, [.allow])
        XCTAssertNil(delivered.takeDecision(input.key, toolName: "Bash", inputPreview: input.inputPreview, now: 1_100), "配れた分は取り置かない")
    }

    func testSwapAndOverflowAndDropAndSweep() {
        let swapped = PermissionRegistry()
        _ = swapped.register(input, sessionId: "s1", project: "project", now: 1_000)
        var changedInput = input
        changedInput.toolName = "Write"
        changedInput.inputPreview = "z"
        XCTAssertTrue(swapped.register(changedInput, sessionId: "s1", project: "project", now: 2_000).changed)
        XCTAssertEqual(swapped.list().first?.toolName, "Write")
        XCTAssertEqual(swapped.list().first?.askedAt, 2_000)

        let flood = PermissionRegistry()
        for i in 0..<(PermissionRelay.maxPending + 5) {
            var x = input
            x.requestId = "r\(i)"
            _ = flood.register(x, sessionId: nil, project: nil, now: 1_000 + Double(i))
        }
        XCTAssertEqual(flood.count, PermissionRelay.maxPending)
        XCTAssertEqual(flood.list().first?.requestId, "r5")
        var over = input
        over.requestId = "over"
        XCTAssertEqual(flood.register(over, sessionId: nil, project: nil, now: 9_999).evicted.first?.requestId, "r5")

        let reg = PermissionRegistry()
        _ = reg.register(input, sessionId: "s1", project: "p", now: 3_000)
        XCTAssertEqual(reg.dropResolved(sessionId: "s1", lastActivityAt: 3_000).count, 0, "預かる前の活動では落ちない")
        XCTAssertEqual(reg.dropResolved(sessionId: "s2", lastActivityAt: 9_000).count, 0)
        var got: [PermissionOutcome] = []
        _ = reg.addWaiter(input.key) { got.append($0) }
        XCTAssertEqual(reg.dropResolved(sessionId: "s1", lastActivityAt: 3_001).first?.requestId, "abcde")
        XCTAssertEqual(got, [.dropped])
        XCTAssertEqual(reg.count, 0)

        let stale = PermissionRegistry()
        _ = stale.register(input, sessionId: nil, project: nil, now: 10_000)
        XCTAssertEqual(stale.sweep(now: 10_000 + PermissionRelay.pendingTTL - 1).count, 0)
        XCTAssertEqual(stale.sweep(now: 10_000 + PermissionRelay.pendingTTL).first?.requestId, "abcde")

        let old = PermissionRegistry()
        _ = old.register(input, sessionId: nil, project: nil, now: 0)
        _ = old.register(input, sessionId: nil, project: nil, now: PermissionRelay.pendingMaxAge)
        XCTAssertEqual(old.sweep(now: PermissionRelay.pendingMaxAge).first?.requestId, "abcde", "古すぎる保留は消える")

        let many = PermissionRegistry()
        var bb = input; bb.requestId = "bbbbb"
        var aa = input; aa.requestId = "aaaaa"
        _ = many.register(bb, sessionId: nil, project: nil, now: 200)
        _ = many.register(aa, sessionId: nil, project: nil, now: 100)
        XCTAssertEqual(many.list().map(\.requestId), ["aaaaa", "bbbbb"])
    }
}
