import XCTest
@testable import MonitorKit

/// 届いた要求に、決めた応答を返す偽の mcpbridge。
private final class FakeBridge: XcodeBridgeTransport, @unchecked Sendable {
    typealias Responder = @Sendable (_ method: String, _ tool: String?, _ arguments: [String: Any]) -> Any?

    private let lock = NSLock()
    private var sentMessages: [[String: Any]] = []
    private var stopCount = 0
    private let events: AsyncStream<XcodeBridgeEvent>.Continuation
    private let responder: Responder

    init(events: AsyncStream<XcodeBridgeEvent>.Continuation, responder: @escaping Responder) {
        self.events = events
        self.responder = responder
    }

    var sent: [[String: Any]] { lock.withLock { sentMessages } }
    var stops: Int { lock.withLock { stopCount } }
    var toolCalls: [String] {
        sent.compactMap { ($0["params"] as? [String: Any])?["name"] as? String }
    }

    func send(_ line: Data) throws {
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        lock.withLock { sentMessages.append(message) }
        guard let id = message["id"] as? Int else { return }
        let params = message["params"] as? [String: Any]
        let reply = responder(message["method"] as? String ?? "", params?["name"] as? String, params?["arguments"] as? [String: Any] ?? [:])
        guard let reply else { return }
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": reply]
        events.yield(.line(try JSONSerialization.data(withJSONObject: envelope)))
    }

    func exit(_ detail: String) {
        events.yield(.exited(detail))
        events.finish()
    }

    func stop() async {
        lock.withLock { stopCount += 1 }
        events.finish()
    }
}

/// 起動した偽物を覚えておく。
private final class Launched: @unchecked Sendable {
    private let lock = NSLock()
    private var bridges: [FakeBridge] = []
    var all: [FakeBridge] { lock.withLock { bridges } }
    func add(_ bridge: FakeBridge) { lock.withLock { bridges.append(bridge) } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

private func tool(_ structured: [String: Any]) -> [String: Any] {
    ["content": [["type": "text", "text": "{}"]], "structuredContent": structured]
}

private func toolError(_ text: String) -> [String: Any] {
    ["isError": true, "content": [["type": "text", "text": text]]]
}

/// RenderPreview を持つ Xcode の既定の応答。
private func standardReply(_ method: String, _ name: String?, _ arguments: [String: Any]) -> Any? {
    switch (method, name) {
    case ("initialize", _): return ["protocolVersion": "2025-06-18", "capabilities": [String: Any]()]
    case ("tools/list", _): return ["tools": [["name": "RenderPreview"], ["name": "XcodeGlob"], ["name": "XcodeWrite"]]]
    case ("tools/call", "XcodeOpenWorkspace"): return tool(["workspaceIdentifier": "workspace-1", "activeScheme": "App"])
    case ("tools/call", "XcodeGlob"): return tool(["matches": ["App/Views/V.swift"], "pattern": "**/V.swift", "searchPath": "", "truncated": false, "totalFound": 1])
    case ("tools/call", "XcodeCloseWorkspace"): return tool(["message": "Closed"])
    case ("tools/call", "RenderPreview"):
        return tool(["displayName": "V", "previewSnapshotPath": "/tmp/v.png", "errors": [Any](),
                     "supportedPreviewVariantOverrides": ["Color Scheme": ["Light Appearance", "Dark Appearance"]]])
    default: return nil
    }
}

final class XcodeBridgeClientTests: XCTestCase {
    private func client(launched: Launched, timeouts: XcodeBridgeClient.Timeouts = .init(),
                        responder: @escaping FakeBridge.Responder = standardReply) -> XcodeBridgeClient {
        XcodeBridgeClient(timeouts: timeouts) { events in
            let bridge = FakeBridge(events: events, responder: responder)
            launched.add(bridge)
            return bridge
        }
    }

    func testHandshakeThenOpenGlobRenderClose() async throws {
        let launched = Launched()
        let client = client(launched: launched)
        try await client.start()
        let isRunning = await client.isRunning
        XCTAssertTrue(isRunning)
        let opened = try await client.openWorkspace(path: "/p/App.xcodeproj")
        XCTAssertEqual(opened.workspaceIdentifier, "workspace-1")
        let found = try await client.glob(workspace: "workspace-1", pattern: "**/V.swift")
        XCTAssertEqual(found.matches, ["App/Views/V.swift"])
        let result = try await client.renderPreview(RenderPreviewArguments(
            workspaceIdentifier: "workspace-1", sourceFilePath: "App/Views/V.swift", index: 0,
            variants: ["Color Scheme": "Dark Appearance"], timeout: 60))
        XCTAssertEqual(result.previewSnapshotPath, "/tmp/v.png")
        try await client.closeWorkspace("workspace-1")
        await client.stop()

        let bridge = try XCTUnwrap(launched.all.first)
        XCTAssertEqual(bridge.sent.map { $0["method"] as? String }, ["initialize", "notifications/initialized", "tools/list",
                                                                     "tools/call", "tools/call", "tools/call", "tools/call"])
        XCTAssertEqual(bridge.toolCalls, ["XcodeOpenWorkspace", "XcodeGlob", "RenderPreview", "XcodeCloseWorkspace"])
        let render = try XCTUnwrap(bridge.sent.first { ($0["params"] as? [String: Any])?["name"] as? String == "RenderPreview" })
        let arguments = try XCTUnwrap((render["params"] as? [String: Any])?["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["previewVariantOverrides"] as? [String: String], ["Color Scheme": "Dark Appearance"])
        XCTAssertEqual(bridge.stops, 1)
        let stillRunning = await client.isRunning
        XCTAssertFalse(stillRunning)
    }

    func testRequestsAreSentOneAtATime() async throws {
        let launched = Launched()
        let client = client(launched: launched)
        try await client.start()
        async let a = client.glob(workspace: "w", pattern: "**/A.swift")
        async let b = client.glob(workspace: "w", pattern: "**/B.swift")
        async let c = client.glob(workspace: "w", pattern: "**/C.swift")
        _ = try await (a, b, c)
        let ids = try XCTUnwrap(launched.all.first).sent.compactMap { $0["id"] as? Int }
        XCTAssertEqual(ids.count, 5)
        XCTAssertEqual(Set(ids).count, 5)
    }

    func testOlderXcodeWithoutRenderPreviewIsUnsupported() async throws {
        let launched = Launched()
        let client = client(launched: launched) { method, name, arguments in
            method == "tools/list" ? ["tools": [["name": "XcodeGlob"]]] : standardReply(method, name, arguments)
        }
        do {
            try await client.start()
            XCTFail("unsupported のはず")
        } catch {
            XCTAssertEqual(error as? XcodeBridgeFailure, .unsupported)
        }
        XCTAssertEqual(launched.all.first?.stops, 1)
        let isRunning = await client.isRunning
        XCTAssertFalse(isRunning)
    }

    func testUnapprovedOpenIsReported() async throws {
        let launched = Launched()
        let client = client(launched: launched) { method, name, arguments in
            name == "XcodeOpenWorkspace"
                ? toolError("Xcode is waiting for the user to approve this request; it has been recorded.")
                : standardReply(method, name, arguments)
        }
        try await client.start()
        do {
            _ = try await client.openWorkspace(path: "/p/App.xcodeproj")
            XCTFail("notApproved のはず")
        } catch {
            XCTAssertEqual(error as? XcodeBridgeFailure, .notApproved)
        }
        // 1 件の失敗では止めない。
        let isRunning = await client.isRunning
        XCTAssertTrue(isRunning)
        await client.stop()
    }

    func testTimeoutStopsBridgeAndNextStartLaunchesAgain() async throws {
        let launched = Launched()
        var timeouts = XcodeBridgeClient.Timeouts()
        timeouts.short = .milliseconds(200)
        let client = client(launched: launched, timeouts: timeouts) { method, name, arguments in
            name == "XcodeGlob" ? nil : standardReply(method, name, arguments)
        }
        try await client.start()
        do {
            _ = try await client.glob(workspace: "w", pattern: "**/A.swift")
            XCTFail("timedOut のはず")
        } catch {
            XCTAssertEqual(error as? XcodeBridgeFailure, .timedOut(0))
        }
        let isRunning = await client.isRunning
        XCTAssertFalse(isRunning)
        XCTAssertEqual(launched.all.first?.stops, 1)
        try await client.start()
        XCTAssertEqual(launched.all.count, 2)
        await client.stop()
    }

    func testExitFailsPendingRequest() async throws {
        let launched = Launched()
        let client = client(launched: launched) { method, name, arguments in
            name == "RenderPreview" ? nil : standardReply(method, name, arguments)
        }
        try await client.start()
        let bridge = try XCTUnwrap(launched.all.first)
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            bridge.exit("Xcode is not running")
        }
        do {
            _ = try await client.renderPreview(RenderPreviewArguments(workspaceIdentifier: "w", sourceFilePath: "A.swift", index: 0, timeout: 60))
            XCTFail("終了で失敗するはず")
        } catch {
            XCTAssertEqual(error as? XcodeBridgeFailure, .xcodeNotRunning)
        }
        let isRunning = await client.isRunning
        XCTAssertFalse(isRunning)
    }

    func testRetriesWhilePackagesLoad() async throws {
        let launched = Launched()
        let attempts = Counter()
        let client = client(launched: launched) { method, name, arguments in
            guard name == "RenderPreview" else { return standardReply(method, name, arguments) }
            if attempts.next() < 3 {
                return tool(["errors": [["message": #"{"type":"error","data":"PreviewBlockedReason: Waiting for packages to load"}"#]]])
            }
            return standardReply(method, name, arguments)
        }
        try await client.start()
        let result = try await client.renderPreview(RenderPreviewArguments(workspaceIdentifier: "w", sourceFilePath: "A.swift", index: 0, timeout: 60),
                                                    packagesWait: .seconds(5), retryInterval: .milliseconds(20))
        XCTAssertEqual(result.previewSnapshotPath, "/tmp/v.png")
        XCTAssertEqual(attempts.count, 3)

        // 待つ時間を過ぎたら、読み込み中のまま返す。
        let stuck = self.client(launched: Launched()) { method, name, arguments in
            name == "RenderPreview"
                ? tool(["errors": [["message": "Waiting for packages to load"]]])
                : standardReply(method, name, arguments)
        }
        try await stuck.start()
        do {
            _ = try await stuck.renderPreview(RenderPreviewArguments(workspaceIdentifier: "w", sourceFilePath: "A.swift", index: 0, timeout: 60),
                                              packagesWait: .milliseconds(100), retryInterval: .milliseconds(20))
            XCTFail("packagesLoading のはず")
        } catch {
            XCTAssertEqual(error as? XcodeBridgeFailure, .packagesLoading)
        }
        await client.stop()
        await stuck.stop()
    }

    func testLaunchFailureIsReported() async {
        let client = XcodeBridgeClient { _ in throw PosixSpawnError.failed(ENOENT) }
        do {
            try await client.start()
            XCTFail("起動できないはず")
        } catch {
            guard case .bridgeUnavailable = error as? XcodeBridgeFailure else { return XCTFail("\(error)") }
        }
    }
}

final class XcodeBridgeProcessTests: XCTestCase {
    func testLinesRoundTripAndStopClosesGroup() async throws {
        let (stream, continuation) = AsyncStream<XcodeBridgeEvent>.makeStream()
        // 孫まで同じグループで動く（cat を子に持つ sh）。
        let process = try XcodeBridgeProcess.spawn(executable: "/bin/sh", arguments: ["-c", "cat; sleep 30"],
                                                   environment: ["PATH": "/usr/bin:/bin"], directory: NSTemporaryDirectory(),
                                                   events: continuation)
        try process.send(Data(#"{"id":1}"#.utf8))
        try process.send(Data(#"{"id":2}"#.utf8))
        var lines: [String] = []
        for await event in stream {
            if case .line(let data) = event { lines.append(String(decoding: data, as: UTF8.self)) }
            if lines.count == 2 { break }
        }
        XCTAssertEqual(lines, [#"{"id":1}"#, #"{"id":2}"#])
        await process.stop()
        XCTAssertTrue(process.isFinished)
        XCTAssertEqual(DevServerProcess.groupAlive(process.pid), false)
        XCTAssertThrowsError(try process.send(Data("x".utf8)))
    }

    func testExitIsReportedWithStderr() async throws {
        let (stream, continuation) = AsyncStream<XcodeBridgeEvent>.makeStream()
        let process = try XcodeBridgeProcess.spawn(executable: "/bin/sh", arguments: ["-c", "echo 'no Xcode' >&2; exit 3"],
                                                   environment: [:], directory: NSTemporaryDirectory(), events: continuation)
        var detail: String?
        for await event in stream {
            if case .exited(let text) = event { detail = text }
        }
        XCTAssertEqual(detail, "no Xcode")
        await process.stop()
        XCTAssertTrue(process.isFinished)
    }

    func testBlockingStopKillsProcessIgnoringTerm() async throws {
        let (stream, continuation) = AsyncStream<XcodeBridgeEvent>.makeStream()
        let process = try XcodeBridgeProcess.spawn(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; echo ready; sleep 60 & wait"],
                                                   environment: ["PATH": "/usr/bin:/bin"], directory: NSTemporaryDirectory(),
                                                   events: continuation)
        // trap が効いてから止める。
        for await event in stream {
            if case .line = event { break }
        }
        let started = Date()
        XcodeBridgeProcess.stopAllBlocking([process])
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(process.isFinished)
        XCTAssertGreaterThanOrEqual(elapsed, DevServerStopPlan.grace - 0.2)
        XCTAssertLessThan(elapsed, DevServerStopPlan.grace + DevServerStopPlan.killWait + 2)
        XCTAssertEqual(DevServerProcess.groupAlive(process.pid), false)
    }
}
