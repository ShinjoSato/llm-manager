import XCTest
@testable import MonitorKit

/// チャネルの MCP 応答。Claude Code が読む形なので、@modelcontextprotocol/sdk の Server と同じ応答になっているかを見る。
final class ChannelProtocolTests: XCTestCase {
    private func reply(_ line: String) -> [String: Any]? {
        guard case .reply(let text) = ChannelProtocol.handle(line: line) else { return nil }
        XCTAssertFalse(text.contains("\n"), "1 行で返す")
        return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    func testInitialize() throws {
        let r = try XCTUnwrap(reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2"}}}"#))
        XCTAssertEqual(r["id"] as? Int, 1)
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18", "対応している版はそのまま返す")
        let experimental = try XCTUnwrap((result["capabilities"] as? [String: Any])?["experimental"] as? [String: Any])
        XCTAssertEqual(Set(experimental.keys), ["claude/channel", "claude/channel/permission"])
        XCTAssertNil((result["capabilities"] as? [String: Any])?["tools"], "ツールは出さない")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "claude-deck-channel")
        XCTAssertEqual(result["instructions"] as? String, ChannelProtocol.instructions)

        let unknown = try XCTUnwrap(reply(#"{"jsonrpc":"2.0","id":"x","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        XCTAssertEqual(unknown["id"] as? String, "x")
        XCTAssertEqual((unknown["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25", "知らない版には最新で答える")
    }

    func testPingAndUnknownMethods() throws {
        XCTAssertEqual((try XCTUnwrap(reply(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#))["result"] as? [String: Any])?.count, 0)
        for method in ["tools/list", "prompts/list", "resources/list", "tools/call"] {
            let r = try XCTUnwrap(reply(#"{"jsonrpc":"2.0","id":3,"method":"\#(method)"}"#))
            XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? Int, -32601, method)
            XCTAssertEqual((r["error"] as? [String: Any])?["message"] as? String, "Method not found")
        }
    }

    func testIgnoresNotificationsAndBrokenLines() {
        for line in ["", "garbage", "[]", #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                     #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
                     #"{"jsonrpc":"2.0","id":1,"result":{}}"#,
                     #"{"jsonrpc":"2.0","method":"notifications/claude/channel/permission_request","params":{"request_id":"abcde","tool_name":"Bash"}}"#] {
            guard case .ignore = ChannelProtocol.handle(line: line) else { return XCTFail("無視するはず: \(line)") }
        }
    }

    func testPermissionRequestAndVerdict() throws {
        let line = #"{"jsonrpc":"2.0","method":"notifications/claude/channel/permission_request","params":{"request_id":"abcde","tool_name":"Bash","description":"ls を実行する","input_preview":"{\"command\":\"ls\"}"}}"# + "\r"
        guard case .permissionRequest(let request) = ChannelProtocol.handle(line: line) else { return XCTFail() }
        XCTAssertEqual(request, ChannelPermissionRequest(requestId: "abcde", toolName: "Bash", description: "ls を実行する",
                                                         inputPreview: #"{"command":"ls"}"#))
        let verdict = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(ChannelProtocol.permissionNotification(requestId: "abcde", decision: .deny).utf8)) as? [String: Any])
        XCTAssertEqual(verdict["method"] as? String, "notifications/claude/channel/permission")
        XCTAssertNil(verdict["id"], "通知なので id は付けない")
        XCTAssertEqual(verdict["params"] as? [String: String], ["request_id": "abcde", "behavior": "deny"])

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: ChannelRelay.requestBody(request, pid: 4321, cwd: "/p")) as? [String: Any])
        // 受け口が読める形（PermissionRelay.parseRequest）で渡す。
        XCTAssertEqual(PermissionRelay.parseRequest(body),
                       PermissionRequestInput(requestId: "abcde", toolName: "Bash", description: "ls を実行する",
                                              inputPreview: #"{"command":"ls"}"#, pid: 4321, cwd: "/p"))
    }
}

final class ChannelRelayTests: XCTestCase {
    func testBaseURL() {
        XCTAssertEqual(ChannelRelay.baseURL([:]), "http://127.0.0.1:8766")
        XCTAssertEqual(ChannelRelay.baseURL(["MONITOR_URL": "http://127.0.0.1:9000/"]), "http://127.0.0.1:8766", "旧名は読まない")
        XCTAssertEqual(ChannelRelay.baseURL(["CLAUDE_DECK_URL": "http://127.0.0.1:9100//", "MONITOR_URL": "http://127.0.0.1:9000"]),
                       "http://127.0.0.1:9100")
        XCTAssertEqual(ChannelRelay.baseURL(["CLAUDE_DECK_URL": ""]), "http://127.0.0.1:8766")
        XCTAssertEqual(ChannelRelay.baseURL(["CLAUDE_DECK_URL": "http://localhost:9100"]), "http://localhost:9100")
        XCTAssertEqual(ChannelRelay.baseURL(["CLAUDE_DECK_URL": "http://[::1]:9100/"]), "http://[::1]:9100")
        XCTAssertEqual(ChannelRelay.baseURL(["CLAUDE_DECK_URL": "HTTP://LOCALHOST:9100"]), "HTTP://LOCALHOST:9100")
    }

    func testBaseURLRejectsNonLoopback() {
        for raw in ["http://example.com:8766", "https://127.0.0.1:8766", "http://192.168.0.2:8766", "http://127.0.0.1.example.com",
                    "http://user@127.0.0.1:8766", "http://127.0.0.1:8766/other", "http://127.0.0.1:8766?x=1", "file:///tmp/x",
                    "127.0.0.1:8766", "not a url"] {
            var logged: [String] = []
            XCTAssertEqual(ChannelRelay.baseURL(["CLAUDE_DECK_URL": raw]) { logged.append($0) }, "http://127.0.0.1:8766", raw)
            XCTAssertEqual(logged.count, 1, "既定に戻した理由を残す: \(raw)")
        }
    }

    func testSessionStaysLocal() {
        let session = ChannelRelay.makeSession()
        defer { session.invalidateAndCancel() }
        XCTAssertEqual(session.configuration.connectionProxyDictionary?.isEmpty, true, "システムのプロキシを経由しない")
        XCTAssertGreaterThanOrEqual(session.configuration.httpMaximumConnectionsPerHost, 32)
        XCTAssertTrue(session.delegate is ChannelRelay.NoRedirect)
    }

    func testClassify() {
        func c(_ status: Int, _ body: String) -> ChannelAskResult { ChannelRelay.classify(status: status, body: Data(body.utf8)).0 }
        XCTAssertEqual(c(200, #"{"ok":true,"outcome":"allow"}"#), .allow)
        XCTAssertEqual(c(200, #"{"ok":true,"outcome":"deny"}"#), .deny)
        XCTAssertEqual(c(200, #"{"ok":true,"outcome":"dropped"}"#), .dropped)
        XCTAssertEqual(c(200, #"{"ok":true,"outcome":"timeout"}"#), .timeout)
        XCTAssertEqual(c(200, "broken"), .unreachable, "読めない応答で待たずに取り直し続けない")
        XCTAssertEqual(c(200, #"{"ok":true}"#), .unreachable)
        XCTAssertEqual(c(200, #"{"ok":true,"outcome":"later"}"#), .unreachable)
        XCTAssertNotNil(ChannelRelay.classify(status: 200, body: Data("broken".utf8)).1)
        XCTAssertEqual(c(400, ""), .dropped, "形が悪い申請は取り直しても同じ")
        XCTAssertEqual(c(403, ""), .dropped)
        XCTAssertEqual(c(503, ""), .unreachable)
        XCTAssertNotNil(ChannelRelay.classify(status: 400, body: Data()).1, "受け付けられない理由はログに残す")
    }

    private func relay(_ answers: [ChannelAskResult], clock: Box<TimeInterval>, sleeps: Box<Int>, logs: Box<[String]>) -> ChannelRelay {
        let queue = Box(answers)
        return ChannelRelay(
            ask: {
                var next = ChannelAskResult.unreachable
                queue.mutate { if !$0.isEmpty { next = $0.removeFirst() } }
                return next
            },
            sleep: { seconds in clock.mutate { $0 += seconds }; sleeps.mutate { $0 += 1 } },
            now: { clock.value },
            log: { message in logs.mutate { $0.append(message) } })
    }

    func testRetriesUntilDecision() async {
        let clock = Box<TimeInterval>(0), sleeps = Box(0), logs = Box<[String]>([])
        let r = relay([.timeout, .unreachable, .timeout, .allow], clock: clock, sleeps: sleeps, logs: logs)
        let decision = await r.run(toolName: "Bash", baseURL: "http://x")
        XCTAssertEqual(decision, .allow)
        XCTAssertEqual(sleeps.value, 1, "timeout はすぐ取り直し、繋がらない時だけ待つ")
        XCTAssertEqual(logs.value.count, 1)
    }

    func testDroppedStopsWithoutDecision() async {
        let clock = Box<TimeInterval>(0), sleeps = Box(0), logs = Box<[String]>([])
        let decision = await relay([.timeout, .dropped, .allow], clock: clock, sleeps: sleeps, logs: logs).run(toolName: "Bash", baseURL: "http://x")
        XCTAssertNil(decision, "端末側で答えられた分は返さない")
    }

    func testGivesUpAfterThirtyMinutes() async {
        let clock = Box<TimeInterval>(0), sleeps = Box(0), logs = Box<[String]>([])
        let decision = await relay([], clock: clock, sleeps: sleeps, logs: logs).run(toolName: "Bash", baseURL: "http://x")
        XCTAssertNil(decision)
        XCTAssertEqual(clock.value, ChannelRelay.giveUpAfter, "30 分で諦める")
        XCTAssertEqual(sleeps.value, Int(ChannelRelay.giveUpAfter / ChannelRelay.retryDelay))
        XCTAssertLessThan(logs.value.count, 40, "繋がらない間のログは間引く")
        XCTAssertTrue(logs.value.last?.contains("諦めます") == true)
    }
}

/// 実行ファイルを stdin/stdout のパイプで繋ぎ、偽の受け口（OS 割り当てポート）と通して確かめる。本物の claude は起動しない。
final class ChannelExecutableTests: XCTestCase {
    private var executable: URL {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        return products.appendingPathComponent("claude-deck-channel")
    }

    private func listen(_ server: LoopbackHTTPServer) async throws -> Int {
        let states = Box<[LoopbackServerState]>([])
        server.start(port: 0) { state in states.mutate { $0.append(state) } }
        for _ in 0..<300 {
            if case .listening(let port)? = states.value.last { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "listen", code: 1)
    }

    func testDoesNotFollowRedirect() async throws {
        let followed = Box(false)
        let server = LoopbackHTTPServer { request in
            if request.path == "/elsewhere" {
                followed.mutate { $0 = true }
                return .json(200, ["ok": true, "outcome": "allow"])
            }
            return HTTPResponse(status: 307, headers: [("Location", "/elsewhere")])
        }
        defer { server.stop() }
        let port = try await listen(server)
        let session = ChannelRelay.makeSession()
        defer { session.invalidateAndCancel() }
        let ask = ChannelRelay.httpAsk(baseURL: "http://127.0.0.1:\(port)", body: Data("{}".utf8), session: session) { _ in }
        let outcome = await ask()
        XCTAssertNotEqual(outcome, .allow)
        XCTAssertFalse(followed.value, "リダイレクト先には預けない")
    }

    func testRelaysPermissionThroughFakeReceiver() async throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return XCTFail("実行ファイルが無い: \(executable.path)")
        }
        let received = Box<[[String: Any]]>([])
        let server = LoopbackHTTPServer { request in
            guard request.method == "POST", request.path == "/api/channel/permissions" else { return .json(404, [:]) }
            let body = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            var count = 0
            received.mutate { $0.append(body); count = $0.count }
            // 1 回目は判断が出ないまま一巡したことにして、取り直しも通す。
            return .json(200, ["ok": true, "outcome": count == 1 ? "timeout" : "allow"])
        }
        defer { server.stop() }
        let port = try await listen(server)
        XCTAssertNotEqual(port, 8766)

        let process = Process()
        process.executableURL = executable
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_DECK_URL"] = "http://127.0.0.1:\(port)"
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let lines = Box<[String]>([])
        let pending = Box(Data())
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            pending.mutate { buffer in
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                    buffer = Data(buffer[(nl + 1)...])
                    lines.mutate { $0.append(line) }
                }
            }
        }
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        func send(_ line: String) throws { try stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }
        func waitFor(_ predicate: ([String]) -> Bool) async throws {
            for _ in 0..<1000 where !predicate(lines.value) { try await Task.sleep(for: .milliseconds(10)) }
        }

        try send(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}"#)
        try send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        try await waitFor { !$0.isEmpty }
        let initialized = try XCTUnwrap(lines.value.first.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        XCTAssertEqual(initialized["id"] as? Int, 0)
        XCTAssertNotNil((initialized["result"] as? [String: Any])?["capabilities"])

        try send(#"{"jsonrpc":"2.0","method":"notifications/claude/channel/permission_request","params":{"request_id":"qwert","tool_name":"Bash","description":"ls","input_preview":"{\"command\":\"ls\"}"}}"#)
        try await waitFor { $0.count >= 2 }
        let verdict = try XCTUnwrap(lines.value.dropFirst().first.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        XCTAssertEqual(verdict["method"] as? String, "notifications/claude/channel/permission")
        XCTAssertEqual(verdict["params"] as? [String: String], ["request_id": "qwert", "behavior": "allow"])

        XCTAssertEqual(received.value.count, 2, "timeout の後に取り直す")
        let body = try XCTUnwrap(received.value.first)
        XCTAssertEqual(body["requestId"] as? String, "qwert")
        XCTAssertEqual(body["toolName"] as? String, "Bash")
        XCTAssertEqual(body["pid"] as? Int, Int(getpid()), "親 PID（ここではテストのプロセス）でセッションを引く")
        XCTAssertNotNil(PermissionRelay.parseRequest(body), "アプリの受け口が読める形")

        // stdin を閉じれば（Claude Code が終われば）抜ける。
        try stdin.fileHandleForWriting.close()
        for _ in 0..<500 where process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationStatus, 0)
        stdout.fileHandleForReading.readabilityHandler = nil
    }
}
