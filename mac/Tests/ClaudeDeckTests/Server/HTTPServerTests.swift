import XCTest
@testable import MonitorKit

/// アプリ内サーバー。:8766 は使わず、OS に割り当てさせた別ポートで立てる。
final class HTTPServerTests: XCTestCase {
    typealias F = FakeClaudeHome
    let sessionId = "11111111-2222-3333-4444-555555555555"
    var home: FakeClaudeHome!
    var hub: SessionHub!
    var server: HTTPServer!
    var port = 0

    override func setUp() async throws {
        home = try FakeClaudeHome()
        try home.writeSession(pid: getpid(), sessionId: sessionId, cwd: "/tmp/proj-a")
        hub = SessionHub(home: home.home, usageFile: nil)
        await hub.scanInventory()
        let hub = hub!
        server = HTTPServer { request in await HookServerRoutes.handle(request, hub: hub) }
        port = try await startListening(server, port: 0)
        XCTAssertNotEqual(port, 8766)
    }

    override func tearDown() {
        server?.stop()
        home?.remove()
    }

    private func request(_ method: String, _ path: String, body: String? = nil, contentType: String? = "application/json",
                         headers: [String: String] = [:]) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = method
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body.map { Data($0.utf8) }
        req.timeoutInterval = 10
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return ((response as! HTTPURLResponse).statusCode, json)
    }

    func testHealthAndNotFound() async throws {
        let (status, json) = try await request("GET", "/api/health", contentType: nil)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["sessions"] as? Int, 1)
        let (missing, _) = try await request("GET", "/api/sessions", contentType: nil)
        XCTAssertEqual(missing, 404, "外から叩かれない口は出さない")
        let (wrongMethod, _) = try await request("GET", "/hook", contentType: nil)
        XCTAssertEqual(wrongMethod, 404)
    }

    func testHookIsAppliedAndValidated() async throws {
        let body = F.json(["session_id": sessionId, "hook_event_name": "Notification", "notification_type": "permission_prompt",
                           "tool_name": "Bash", "cwd": "/tmp/proj-a"])
        let (status, json) = try await request("POST", "/hook", body: body)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["ok"] as? Bool, true)
        await hub.flushHooks()
        let snapshot = await hub.snapshot().first
        XCTAssertEqual(snapshot?.status, .permission)
        XCTAssertEqual(snapshot?.statusDetail, "Bash")

        let (unknown, _) = try await request("POST", "/hook", body: F.json(["session_id": "nope", "hook_event_name": "Stop"]))
        XCTAssertEqual(unknown, 200, "未知のセッションでもフック側を失敗させない")
        // 末尾が欠けたサロゲート（応答文の切り詰め等）でも本文は読める。
        let (lone, _) = try await request("POST", "/hook", body: #"{"session_id":"nope","hook_event_name":"Stop","last_assistant_message":"\ud83d"}"#)
        XCTAssertEqual(lone, 200)

        let (noType, _) = try await request("POST", "/hook", body: body, contentType: "text/plain")
        XCTAssertEqual(noType, 415, "プリフライトを回避した cross-origin POST を弾く")
        let (broken, _) = try await request("POST", "/hook", body: "{oops")
        XCTAssertEqual(broken, 400)
    }

    func testHostAndOriginAreChecked() async throws {
        let body = F.json(["session_id": sessionId, "hook_event_name": "Stop"])
        let (evilOrigin, _) = try await request("POST", "/hook", body: body, headers: ["Origin": "https://evil.example.com"])
        XCTAssertEqual(evilOrigin, 403)
        let (ownOrigin, _) = try await request("POST", "/hook", body: body, headers: ["Origin": "http://localhost:\(port)"])
        XCTAssertEqual(ownOrigin, 200)

        // URLSession は Host を差し替えられないので、生のソケットで DNS リバインディングの形を送る。
        let raw = try rawRequest("POST /hook HTTP/1.1\r\nHost: evil.example.com:\(port)\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}")
        XCTAssertTrue(raw.hasPrefix("HTTP/1.1 403"), raw)
        let noHost = try rawRequest("GET /api/health HTTP/1.1\r\n\r\n")
        XCTAssertTrue(noHost.hasPrefix("HTTP/1.1 403"), noHost)
        let ok = try rawRequest("GET /api/health HTTP/1.1\r\nHost: localhost:\(port)\r\n\r\n")
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200"), ok)
        XCTAssertTrue(ok.contains("Cache-Control: no-store"))
        XCTAssertFalse(ok.lowercased().contains("access-control-allow-origin"), "CORS は付けない")
    }

    func testOversizedAndChunkedBodiesAreRejected() async throws {
        let big = try rawRequest("POST /hook HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: \(HTTPServer.maxBodyBytes + 1)\r\n\r\n")
        XCTAssertTrue(big.hasPrefix("HTTP/1.1 413"), big)
        let chunked = try rawRequest("POST /hook HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
        XCTAssertTrue(chunked.hasPrefix("HTTP/1.1 501"), chunked)
        let garbage = try rawRequest("NOT HTTP\r\n\r\n")
        XCTAssertTrue(garbage.hasPrefix("HTTP/1.1 400"), garbage)
    }

    func testExpectContinueIsAnswered() async throws {
        let body = F.json(["session_id": sessionId, "hook_event_name": "Stop"])
        let response = try rawRequest("POST /hook HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nExpect: 100-continue\r\n\r\n",
                                      thenAfterContinue: body)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 100 Continue"), response)
        XCTAssertTrue(response.contains("HTTP/1.1 200"), response)

        // 弾く相手には 100 Continue を返さず、本文を送らせない。
        let foreign = try rawRequest("POST /hook HTTP/1.1\r\nHost: evil.example.com:\(port)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nExpect: 100-continue\r\n\r\n")
        XCTAssertTrue(foreign.hasPrefix("HTTP/1.1 403"), foreign)
        XCTAssertFalse(foreign.contains("100 Continue"), foreign)
    }

    /// 監視が初回走査等で塞がっていても、フックにはすぐ答える（curl は 1 秒で諦める）。
    func testHookIsAnsweredWhileHubIsBusy() async throws {
        let gate = DispatchSemaphore(value: 0)
        let blocking = Box(false)
        let busyHub = SessionHub(home: home.home, usageFile: nil, isAlive: { _ in
            if blocking.value { gate.wait() }
            return true
        })
        await busyHub.scanInventory()
        let busyServer = HTTPServer { request in await HookServerRoutes.handle(request, hub: busyHub) }
        defer { busyServer.stop() }
        let busyPort = try await startListening(busyServer, port: 0)
        blocking.mutate { $0 = true }
        let scanning = Task { await busyHub.scanInventory() }
        try await Task.sleep(for: .milliseconds(50))

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(busyPort)/hook")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(F.json(["session_id": sessionId, "hook_event_name": "Notification", "notification_type": "permission_prompt",
                                    "tool_name": "Bash"]).utf8)
        req.timeoutInterval = 1
        let started = Date()
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)

        blocking.mutate { $0 = false }
        gate.signal()
        await scanning.value
        await busyHub.flushHooks()
        let status = await busyHub.snapshot().first?.status
        XCTAssertEqual(status, .permission, "反映は後から届いた順に流れる")
    }

    func testStrictHeaderParsing() async throws {
        let base = "POST /hook HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\n"
        for length in ["+2", "2x", "-2", " ", "0x2", "99999999999999999999999"] {
            let response = try rawRequest(base + "Content-Length: \(length)\r\n\r\n{}")
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 400"), "Content-Length: \(length) → \(response)")
        }
        let spaced = try rawRequest("GET /api/health HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX Bad: 1\r\n\r\n")
        XCTAssertTrue(spaced.hasPrefix("HTTP/1.1 400"), spaced)
        let beforeColon = try rawRequest("GET /api/health HTTP/1.1\r\nHost : 127.0.0.1:\(port)\r\n\r\n")
        XCTAssertTrue(beforeColon.hasPrefix("HTTP/1.1 400"), beforeColon)
        let folded = try rawRequest("GET /api/health HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n folded\r\n\r\n")
        XCTAssertTrue(folded.hasPrefix("HTTP/1.1 400"), folded)
        let ok = try rawRequest(base + "Content-Length:  2 \r\n\r\n{}")
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200"), ok)
    }

    /// 本文ごと 1 回で届いても、ヘッダーの総量の上限は効く。
    func testOversizedHeadersSentAtOnceAreRejected() async throws {
        let filler = String(repeating: "a", count: 1000)
        var head = "GET /api/health HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
        for i in 0..<70 { head += "X-Fill-\(i): \(filler)\r\n" }
        let response = try rawRequest(head + "\r\n")
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 431"), String(response.prefix(80)))
    }

    /// 上限を超えた接続はすぐ閉じる。既存の接続が終われば、また受け付ける。
    func testConnectionLimit() async throws {
        var idle: [Int32] = []
        defer { idle.forEach { close($0) } }
        for _ in 0..<HTTPServer.maxConnections { idle.append(try connectRaw()) }
        for _ in 0..<200 where server.connectionCount < HTTPServer.maxConnections {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(server.connectionCount, HTTPServer.maxConnections)
        let extra = try connectRaw()
        defer { close(extra) }
        var buf = [UInt8](repeating: 0, count: 16)
        let n = read(extra, &buf, buf.count)
        XCTAssertTrue(n == 0 || (n < 0 && errno != EAGAIN), "上限を超えた接続は何も返さずに閉じる（n=\(n) errno=\(errno)）")
        XCTAssertEqual(server.connectionCount, HTTPServer.maxConnections)

        idle.forEach { close($0) }
        idle = []
        for _ in 0..<200 where server.connectionCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(server.connectionCount, 0, "切った接続は数から外す")
        let (status, _) = try await request("GET", "/api/health", contentType: nil)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(server.boundPort, port)
    }

    /// 長ポーリングの途中で相手が切ったら、待ち手を外す（判断は取り直しに渡る）。
    func testLongPollDisconnectRemovesWaiter() async throws {
        let input = PermissionRequestInput(requestId: "abcde", toolName: "Bash", description: "ls", inputPreview: "ls",
                                           pid: getpid(), cwd: "/tmp/proj-a")
        let body = F.json(["requestId": "abcde", "toolName": "Bash", "description": "ls", "inputPreview": "ls",
                           "pid": Int(getpid()), "cwd": "/tmp/proj-a"])
        let fd = try connectRaw()
        let head = "POST /api/channel/permissions HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        _ = head.withCString { write(fd, $0, strlen($0)) }
        var waiters = 0
        for _ in 0..<300 where waiters == 0 {
            waiters = await hub.waiterCount(input.key)
            if waiters == 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(waiters, 1)
        close(fd)
        for _ in 0..<300 where waiters > 0 {
            waiters = await hub.waiterCount(input.key)
            if waiters > 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(waiters, 0, "切れた接続の待ち手を残さない")
        for _ in 0..<200 where server.connectionCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(server.connectionCount, 0)

        await hub.decidePermission(key: input.key, decision: .allow)
        let (status, json) = try await request("POST", "/api/channel/permissions", body: body)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["outcome"] as? String, "allow", "取り直しに判断が渡る")
    }

    /// 送り終えて片側だけ閉じる（shutdown(SHUT_WR)）相手にも応答を返す。
    func testHalfClosedClientStillGetsResponse() async throws {
        let body = F.json(["session_id": sessionId, "hook_event_name": "Notification", "notification_type": "permission_prompt",
                           "tool_name": "Bash"])
        let hook = try rawRequest("POST /hook HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)",
                                  halfClose: true)
        XCTAssertTrue(hook.hasPrefix("HTTP/1.1 200"), hook)
        await hub.flushHooks()
        let status = await hub.snapshot().first?.status
        XCTAssertEqual(status, .permission)

        let health = try rawRequest("GET /api/health HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n", halfClose: true)
        XCTAssertTrue(health.hasPrefix("HTTP/1.1 200"), health)
        XCTAssertTrue(health.contains(#""server":"claude-deck""#), health)

        // 長ポーリングは待ち続けず、取り直しを促す timeout を返して待ち手を残さない。
        let permission = F.json(["requestId": "abcde", "toolName": "Bash", "description": "ls", "inputPreview": "ls",
                                 "pid": Int(getpid()), "cwd": "/tmp/proj-a"])
        let started = Date()
        let poll = try rawRequest("POST /api/channel/permissions HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: \(permission.utf8.count)\r\n\r\n\(permission)",
                                  halfClose: true)
        XCTAssertTrue(poll.hasPrefix("HTTP/1.1 200"), poll)
        XCTAssertTrue(poll.contains(#""outcome":"timeout""#), poll)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let key = PermissionRequestInput(requestId: "abcde", toolName: "Bash", description: "ls", inputPreview: "ls",
                                         pid: getpid(), cwd: "/tmp/proj-a").key
        let waiters = await hub.waiterCount(key)
        XCTAssertEqual(waiters, 0)
    }

    func testChannelPermissionLongPollIsDecidedInApp() async throws {
        let body = F.json(["requestId": "abcde", "toolName": "Bash", "description": "ls", "inputPreview": "ls",
                           "pid": Int(getpid()), "cwd": "/tmp/proj-a"])
        let call = Task { try await request("POST", "/api/channel/permissions", body: body) }
        var pending: [PendingPermission] = []
        for _ in 0..<300 where pending.isEmpty {
            pending = await hub.pendingPermissions()
            if pending.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(pending.first?.sessionId, sessionId)
        await hub.decidePermission(key: pending[0].key, decision: .deny)
        let (status, json) = try await call.value
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["outcome"] as? String, "deny")

        let (bad, _) = try await request("POST", "/api/channel/permissions", body: F.json(["requestId": "../x", "toolName": "Bash"]))
        XCTAssertEqual(bad, 400)
        let (noType, _) = try await request("POST", "/api/channel/permissions", body: body, contentType: nil)
        XCTAssertEqual(noType, 415)
    }

    func testNonLoopbackActorIsHidden() async {
        let request = HTTPRequest(method: "GET", path: "/api/health", headers: ["host": "127.0.0.1:8766"], remoteAddress: "192.168.0.11")
        XCTAssertEqual(HookServerRoutes.rejection(request, port: 8766)?.status, 404, "ループバック以外には存在ごと伏せる")
    }

    /// ポートが使われていれば奪わずに「使用中」を返す。
    func testPortInUseIsReportedWithoutStealing() async throws {
        let second = HTTPServer { _ in .json(200, ["ok": true]) }
        defer { second.stop() }
        do {
            _ = try await startListening(second, port: port)
            XCTFail("同じポートで待ち受けられてしまった")
        } catch ServerTestError.portInUse(let p) {
            XCTAssertEqual(p, port)
        }
        let (status, _) = try await request("GET", "/api/health", contentType: nil)
        XCTAssertEqual(status, 200, "先に待ち受けていた側はそのまま応える")

        // 止めたら、すぐに別の待ち受けが引き継げる（止める側がポートを手放すまで待つ）。
        let taken = port
        server.stop()
        port = try await startListening(second, port: taken)
        XCTAssertEqual(port, taken)
    }

    /// 止めて別の待ち受けで開き直すのを繰り返しても、毎回すぐに取れる。
    func testStopThenListenElsewhereRepeatedly() async throws {
        let taken = port
        let other = HTTPServer { _ in .json(200, ["ok": true]) }
        defer { other.stop() }
        var (current, next) = (server!, other)
        for _ in 0..<50 {
            current.stop()
            let bound = try await startListening(next, port: taken)
            XCTAssertEqual(bound, taken)
            (current, next) = (next, current)
        }
    }

    /// 待ち受け中に同じポートで開き直しても、前の待ち受けが手放すのを待ってから取り直す。
    func testRestartOnSamePortRebinds() async throws {
        let taken = port
        for _ in 0..<5 {
            port = try await startListening(server, port: taken)
            XCTAssertEqual(port, taken)
            let (status, _) = try await request("GET", "/api/health", contentType: nil)
            XCTAssertEqual(status, 200)
        }
    }

    /// Node（libuv）の待ち受けと同じく SO_REUSEADDR だけを付けた別プロセス相当のソケットが居ても奪わない。
    func testForeignReuseAddrListenerIsNotStolen() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(fd, 8), 0)
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let foreignPort = Int(UInt16(bigEndian: actual.sin_port))

        let mine = HTTPServer { _ in .json(200, ["ok": true]) }
        defer { mine.stop() }
        do {
            _ = try await startListening(mine, port: foreignPort)
            XCTFail("他のプロセスの待ち受けと同じポートで待ち受けられてしまった")
        } catch ServerTestError.portInUse(let p) {
            XCTAssertEqual(p, foreignPort)
        }
    }

    /// 0.0.0.0 / [::] で待ち受ける別のプロセス相当のソケット（SO_REUSEADDR の有無とも）が居る時も、127.0.0.1 で奪わない。
    func testWildcardListenersAreNotStolen() async throws {
        for (v6, reuse) in [(false, false), (false, true), (true, false), (true, true)] {
            let (fd, foreignPort) = try wildcardListener(v6: v6, reuseAddr: reuse)
            defer { close(fd) }
            let mine = HTTPServer { _ in .json(200, ["ok": true]) }
            defer { mine.stop() }
            do {
                _ = try await startListening(mine, port: foreignPort)
                XCTFail("\(v6 ? "[::]" : "0.0.0.0") SO_REUSEADDR=\(reuse) と同じポートで待ち受けられてしまった")
            } catch ServerTestError.portInUse(let p) {
                XCTAssertEqual(p, foreignPort)
            }
        }
    }

    private func wildcardListener(v6: Bool, reuseAddr: Bool) throws -> (Int32, Int) {
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        if reuseAddr { setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size)) }
        let bound: Int32
        if v6 {
            var off: Int32 = 0
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_addr = in6addr_any
            bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = INADDR_ANY
            bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = withUnsafePointer(to: &storage) { p in
            v6 ? p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin6_port)) }
               : p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin_port)) }
        }
        return (fd, port)
    }

    /// 繋いだだけのソケット（何も送らない）。
    private func connectRaw() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
        return fd
    }

    /// 生のソケットで 1 リクエスト送り、応答をすべて読む。
    private func rawRequest(_ head: String, thenAfterContinue body: String? = nil, halfClose: Bool = false) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        _ = head.withCString { write(fd, $0, strlen($0)) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        if let body {
            let n = read(fd, &buf, buf.count)
            if n > 0 { out.append(contentsOf: buf[0..<n]) }
            _ = body.withCString { write(fd, $0, strlen($0)) }
        }
        if halfClose { shutdown(fd, SHUT_WR) }
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
