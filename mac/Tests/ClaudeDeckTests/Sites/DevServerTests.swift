import XCTest
@testable import MonitorKit

final class DevServerRulesTests: XCTestCase {
    // MARK: - 起動条件

    func testReadinessNeedsDevScript() {
        XCTAssertEqual(DevServerRules.readiness(packageJSON: Data(#"{"scripts":{"dev":"next dev"}}"#.utf8)), .ready(script: "next dev"))
        XCTAssertEqual(DevServerRules.readiness(packageJSON: Data(#"{"scripts":{"build":"next build"}}"#.utf8)), .noDevScript)
        XCTAssertEqual(DevServerRules.readiness(packageJSON: Data(#"{"scripts":{"dev":"  "}}"#.utf8)), .noDevScript)
        XCTAssertEqual(DevServerRules.readiness(packageJSON: Data(#"{"name":"x"}"#.utf8)), .noDevScript)
        XCTAssertEqual(DevServerRules.readiness(packageJSON: Data("{".utf8)), .unreadablePackageJson)
        XCTAssertEqual(DevServerRules.readiness(packageJSON: Data("[]".utf8)), .unreadablePackageJson)
        XCTAssertEqual(DevServerRules.readiness(packageJSON: nil), .unreadablePackageJson)
        XCTAssertNil(DevServerReadiness.ready(script: "x").problem)
        XCTAssertNotNil(DevServerReadiness.noDevScript.problem)
    }

    func testReadinessFromFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("devserver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(DevServerRules.readiness(siteRoot: dir.path), .noPackageJson)
        try Data(#"{"scripts":{"dev":"vite"}}"#.utf8).write(to: dir.appendingPathComponent("package.json"))
        XCTAssertEqual(DevServerRules.readiness(siteRoot: dir.path), .ready(script: "vite"))
    }

    func testEnvironmentDropsKeysAndSessionMarks() {
        let env = DevServerRules.environment(base: [
            "PATH": "/usr/bin", "ANTHROPIC_API_KEY": "k", "ANTHROPIC_AUTH_TOKEN": "t", "CLAUDECODE": "1",
            "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_AGENT_SDK_VERSION": "1", "HOME": "/Users/x",
        ])
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertEqual(env["HOME"], "/Users/x")
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_AGENT_SDK_VERSION"] {
            XCTAssertNil(env[key], key)
        }
        XCTAssertEqual(env["BROWSER"], "none")
        XCTAssertTrue(DevServerRules.shellCommand.hasPrefix("unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN;"))
        XCTAssertTrue(DevServerRules.shellCommand.hasSuffix("exec npm run dev"))
    }

    // MARK: - アドレス

    func testFindsAddressInCommonOutputs() {
        XCTAssertEqual(DevServerRules.address(in: "   - Local:        http://localhost:3000")?.absoluteString, "http://localhost:3000/")
        XCTAssertEqual(DevServerRules.address(in: "  ➜  Local:   http://localhost:5173/")?.absoluteString, "http://localhost:5173/")
        XCTAssertEqual(DevServerRules.address(in: "  ➜  Local:   http://localhost:5173/base/")?.absoluteString, "http://localhost:5173/base/")
        XCTAssertEqual(DevServerRules.address(in: "ready - started server on 0.0.0.0:3000, url: http://localhost:3000")?.absoluteString,
                       "http://localhost:3000/")
        XCTAssertEqual(DevServerRules.address(in: "Serving at 127.0.0.1:8080")?.absoluteString, "http://127.0.0.1:8080/")
        XCTAssertEqual(DevServerRules.address(in: "listening on http://[::1]:4321")?.absoluteString, "http://localhost:4321/")
        XCTAssertEqual(DevServerRules.address(in: "\u{1B}[32m- Local:\u{1B}[39m http://localhost:\u{1B}[1m3001\u{1B}[22m")?.absoluteString,
                       "http://localhost:3001/")
    }

    func testIgnoresLanErrorsAndBadPorts() {
        XCTAssertNil(DevServerRules.address(in: "   - Network:      http://192.168.1.5:3000"))
        XCTAssertNil(DevServerRules.address(in: "Error: listen EADDRINUSE: address already in use 127.0.0.1:3000"))
        XCTAssertNil(DevServerRules.address(in: " ⚠ Port 3000 is in use, trying 3001 instead."))
        XCTAssertNil(DevServerRules.address(in: "http://localhost:99999"))
        XCTAssertNil(DevServerRules.address(in: "http://localhost/"))
        XCTAssertNil(DevServerRules.address(in: "see https://nextjs.org/docs"))
    }

    func testLocalAddressCheck() {
        XCTAssertTrue(DevServerRules.isLocalAddress(URL(string: "http://localhost:3000/")))
        XCTAssertTrue(DevServerRules.isLocalAddress(URL(string: "http://127.0.0.1:8080/")))
        XCTAssertFalse(DevServerRules.isLocalAddress(URL(string: "http://example.com:3000/")))
        XCTAssertFalse(DevServerRules.isLocalAddress(URL(string: "http://localhost/")))
        XCTAssertFalse(DevServerRules.isLocalAddress(URL(string: "file:///tmp/x")))
        XCTAssertFalse(DevServerRules.isLocalAddress(nil))
    }

    // MARK: - 失敗の理由

    func testFailureReasons() {
        let quick = DevServerExit(code: 1)
        XCTAssertTrue(DevServerRules.failureReason(exit: DevServerExit(code: 127), log: ["zsh:1: command not found: npm"], foundAddress: false)
            .contains("npm が見つかりません"))
        XCTAssertTrue(DevServerRules.failureReason(exit: quick, log: ["env: node: No such file or directory"], foundAddress: false)
            .contains("node が見つかりません"))
        XCTAssertTrue(DevServerRules.failureReason(exit: quick, log: ["npm error Missing script: \"dev\""], foundAddress: false)
            .contains("dev スクリプト"))
        XCTAssertTrue(DevServerRules.failureReason(exit: quick, log: ["Error: listen EADDRINUSE: address already in use :::3000"],
                                                   foundAddress: false).contains("ポート 3000 は他のプロセス"))
        XCTAssertTrue(DevServerRules.failureReason(exit: quick, log: ["error when starting dev server:", "Error: Port 5173 is already in use"],
                                                   foundAddress: false).contains("ポート 5173"))
        XCTAssertTrue(DevServerRules.failureReason(exit: quick, log: ["boom"], foundAddress: false).contains("すぐ終了しました（終了コード 1）"))
        XCTAssertTrue(DevServerRules.failureReason(exit: DevServerExit(signal: 9), log: [], foundAddress: true).contains("シグナル 9"))
    }

    // MARK: - 出力の末尾

    func testLogSplitsLinesAndKeepsTail() {
        var log = DevServerLog(limit: 3)
        XCTAssertEqual(log.append(Data("a\nb".utf8)), ["a"])
        XCTAssertEqual(log.tail, ["a", "b"])
        XCTAssertEqual(log.append(Data("c\r\nd\ne\n".utf8)), ["bc", "d", "e"])
        XCTAssertEqual(log.lines, ["bc", "d", "e"])
        log.append(Data("50%\r100%\n".utf8))
        XCTAssertEqual(log.lines.last, "100%")
        log.append(Data("tail".utf8))
        XCTAssertEqual(log.finish(), ["tail"])
        XCTAssertEqual(log.lines.count, 3)
    }

    func testLogJoinsSplitMultibyteAndStripsEscapes() {
        var log = DevServerLog()
        let bytes = Array("起動\n".utf8)
        log.append(Data(bytes[0..<2]))
        log.append(Data(bytes[2...]))
        XCTAssertEqual(log.lines, ["起動"])
        log.append(Data("\u{1B}[31mred\u{1B}[0m \u{1B}]0;title\u{07}ok\u{08}\n".utf8))
        XCTAssertEqual(log.lines.last, "red ok")
    }

    // MARK: - 止める手順

    func testStopPlan() {
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(DevServerStopPlan.next(ownsGroup: false, groupAlive: true, termSentAt: nil, killSentAt: nil, now: t0), .finished)
        XCTAssertEqual(DevServerStopPlan.next(ownsGroup: true, groupAlive: false, termSentAt: nil, killSentAt: nil, now: t0), .finished)
        XCTAssertEqual(DevServerStopPlan.next(ownsGroup: true, groupAlive: true, termSentAt: nil, killSentAt: nil, now: t0), .terminate)
        XCTAssertEqual(DevServerStopPlan.next(ownsGroup: true, groupAlive: true, termSentAt: t0, killSentAt: nil,
                                              now: t0.addingTimeInterval(1)), .wait)
        XCTAssertEqual(DevServerStopPlan.next(ownsGroup: true, groupAlive: true, termSentAt: t0, killSentAt: nil,
                                              now: t0.addingTimeInterval(DevServerStopPlan.grace)), .kill)
        let k = t0.addingTimeInterval(3)
        XCTAssertEqual(DevServerStopPlan.next(ownsGroup: true, groupAlive: true, termSentAt: t0, killSentAt: k,
                                              now: k.addingTimeInterval(0.5)), .wait)
        XCTAssertEqual(DevServerStopPlan.next(ownsGroup: true, groupAlive: true, termSentAt: t0, killSentAt: k,
                                              now: k.addingTimeInterval(DevServerStopPlan.killWait)), .finished)
        XCTAssertEqual(DevServerStopPlan.next(ownsGroup: true, groupAlive: false, termSentAt: t0, killSentAt: nil,
                                              now: t0.addingTimeInterval(0.1)), .finished)
    }
}

/// 実際に子を起動して、出力・終了・グループごとの停止を確かめる（npm は使わず sh で代わりを立てる）。
final class DevServerProcessTests: XCTestCase {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var log = DevServerLog()
        private var exits: [DevServerExit] = []

        func add(_ data: Data) { lock.withLock { _ = log.append(data) } }
        func exit(_ value: DevServerExit) { lock.withLock { exits.append(value) } }
        var lines: [String] { lock.withLock { log.lines } }
        var exit: DevServerExit? { lock.withLock { exits.first } }
    }

    private func spawn(_ script: String, collector: Collector) throws -> DevServerProcess {
        try DevServerProcess.spawn(executable: "/bin/sh", arguments: ["-c", script],
                                   environment: DevServerRules.environment(), directory: NSTemporaryDirectory(),
                                   onOutput: { collector.add($0) }, onExit: { collector.exit($0) })
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { usleep(20_000) }
    }

    func testStopsWholeGroupIncludingGrandchildren() async throws {
        let collector = Collector()
        let process = try spawn("sleep 60 & echo \"  - Local: http://localhost:4567\"; wait", collector: collector)
        waitUntil { collector.lines.contains { DevServerRules.address(in: $0) != nil } }
        XCTAssertEqual(collector.lines.compactMap(DevServerRules.address(in:)).first?.port, 4567)
        XCTAssertEqual(getpgid(process.pid), process.pid)
        XCTAssertTrue(DevServerProcess.groupAlive(process.pid))
        await process.stop()
        XCTAssertFalse(DevServerProcess.groupAlive(process.pid))
        // 刈り取り済みなので自分の子としてはもう見えない。
        var status: Int32 = 0
        XCTAssertEqual(waitpid(process.pid, &status, WNOHANG), -1)
    }

    func testKillsWhenTermIsIgnored() async throws {
        let collector = Collector()
        let process = try spawn("trap '' TERM; echo ready; sleep 60 & wait", collector: collector)
        waitUntil { collector.lines.contains("ready") }
        let started = Date()
        await process.stop()
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), DevServerStopPlan.grace - 0.2)
        XCTAssertFalse(DevServerProcess.groupAlive(process.pid))
    }

    func testReportsQuickExit() throws {
        let collector = Collector()
        let process = try spawn("echo boom; exit 3", collector: collector)
        waitUntil { collector.exit != nil }
        XCTAssertEqual(process.exitStatus, DevServerExit(code: 3))
        XCTAssertEqual(collector.exit, DevServerExit(code: 3))
        XCTAssertEqual(collector.lines, ["boom"])
    }

    func testBlockingStopForTermination() throws {
        let collector = Collector()
        let a = try spawn("echo a; sleep 60 & wait", collector: collector)
        let b = try spawn("echo b; sleep 60 & wait", collector: collector)
        waitUntil { collector.lines.count >= 2 }
        DevServerProcess.stopAllBlocking([a, b])
        XCTAssertFalse(DevServerProcess.groupAlive(a.pid))
        XCTAssertFalse(DevServerProcess.groupAlive(b.pid))
    }
}
