import XCTest
@testable import MonitorKit

final class MonitorModelTests: XCTestCase {
    static let sessionJSON = """
    {"sessionId":"s1","pid":123,"alive":true,"name":"ai-manager-81","project":"ai-manager","cwd":"/tmp/x",
     "branch":"develop","title":null,"lastPrompt":"hi","status":"working","statusSource":"transcript",
     "statusDetail":null,"entrypoint":"cli","version":"2.1.285","startedAt":1790773845048,
     "lastActivityAt":1790773846000,"currentTool":"Bash","currentSkill":null,"currentAction":"ls",
     "tokens":{"input":10,"output":20,"cacheRead":30},
     "agents":[{"id":"a1","type":"developer-plugin:code-reviewer","lastActivityAt":1790773846000}],
     "canReceive":true,"xcodeProject":null}
    """

    func testDecodesSessionsEvent() throws {
        let event = try MonitorEvent.decode(SSEEvent(event: "sessions", data: "[\(Self.sessionJSON)]"))
        guard case .sessions(let list) = event else { return XCTFail("\(event)") }
        XCTAssertEqual(list.count, 1)
        let s = list[0]
        XCTAssertEqual(s.pid, 123)
        XCTAssertEqual(s.status, .working)
        XCTAssertEqual(s.statusSource, .transcript)
        XCTAssertEqual(s.tokens, TokenUsage(input: 10, output: 20, cacheRead: 30))
        XCTAssertEqual(s.agents.first?.type, "developer-plugin:code-reviewer")
        XCTAssertNil(s.title)
        XCTAssertEqual(s.startedDate.timeIntervalSince1970, 1790773845.048, accuracy: 0.001)
    }

    func testUnknownStatusDoesNotFailDecoding() throws {
        let json = Self.sessionJSON.replacingOccurrences(of: "\"working\"", with: "\"sleeping\"")
        let event = try MonitorEvent.decode(SSEEvent(event: "sessions", data: "[\(json)]"))
        guard case .sessions(let list) = event else { return XCTFail() }
        XCTAssertEqual(list.first?.status, .unknown)
    }

    func testDecodesFeedAndBatch() throws {
        let item = #"{"id":5,"sessionId":"s1","project":"p","at":1,"kind":"tool","text":"Bash ls","tool":"Bash"}"#
        XCTAssertEqual(try MonitorEvent.decode(SSEEvent(event: "feed", data: item)),
                       .feed(FeedItem(id: 5, sessionId: "s1", project: "p", at: 1, kind: .tool, text: "Bash ls", tool: "Bash", local: nil)))
        guard case .feedBatch(let items) = try MonitorEvent.decode(SSEEvent(event: "feed-batch", data: "[\(item)]")) else { return XCTFail() }
        XCTAssertEqual(items.map(\.id), [5])
    }

    func testDecodesUsageIncludingNull() throws {
        XCTAssertEqual(try MonitorEvent.decode(SSEEvent(event: "usage", data: "null")), .usage(nil))
        let json = #"{"fetchedAt":1000,"fiveHour":{"usedPercentage":35.5,"resetsAt":2000},"sevenDay":null}"#
        guard case .usage(let usage?) = try MonitorEvent.decode(SSEEvent(event: "usage", data: json)) else { return XCTFail() }
        XCTAssertEqual(usage.fiveHour?.remainingPercentage ?? 0, 64.5, accuracy: 0.001)
        XCTAssertNil(usage.sevenDay)
    }

    func testDecodesPermissions() throws {
        let json = #"[{"key":"123:abcde","requestId":"abcde","sessionId":null,"project":"p","toolName":"Bash","description":"run","inputPreview":"ls","askedAt":1}]"#
        guard case .permissions(let list) = try MonitorEvent.decode(SSEEvent(event: "permissions", data: json)) else { return XCTFail() }
        XCTAssertEqual(list.first?.key, "123:abcde")
        XCTAssertNil(list.first?.sessionId)
    }

    func testDecodesTranscriptAndUnknownEvent() throws {
        let json = #"{"sessionId":"s1","items":[{"id":"u:0","kind":"tool","at":null,"text":null,"tool":{"name":"Bash","description":null,"target":"ls"},"parentId":"a:0"}]}"#
        guard case .transcript(let t) = try MonitorEvent.decode(SSEEvent(event: "transcript", data: json)) else { return XCTFail() }
        XCTAssertEqual(t.items.first?.tool?.target, "ls")
        XCTAssertEqual(try MonitorEvent.decode(SSEEvent(event: "future", data: "{}")), .unknown(name: "future"))
    }

    func testMalformedPayloadThrows() {
        XCTAssertThrowsError(try MonitorEvent.decode(SSEEvent(event: "sessions", data: "{")))
    }

    func testBackoffGrowsAndCaps() {
        let b = ReconnectBackoff(initial: 0.5, maximum: 10, multiplier: 2, jitter: 0.2)
        XCTAssertEqual(b.delay(forAttempt: 0, random: 0), 0.5)
        XCTAssertEqual(b.delay(forAttempt: 3, random: 0), 4)
        XCTAssertEqual(b.delay(forAttempt: 100, random: 0), 10)
        XCTAssertEqual(b.delay(forAttempt: 100, random: 1), 8, accuracy: 0.0001)
    }

    func testConfigurationFromEnvironment() {
        XCTAssertEqual(MonitorConfiguration.fromEnvironment([:]).baseURL, MonitorConfiguration.defaultBaseURL)
        XCTAssertEqual(MonitorConfiguration.fromEnvironment(["CLAUDE_DECK_MONITOR_PORT": "8799"]).baseURL.absoluteString, "http://127.0.0.1:8799")
        let c = MonitorConfiguration.fromEnvironment(["CLAUDE_DECK_MONITOR_URL": "http://localhost:9000/", "CLAUDE_DECK_MONITOR_PORT": "8799", "CLAUDE_DECK_MONITOR_DEBUG": "1"])
        XCTAssertEqual(c.baseURL.absoluteString, "http://localhost:9000/")
        XCTAssertTrue(c.debugLogging)
        XCTAssertEqual(MonitorConfiguration.fromEnvironment(["CLAUDE_DECK_MONITOR_PORT": "nope"]).baseURL, MonitorConfiguration.defaultBaseURL)
    }

    func testEndpointsAndEscaping() {
        let client = MonitorClient(configuration: MonitorConfiguration(baseURL: URL(string: "http://localhost:9000/")!))
        XCTAssertEqual(client.endpoint("/api/sessions").absoluteString, "http://localhost:9000/api/sessions")
        XCTAssertEqual(client.eventsURL(transcripts: .none).absoluteString, "http://localhost:9000/events")
        XCTAssertEqual(client.eventsURL(transcripts: .all).absoluteString, "http://localhost:9000/events?transcripts=*")
        XCTAssertEqual(client.eventsURL(transcripts: .sessions(["b", "a"])).absoluteString, "http://localhost:9000/events?transcripts=a,b")
        XCTAssertEqual(MonitorClient.pathSegment("123:ab/c?d"), "123%3Aab%2Fc%3Fd")
    }

    func testSessionRegistryLookup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"pid":4242,"sessionId":"sess-1","cwd":"/x","startedAt":1,"extra":"ignored"}"#.utf8)
            .write(to: dir.appendingPathComponent("4242.json"))
        try Data(#"{"pid":999,"sessionId":"wrong"}"#.utf8).write(to: dir.appendingPathComponent("5555.json"))
        let registry = ClaudeSessionRegistry(directory: dir)
        XCTAssertEqual(registry.sessionId(forPid: 4242), "sess-1")
        XCTAssertNil(registry.sessionId(forPid: 5555))   // ファイル名と中身の pid が食い違えば信用しない
        XCTAssertNil(registry.sessionId(forPid: 1))
    }
}
