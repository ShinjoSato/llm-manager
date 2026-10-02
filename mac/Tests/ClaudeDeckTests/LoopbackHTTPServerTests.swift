import XCTest
@testable import MonitorKit

/// アプリ内サーバー（移植元: monitor/src/server.ts の外から叩かれる口）。:8766 は使わず、OS に割り当てさせた別ポートで立てる。
final class LoopbackHTTPServerTests: XCTestCase {
    typealias F = FakeClaudeHome
    let sessionId = "11111111-2222-3333-4444-555555555555"
    var home: FakeClaudeHome!
    var hub: SessionHub!
    var server: LoopbackHTTPServer!
    var port = 0

    override func setUp() async throws {
        home = try FakeClaudeHome()
        try home.writeSession(pid: getpid(), sessionId: sessionId, cwd: "/tmp/proj-a")
        hub = SessionHub(home: home.home, usageFile: nil)
        await hub.scanInventory()
        let hub = hub!
        server = LoopbackHTTPServer { request in await MonitorHTTPRoutes.handle(request, hub: hub) }
        port = try await listen(server, port: 0)
        XCTAssertNotEqual(port, 8766)
    }

    override func tearDown() {
        server?.stop()
        home?.remove()
    }

    private func listen(_ server: LoopbackHTTPServer, port: Int) async throws -> Int {
        let states = Box<[LoopbackServerState]>([])
        server.start(port: port) { state in states.mutate { $0.append(state) } }
        for _ in 0..<200 {
            if let last = states.value.last {
                switch last {
                case .listening(let bound): return bound
                case .portInUse(let p): throw ServerTestError.portInUse(p)
                case .failed(let reason): throw ServerTestError.failed(reason)
                default: break
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ServerTestError.failed("timeout")
    }

    enum ServerTestError: Error, Equatable {
        case portInUse(Int)
        case failed(String)
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
        XCTAssertEqual(json["applied"] as? Bool, true)
        let snapshot = await hub.snapshot().first
        XCTAssertEqual(snapshot?.status, .permission)
        XCTAssertEqual(snapshot?.statusDetail, "Bash")

        let (unknown, unknownJSON) = try await request("POST", "/hook", body: F.json(["session_id": "nope", "hook_event_name": "Stop"]))
        XCTAssertEqual(unknown, 200, "未知のセッションでもフック側を失敗させない")
        XCTAssertEqual(unknownJSON["applied"] as? Bool, false)

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
        let big = try rawRequest("POST /hook HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: \(LoopbackHTTPServer.maxBodyBytes + 1)\r\n\r\n")
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
        let hub = hub!
        let response = await MonitorHTTPRoutes.guarded(request, port: 8766) { await MonitorHTTPRoutes.handle($0, hub: hub) }
        XCTAssertEqual(response.status, 404, "ループバック以外には存在ごと伏せる")
    }

    /// ポートが使われていれば奪わずに「使用中」を返す（旧 monitor が動いている時の扱い）。
    func testPortInUseIsReportedWithoutStealing() async throws {
        let second = LoopbackHTTPServer { _ in .json(200, ["ok": true]) }
        defer { second.stop() }
        do {
            _ = try await listen(second, port: port)
            XCTFail("同じポートで待ち受けられてしまった")
        } catch ServerTestError.portInUse(let p) {
            XCTAssertEqual(p, port)
        }
        let (status, _) = try await request("GET", "/api/health", contentType: nil)
        XCTAssertEqual(status, 200, "先に待ち受けていた側はそのまま応える")

        // 空いたら引き継げる。
        let taken = port
        server.stop()
        port = try await listen(second, port: taken)
        XCTAssertEqual(port, taken)
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

        let mine = LoopbackHTTPServer { _ in .json(200, ["ok": true]) }
        defer { mine.stop() }
        do {
            _ = try await listen(mine, port: foreignPort)
            XCTFail("他のプロセスの待ち受けと同じポートで待ち受けられてしまった")
        } catch ServerTestError.portInUse(let p) {
            XCTAssertEqual(p, foreignPort)
        }
    }

    /// 生のソケットで 1 リクエスト送り、応答をすべて読む。
    private func rawRequest(_ head: String, thenAfterContinue body: String? = nil) throws -> String {
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
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
