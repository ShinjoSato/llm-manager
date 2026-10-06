import Network
import XCTest
@testable import MonitorKit

/// iPhone 向けの口を TLS で実際に立てて叩く。LAN には立てず、ループバックの OS 割り当てのポートで試す。
@MainActor
final class RemoteServerTests: XCTestCase {
    var dir: URL!
    var control: FakeRemoteControl!
    var transcripts: FakeTranscriptSource!
    var service: RemoteAccessService!
    var port = 0
    var fingerprint = ""

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("remote-server-\(UUID().uuidString)")
        control = FakeRemoteControl()
        transcripts = FakeTranscriptSource()
        service = RemoteAccessService(directory: dir, transcripts: transcripts, control: control, serverName: "test-mac",
                                      throttle: RemoteAuthThrottle(window: 60, maxFailures: 5))
        service.start(address: "127.0.0.1", port: 0)
        for _ in 0..<300 where service.boundPort == nil {
            if case .failed(let reason) = service.state { throw NSError(domain: reason, code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
        port = try XCTUnwrap(service.boundPort)
        XCTAssertNotEqual(port, HookServerRoutes.defaultPort)
        fingerprint = try XCTUnwrap(service.fingerprint)
    }

    override func tearDown() async throws {
        await service?.stopAndWait()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 補助

    private lazy var session = PinnedSession(pin: fingerprint)

    private func request(_ method: String, _ path: String, token: String? = nil, json: Any? = nil, body: Data? = nil,
                         headers: [String: String] = [:], session: PinnedSession? = nil) async throws -> (Int, Data, HTTPURLResponse) {
        var req = URLRequest(url: URL(string: "https://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = method
        req.timeoutInterval = 10
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        if let body { req.httpBody = body }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await (session ?? self.session).session.data(for: req)
        let http = response as! HTTPURLResponse
        return (http.statusCode, data, http)
    }

    private func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func pair(name: String = "test-iphone") async throws -> RemotePairResponse {
        let offer = try XCTUnwrap(service.beginPairing())
        let (status, data, _) = try await request("POST", "/v1/pair", json: ["token": offer.token, "deviceName": name])
        XCTAssertEqual(status, 200, String(data: data, encoding: .utf8) ?? "")
        return try JSONDecoder().decode(RemotePairResponse.self, from: data)
    }

    // MARK: - TLS

    func testPinnedSessionConnectsAndOtherPinsFail() async throws {
        let (status, _, _) = try await request("GET", "/v1/info")
        XCTAssertEqual(status, 401, "TLS は通り、トークンが無いので 401")

        let wrong = PinnedSession(pin: String(repeating: "0", count: 64))
        do {
            _ = try await request("GET", "/v1/info", session: wrong)
            XCTFail("別の指紋では繋がらない")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }

        let plain = URLSession(configuration: .ephemeral)
        do {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/info")!)
            req.timeoutInterval = 5
            let (_, response) = try await plain.data(for: req)
            XCTFail("平文の HTTP は出さない: \(response)")
        } catch {}
    }

    func testNWConnectionWithPinnedVerifyBlock() async throws {
        let paired = try await pair()
        let raw = "GET /v1/info HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(paired.deviceToken)\r\n\r\n"
        let ok = try await RawTLS.exchange(port: port, pin: fingerprint, request: raw)
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200"), ok)
        XCTAssertTrue(ok.contains("\"serverName\":\"test-mac\""))
        do {
            _ = try await RawTLS.exchange(port: port, pin: String(repeating: "f", count: 64), request: raw)
            XCTFail("別の指紋では繋がらない")
        } catch {}
    }

    func testCertificateSurvivesRestart() async throws {
        let paired = try await pair()
        service.stop()
        service.start(address: "127.0.0.1", port: 0)
        for _ in 0..<300 where service.boundPort == nil { try await Task.sleep(for: .milliseconds(10)) }
        port = try XCTUnwrap(service.boundPort)
        XCTAssertEqual(service.fingerprint, fingerprint, "開き直しても同じ証明書（ピン留めが続く）")
        let restarted = RemoteAccessService(directory: dir, transcripts: transcripts, control: control, serverName: "test-mac")
        XCTAssertEqual(restarted.devices.map(\.id), [paired.deviceId], "端末一覧も残る")
    }

    // MARK: - ペアリングと認証

    func testPairingIssuesTokenOnceAndAuthenticates() async throws {
        XCTAssertNil(service.devices.first)
        let offer = try XCTUnwrap(service.beginPairing())
        XCTAssertEqual(offer.host, "127.0.0.1")
        XCTAssertEqual(offer.port, port)
        XCTAssertEqual(offer.fingerprint, fingerprint)
        let (status, data, _) = try await request("POST", "/v1/pair", json: ["token": offer.token, "deviceName": "iPhone 15"])
        XCTAssertEqual(status, 200)
        let paired = try JSONDecoder().decode(RemotePairResponse.self, from: data)
        XCTAssertEqual(paired.serverName, "test-mac")
        XCTAssertEqual(paired.apiVersion, RemoteAPI.version)

        let (again, _, _) = try await request("POST", "/v1/pair", json: ["token": offer.token, "deviceName": "other"])
        XCTAssertEqual(again, 401, "一時トークンは 1 回限り")

        let (info, infoData, _) = try await request("GET", "/v1/info", token: paired.deviceToken)
        XCTAssertEqual(info, 200)
        let decoded = try JSONDecoder().decode(RemoteInfo.self, from: infoData)
        XCTAssertEqual(decoded.device.name, "iPhone 15")
        for _ in 0..<100 where service.devices.isEmpty || service.pairingOffer != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(service.devices.map(\.id), [paired.deviceId])
        XCTAssertNil(service.pairingOffer, "使われた QR は閉じる")
    }

    func testExpiredPairingTokenIsRejected() async throws {
        _ = try XCTUnwrap(service.beginPairing())
        let ticket = service.pairing.startPairing(lifetime: 0.05)
        try await Task.sleep(for: .milliseconds(100))
        let (status, data, _) = try await request("POST", "/v1/pair", json: ["token": ticket.token, "deviceName": "late"])
        XCTAssertEqual(status, 401)
        XCTAssertEqual(object(data)["error"] as? String, "pairing_rejected")
    }

    func testUnauthenticatedInvalidAndRevokedTokensAreRejected() async throws {
        let paired = try await pair()
        let (none, _, noneResponse) = try await request("GET", "/v1/rooms")
        XCTAssertEqual(none, 401)
        XCTAssertEqual(noneResponse.value(forHTTPHeaderField: "WWW-Authenticate"), "Bearer")
        let (bad, _, _) = try await request("GET", "/v1/rooms", token: paired.deviceToken + "x")
        XCTAssertEqual(bad, 401)
        let (good, _, _) = try await request("GET", "/v1/rooms", token: paired.deviceToken)
        XCTAssertEqual(good, 200)
        service.revoke(paired.deviceId)
        let (revoked, _, _) = try await request("GET", "/v1/rooms", token: paired.deviceToken)
        XCTAssertEqual(revoked, 401, "取り消した端末は弾く")
    }

    func testRepeatedFailuresAreThrottled() async throws {
        let paired = try await pair()
        for _ in 0..<5 {
            let (status, _, _) = try await request("GET", "/v1/rooms", token: "wrong")
            XCTAssertEqual(status, 401)
        }
        // 失敗が続いた接続元は、しばらく正しいトークンでも受け付けない（受け入れた時点で切り、TLS の握手もさせない）。
        do {
            let (status, _, _) = try await request("GET", "/v1/rooms", token: paired.deviceToken)
            XCTFail("塞いだ接続元の接続は切る: \(status)")
        } catch {}
        do {
            _ = try await request("POST", "/v1/pair", json: ["token": "x", "deviceName": "y"])
            XCTFail("ペアリングも同じ")
        } catch {}
        // 接続の途中で塞がった時のための検査も残っている。
        XCTAssertEqual(service.throttle.isBlocked("127.0.0.1"), true)
        let routes = RemoteRoutes(pairing: service.pairing, throttle: service.throttle, transcripts: transcripts, events: service.events,
                                  controlRef: RemoteControlRef(control), serverName: "t")
        XCTAssertEqual(routes.rejection(HTTPRequest(method: "GET", path: "/v1/rooms"))?.status, 429)
    }

    /// 1 つの接続元が握れる接続の数には上限があり、未認証の相手だけで口を塞げない。
    func testConnectionsPerAddressAreLimited() async throws {
        let paired = try await pair()
        let queue = DispatchQueue(label: "idle-clients")
        var idle: [NWConnection] = []
        defer { idle.forEach { $0.cancel() } }
        for _ in 0..<RemoteRoutes.maxConnectionsPerAddress {
            let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
            c.start(queue: queue)
            idle.append(c)
        }
        // 何も送らない接続で枠が埋まると、同じ接続元の次の接続は受け入れた時点で切る。
        var refused = false
        for _ in 0..<100 {
            do {
                _ = try await request("GET", "/v1/info", token: paired.deviceToken)
            } catch {
                refused = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(refused, "接続元ごとの上限を超えた接続は切る")
        idle.forEach { $0.cancel() }
        var recovered = false
        for _ in 0..<200 {
            if let (status, _, _) = try? await request("GET", "/v1/info", token: paired.deviceToken), status == 200 {
                recovered = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(recovered, "閉じれば枠は空く")
    }

    /// 閉じる処理で画面のスレッドを待たせず、閉じ終えた後は同じポートで開き直せる。
    func testStopDoesNotBlockAndPortIsReleased() async throws {
        let started = Date()
        service.stop()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(service.state, .stopped)
        await service.stopAndWait()
        let again = port
        service.start(address: "127.0.0.1", port: again)
        for _ in 0..<300 where service.boundPort == nil {
            if case .failed(let reason) = service.state { return XCTFail(reason) }
            if case .portInUse = service.state { return XCTFail("手放し終えてから開く") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.boundPort, again)
    }

    func testLoopbackOnlyRoutesAndBrowsersAreNotExposed() async throws {
        let paired = try await pair()
        let (hook, _, _) = try await request("POST", "/hook", token: paired.deviceToken, json: ["session_id": "x"])
        XCTAssertEqual(hook, 404, "フックの口は LAN に出さない")
        let (channel, _, _) = try await request("POST", "/api/channel/permissions", token: paired.deviceToken, json: [:])
        XCTAssertEqual(channel, 404, "チャネルの口も出さない")
        let (origin, _, _) = try await request("GET", "/v1/rooms", token: paired.deviceToken, headers: ["Origin": "https://evil.example"])
        XCTAssertEqual(origin, 403)
        let (method, _, _) = try await request("DELETE", "/v1/rooms", token: paired.deviceToken)
        XCTAssertEqual(method, 405)
    }

    func testBodyAndHeaderLimits() async throws {
        let paired = try await pair()
        let room = "h:\(UUID().uuidString)"
        let big = Data(repeating: 0x61, count: RemoteRoutes.maxBodyBytes + 1)
        let (status, _, _) = try await request("POST", "/v1/rooms/\(room)/messages", token: paired.deviceToken, body: big,
                                               headers: ["Content-Type": "application/json"])
        XCTAssertEqual(status, 413)
        let (unsupported, _, _) = try await request("POST", "/v1/rooms/\(room)/messages", token: paired.deviceToken,
                                                    body: Data("{\"text\":\"a\"}".utf8), headers: ["Content-Type": "text/plain"])
        XCTAssertEqual(unsupported, 415)
        XCTAssertEqual(control.calls, [], "弾いた要求は mac の操作に届かない")
    }

    // MARK: - API

    func testRoomsTranscriptAndImage() async throws {
        let paired = try await pair()
        control.state = FakeRemoteControl.sampleState()
        let (status, data, _) = try await request("GET", "/v1/rooms", token: paired.deviceToken)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(try JSONDecoder().decode(RemoteState.self, from: data), control.state)

        let sid = FakeTranscriptSource.sessionId
        let (t, tData, _) = try await request("GET", "/v1/sessions/\(sid)/transcript", token: paired.deviceToken)
        XCTAssertEqual(t, 200)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptResponse.self, from: tData).items.map(\.id), ["u1", "a1"])
        let (after, afterData, _) = try await request("GET", "/v1/sessions/\(sid)/transcript?after=u1", token: paired.deviceToken)
        XCTAssertEqual(after, 200)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptResponse.self, from: afterData).items.map(\.id), ["a1"])
        let (missing, _, _) = try await request("GET", "/v1/sessions/99999999-2222-3333-4444-555555555555/transcript", token: paired.deviceToken)
        XCTAssertEqual(missing, 404)

        let (img, imgData, imgResponse) = try await request("GET", "/v1/sessions/\(sid)/items/u1/images/0", token: paired.deviceToken)
        XCTAssertEqual(img, 200)
        XCTAssertEqual(imgData, FakeTranscriptSource.png)
        XCTAssertEqual(imgResponse.value(forHTTPHeaderField: "Content-Type"), "image/png")
        let (noImg, _, _) = try await request("GET", "/v1/sessions/\(sid)/items/u1/images/5", token: paired.deviceToken)
        XCTAssertEqual(noImg, 404)
    }

    func testActionsAreHandedToTheAppWithTheirIdentifiers() async throws {
        let paired = try await pair()
        let room = "h:\(UUID().uuidString)"
        let token = paired.deviceToken
        var (status, _, _) = try await request("POST", "/v1/rooms/\(room)/permission", token: token,
                                               json: ["promptId": "p1", "decision": "allow"])
        XCTAssertEqual(status, 200)
        (status, _, _) = try await request("POST", "/v1/rooms/\(room)/menu", token: token, json: ["menuId": "m1", "choice": 2])
        XCTAssertEqual(status, 200)
        (status, _, _) = try await request("POST", "/v1/rooms/\(room)/menu", token: token,
                                           json: ["menuId": "m1", "cancel": true, "confirmExit": true])
        XCTAssertEqual(status, 200)
        (status, _, _) = try await request("POST", "/v1/rooms/\(room)/menu/tab", token: token, json: ["menuId": "m1", "direction": "next"])
        XCTAssertEqual(status, 200)
        (status, _, _) = try await request("POST", "/v1/rooms/\(room)/menu/dismiss", token: token, json: ["menuId": "u1"])
        XCTAssertEqual(status, 200)
        (status, _, _) = try await request("POST", "/v1/rooms/\(room)/messages", token: token, json: ["text": "続けて"])
        XCTAssertEqual(status, 200)
        (status, _, _) = try await request("POST", "/v1/permissions/decision", token: token, json: ["key": "k1", "decision": "deny"])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(control.calls, [
            "permission \(room) p1 allow",
            "menu \(room) m1 choice=2 cancel=false exit=false",
            "menu \(room) m1 choice=nil cancel=true exit=true",
            "tab \(room) m1 next",
            "dismiss \(room) u1",
            "send \(room) 続けて",
            "decide k1 deny",
        ])

        (status, _, _) = try await request("POST", "/v1/rooms/\(room)/messages", token: token, json: ["text": "  "])
        XCTAssertEqual(status, 400, "空の本文は mac に渡さない")
        (status, _, _) = try await request("POST", "/v1/rooms/not-a-room/messages", token: token, json: ["text": "a"])
        XCTAssertEqual(status, 404)
        (status, _, _) = try await request("POST", "/v1/rooms/\(room)/menu", token: token, json: ["menuId": 1])
        XCTAssertEqual(status, 400)
        XCTAssertEqual(control.calls.count, 7)

        control.result = .failure("changed", "替わった")
        let (conflict, data, _) = try await request("POST", "/v1/rooms/\(room)/menu", token: token, json: ["menuId": "m1", "choice": 0])
        XCTAssertEqual(conflict, 409)
        XCTAssertEqual(try JSONDecoder().decode(RemoteActionResult.self, from: data), .failure("changed", "替わった"))
    }

    /// Channels の許可 / 拒否は画面と同じ `MonitorStore.decide` を通り、待っているチャネルへ答えが返る。
    func testChannelDecisionGoesThroughMonitorStore() async throws {
        let config = MonitorConfiguration(claudeHome: ClaudeHome(root: dir.appendingPathComponent("claude")), usageFile: nil, serverPort: nil)
        let store = MonitorStore(configuration: config)
        control.decideHandler = { key, decision in await store.remoteDecide(key: key, decision: decision) }
        let hub = store.hub
        let input = PermissionRequestInput(requestId: "abcde", toolName: "Bash", description: "ls", inputPreview: "ls", pid: 4242, cwd: "/tmp")
        let waiting = Task { await hub.awaitPermission(input, waitMillis: 10_000) }
        for _ in 0..<200 where await hub.pendingPermissions().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        store.apply(.permissions(await hub.pendingPermissions()))
        let key = try XCTUnwrap(store.permissions.first?.key)

        let paired = try await pair()
        let (status, _, _) = try await request("POST", "/v1/permissions/decision", token: paired.deviceToken,
                                               json: ["key": key, "decision": "allow"])
        XCTAssertEqual(status, 200)
        let outcome = await waiting.value
        XCTAssertEqual(outcome.rawValue, "allow")
        XCTAssertTrue(store.permissions.isEmpty, "答えた確認は消える")
        let (again, againData, _) = try await request("POST", "/v1/permissions/decision", token: paired.deviceToken,
                                                      json: ["key": key, "decision": "allow"])
        XCTAssertEqual(again, 409, "もう待っていない確認には答えない")
        XCTAssertEqual(object(againData)["code"] as? String, "gone")
    }

    // MARK: - ストリーム

    func testEventStreamSendsStateChangesAndTranscripts() async throws {
        let paired = try await pair()
        control.state = FakeRemoteControl.sampleState()
        let sid = FakeTranscriptSource.sessionId
        var req = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/v1/events?transcripts=\(sid)")!)
        req.setValue("Bearer \(paired.deviceToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        let (bytes, response) = try await session.session.bytes(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream; charset=utf-8")
        var events = SSEReader(bytes.lines.makeAsyncIterator())

        let first = try await events.next()
        XCTAssertEqual(first?.name, "state")
        XCTAssertEqual(try first.map { try JSONDecoder().decode(RemoteState.self, from: Data($0.data.utf8)) }, control.state)
        for _ in 0..<200 where service.connections[paired.deviceId] != 1 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(service.connections, [paired.deviceId: 1], "接続中の端末が分かる")

        control.state.rooms[0].status = .working
        let second = try await events.next()
        XCTAssertEqual(second?.name, "state")
        XCTAssertEqual(try second.map { try JSONDecoder().decode(RemoteState.self, from: Data($0.data.utf8)) }?.rooms.first?.status, .working)

        for _ in 0..<200 where await transcripts.subscriberCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let subscription = await transcripts.lastSubscription
        XCTAssertEqual(subscription, .sessions([sid]))
        await transcripts.emit(TranscriptEvent(sessionId: sid, items: [FakeTranscriptSource.item("a2", .assistant, "done")]))
        let third = try await events.next()
        XCTAssertEqual(third?.name, "transcript")
        XCTAssertEqual(try third.map { try JSONDecoder().decode(TranscriptEvent.self, from: Data($0.data.utf8)) }?.items.map(\.id), ["a2"])

        service.revoke(paired.deviceId)
        let end = try await events.next()
        XCTAssertNil(end, "取り消した端末のストリームは切る")
        for _ in 0..<200 where await transcripts.subscriberCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        let remaining = await transcripts.subscriberCount
        XCTAssertEqual(remaining, 0, "切れたら会話の購読も外す")
        XCTAssertEqual(service.connections, [:])
    }

    func testHubSendsStateOnlyOnChangeAndPingsOtherwise() async throws {
        let hub = RemoteEventHub(controlRef: RemoteControlRef(control), transcripts: transcripts,
                                 pollInterval: .seconds(3600), heartbeatInterval: 0)
        guard case .opened(let stream) = hub.open(deviceId: "d", transcripts: .none) else { return XCTFail() }
        var chunks = stream.chunks.makeAsyncIterator()
        let first = await chunks.next().map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(first?.hasPrefix("event: state\ndata: {"), true)
        hub.tick()
        let ping = await chunks.next().map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(ping, ": ping\n\n", "変わっていなければ状態は送らず生存確認だけ")
        control.state.monitoring = false
        hub.tick()
        let changed = await chunks.next().map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(changed?.contains("\"monitoring\":false"), true)
        hub.closeAll()
        let end = await chunks.next()
        XCTAssertNil(end)
    }

    /// 端末あたりの上限に達したら、その端末の最も古いストリームを閉じて新しいものを受ける（黙って切れた分で 429 にしない）。
    func testStreamsPerDeviceReplaceTheOldest() async throws {
        let paired = try await pair()
        var open: [URLSession.AsyncBytes] = []
        for _ in 0..<RemoteEventHub.maxStreamsPerDevice {
            var req = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/v1/events")!)
            req.setValue("Bearer \(paired.deviceToken)", forHTTPHeaderField: "Authorization")
            // 閉じられないまま待ち続けて試験が止まらないように。
            req.timeoutInterval = 5
            let (bytes, response) = try await session.session.bytes(for: req)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            open.append(bytes)
            // 開いた順を確かにする。
            for _ in 0..<200 where service.events.streamCount < open.count { try await Task.sleep(for: .milliseconds(10)) }
        }
        var oldest = SSEReader(open[0].lines.makeAsyncIterator())
        let first = try await oldest.next()
        XCTAssertEqual(first?.name, "state")

        var req = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/v1/events")!)
        req.setValue("Bearer \(paired.deviceToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        let (newest, response) = try await session.session.bytes(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "上限でも新しいストリームは受ける")
        let end = try await oldest.next()
        XCTAssertNil(end, "最も古いストリームを閉じる")
        XCTAssertEqual(service.events.streamCount, RemoteEventHub.maxStreamsPerDevice)
        await service.stopAndWait()
        XCTAssertEqual(service.state, .stopped)
        _ = (open, newest)
    }

    @MainActor
    func testHubEvictsOldestPerDeviceAndRefusesRevokedDevices() async throws {
        let revoked = RevokedSet()
        let hub = RemoteEventHub(controlRef: RemoteControlRef(control), transcripts: transcripts, pollInterval: .seconds(3600),
                                 isDeviceActive: { !revoked.contains($0) })
        var streams: [HTTPBodyStream] = []
        for _ in 0..<RemoteEventHub.maxStreamsPerDevice {
            guard case .opened(let s) = hub.open(deviceId: "a", transcripts: .none) else { return XCTFail() }
            streams.append(s)
        }
        guard case .opened = hub.open(deviceId: "b", transcripts: .none) else { return XCTFail("別の端末は別の枠") }
        guard case .opened = hub.open(deviceId: "a", transcripts: .none) else { return XCTFail("上限でも入れ替えて受ける") }
        XCTAssertEqual(hub.connections, ["a": RemoteEventHub.maxStreamsPerDevice, "b": 1])
        var oldest = streams[0].chunks.makeAsyncIterator()
        _ = await oldest.next()  // 開いた時の state
        let ended = await oldest.next()
        XCTAssertNil(ended, "入れ替えられた最も古いストリームは終わる")
        var second = streams[1].chunks.makeAsyncIterator()
        let alive = await second.next()
        XCTAssertNotNil(alive, "他は残る")

        // 認証の後、開くまでの間に取り消された端末には開かない。
        revoked.insert("b")
        guard case .revoked = hub.open(deviceId: "b", transcripts: .none) else { return XCTFail("取り消し済みの端末には開かない") }
        hub.closeAll()
        XCTAssertEqual(hub.streamCount, 0)
    }
}

// MARK: - 試験用の部品

final class RevokedSet: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    func insert(_ id: String) { lock.withLock { _ = ids.insert(id) } }
    func contains(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
}

@MainActor
final class FakeRemoteControl: RemoteControl {
    var state = RemoteState(rooms: [], usage: nil, monitoring: true)
    var calls: [String] = []
    var result = RemoteActionResult.success("ok")
    var decideHandler: ((String, PermissionDecision) async -> RemoteActionResult)?

    static func sampleState() -> RemoteState {
        let send = RemoteSendState(mode: .input, disabledReason: nil)
        let room = RemoteRoom(id: "h:\(UUID().uuidString)", kind: .hosted, phase: .attention, name: "mirio", branch: "develop",
                              status: .waiting, line: "plan を確認", activityAt: 1, sessionId: FakeTranscriptSource.sessionId,
                              cwd: "/tmp/mirio", ended: nil, session: nil, permissions: [], terminalPermission: nil,
                              menu: RemoteMenu(MenuPrompt(context: [], question: "Proceed?", options: [.init(number: 1, label: "Yes")], cursor: 0),
                                               generation: 0),
                              unreadableMenu: nil, busy: false, send: send)
        return RemoteState(rooms: [room], usage: nil, monitoring: true)
    }

    func remoteState() -> RemoteState { state }

    func remoteDecide(key: String, decision: PermissionDecision) async -> RemoteActionResult {
        if let decideHandler { return await decideHandler(key, decision) }
        calls.append("decide \(key) \(decision.rawValue)")
        return result
    }

    func remoteAnswerTerminalPermission(roomId: String, promptId: String, decision: PermissionDecision) async -> RemoteActionResult {
        calls.append("permission \(roomId) \(promptId) \(decision.rawValue)")
        return result
    }

    func remoteAnswerMenu(roomId: String, request: RemoteMenuAnswerRequest) async -> RemoteActionResult {
        calls.append("menu \(roomId) \(request.menuId) choice=\(request.choice.map(String.init) ?? "nil") cancel=\(request.cancel ?? false) exit=\(request.confirmExit ?? false)")
        return result
    }

    func remoteMoveMenuTab(roomId: String, request: RemoteMenuTabRequest) async -> RemoteActionResult {
        calls.append("tab \(roomId) \(request.menuId) \(request.direction.rawValue)")
        return result
    }

    func remoteDismissMenu(roomId: String, request: RemoteMenuDismissRequest) async -> RemoteActionResult {
        calls.append("dismiss \(roomId) \(request.menuId)")
        return result
    }

    func remoteSendMessage(roomId: String, text: String) async -> RemoteActionResult {
        calls.append("send \(roomId) \(text)")
        return result
    }
}

actor FakeTranscriptSource: RemoteTranscriptSource {
    static let sessionId = "11111111-2222-3333-4444-555555555555"
    static let png = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])

    private var subscribers: [Int: @Sendable (TranscriptEvent) -> Void] = [:]
    private var seq = 0
    private(set) var lastSubscription: TranscriptSubscription?

    static func item(_ id: String, _ kind: TranscriptItemKind, _ text: String, images: [TranscriptImage] = []) -> TranscriptItem {
        TranscriptItem(id: id, kind: kind, at: 1, text: text, tool: nil, parentId: nil, images: images)
    }

    var subscriberCount: Int { subscribers.count }

    func remoteTranscript(sessionId: String, after: String?) async -> TranscriptResponse? {
        guard sessionId == Self.sessionId else { return nil }
        let all = [Self.item("u1", .user, "見て", images: [TranscriptImage(index: 0, mediaType: "image/png")]),
                   Self.item("a1", .assistant, "はい")]
        guard let after, let i = all.firstIndex(where: { $0.id == after }) else {
            return TranscriptResponse(sessionId: sessionId, items: all, reset: after != nil)
        }
        return TranscriptResponse(sessionId: sessionId, items: Array(all[(i + 1)...]), reset: false)
    }

    func remoteImage(sessionId: String, itemId: String, index: Int) async -> TranscriptImageData? {
        guard sessionId == Self.sessionId, itemId == "u1", index == 0 else { return nil }
        return TranscriptImageData(mediaType: "image/png", data: Self.png)
    }

    func remoteSubscribe(_ subscription: TranscriptSubscription, _ fn: @escaping @Sendable (TranscriptEvent) -> Void) async -> Int? {
        seq += 1
        subscribers[seq] = fn
        lastSubscription = subscription
        return seq
    }

    func remoteUnsubscribe(_ id: Int) async {
        subscribers[id] = nil
    }

    func emit(_ event: TranscriptEvent) {
        for fn in subscribers.values { fn(event) }
    }
}

/// 指紋でピン留めする URLSession（iPhone アプリと同じやり方）。
final class PinnedSession: NSObject, URLSessionDelegate, @unchecked Sendable {
    let pin: String
    private(set) var session: URLSession!

    init(pin: String) {
        self.pin = pin
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, RemotePinning.matches(trust, pinned: pin) else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// NWConnection（TLS・指紋のピン留め）で生の HTTP を 1 往復する。
final class RawTLS: @unchecked Sendable {
    struct Failed: Error {}

    private let queue: DispatchQueue
    private let connection: NWConnection
    private let request: String
    private var received = Data()
    private var continuation: CheckedContinuation<String, Error>?

    private init(port: Int, pin: String, request: String) {
        let queue = DispatchQueue(label: "raw-tls")
        self.queue = queue
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            complete(RemotePinning.matches(sec_trust_copy_ref(trust).takeRetainedValue(), pinned: pin))
        }, queue)
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: NWParameters(tls: tls))
        self.request = request
    }

    static func exchange(port: Int, pin: String, request: String) async throws -> String {
        let raw = RawTLS(port: port, pin: pin, request: request)
        defer { raw.connection.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            raw.queue.async { raw.begin(continuation) }
        }
    }

    private func begin(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                connection.send(content: Data(request.utf8), completion: .idempotent)
                read()
            case .failed(let error), .waiting(let error):
                finish(.failure(error))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [self] in finish(.failure(Failed())) }
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            if let data { received.append(data) }
            if complete || error != nil {
                let text = String(data: received, encoding: .utf8) ?? ""
                finish(text.isEmpty ? .failure(error ?? Failed()) : .success(text))
            } else {
                read()
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// `event:` / `data:` の行から 1 件ずつ取り出す（`: ping` のコメントは読み飛ばす）。
struct SSEReader<Lines: AsyncIteratorProtocol> where Lines.Element == String {
    var lines: Lines

    init(_ lines: Lines) {
        self.lines = lines
    }

    mutating func next() async throws -> (name: String, data: String)? {
        var name: String?
        while let line = try await lines.next() {
            if line.hasPrefix("event: ") {
                name = String(line.dropFirst(7))
            } else if line.hasPrefix("data: "), let current = name {
                return (current, String(line.dropFirst(6)))
            }
        }
        return nil
    }
}
