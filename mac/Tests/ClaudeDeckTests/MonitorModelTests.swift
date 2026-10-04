import XCTest
@testable import MonitorKit

final class MonitorModelTests: XCTestCase {
    static let sessionJSON = """
    {"sessionId":"s1","pid":123,"alive":true,"name":"ai-manager-81","project":"ai-manager","cwd":"/tmp/x",
     "branch":"develop","title":null,"lastPrompt":"hi","status":"working","statusSource":"transcript",
     "statusDetail":null,"attentionSince":null,"entrypoint":"cli","version":"2.1.285","startedAt":1790773845048,
     "lastActivityAt":1790773846000,"currentTool":"Bash","currentSkill":null,"currentAction":"ls",
     "tokens":{"input":10,"output":20,"cacheRead":30},
     "agents":[{"id":"a1","type":"developer-plugin:code-reviewer","lastActivityAt":1790773846000}],
     "canReceive":true,"xcodeProject":null}
    """

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testDecodesSession() throws {
        let s = try decode(SessionSnapshot.self, Self.sessionJSON)
        XCTAssertEqual(s.pid, 123)
        XCTAssertEqual(s.status, .working)
        XCTAssertEqual(s.statusSource, .transcript)
        XCTAssertEqual(s.tokens, TokenUsage(input: 10, output: 20, cacheRead: 30))
        XCTAssertEqual(s.agents.first?.type, "developer-plugin:code-reviewer")
        XCTAssertNil(s.title)
        XCTAssertNil(s.attentionSince)
        XCTAssertEqual(s.startedDate.timeIntervalSince1970, 1790773845.048, accuracy: 0.001)
    }

    func testUnknownStatusDoesNotFailDecoding() throws {
        let json = Self.sessionJSON.replacingOccurrences(of: "\"working\"", with: "\"sleeping\"")
        XCTAssertEqual(try decode(SessionSnapshot.self, json).status, .unknown)
    }

    func testTranscriptItemWithoutImagesDecodes() throws {
        let json = #"{"id":"u:0","kind":"tool","at":null,"text":null,"tool":{"name":"Bash","description":null,"target":"ls"},"parentId":"a:0"}"#
        let item = try decode(TranscriptItem.self, json)
        XCTAssertEqual(item.tool?.target, "ls")
        XCTAssertEqual(item.images, [])
    }

    func testRemainingPercentage() {
        XCTAssertEqual(UsageWindow(usedPercentage: 35.5, resetsAt: nil).remainingPercentage, 64.5, accuracy: 0.001)
        XCTAssertEqual(UsageWindow(usedPercentage: 120, resetsAt: nil).remainingPercentage, 0)
    }

    func testConfigurationFromEnvironment() {
        let base = MonitorConfiguration.fromEnvironment(["HOME": "/x"])
        XCTAssertEqual(base.serverPort, 8766, "フックの宛先（:8766）をそのまま受ける")
        XCTAssertFalse(base.debugLogging)
        XCTAssertEqual(base.usageFile?.path, "/x/Library/Application Support/claude-deck/usage.json", "statusline.sh の既定と同じ場所")
        XCTAssertNil(base.legacyUsageFile)

        let usage = URL(fileURLWithPath: "/repo/data/claude-usage.json")
        let c = MonitorConfiguration.fromEnvironment(["CLAUDE_HOME": "/tmp/fake-claude", "CLAUDE_DECK_SERVER_PORT": "8799",
                                                      "CLAUDE_DECK_MONITOR_DEBUG": "1"], legacyUsageFile: usage)
        XCTAssertEqual(c.claudeHome.root.path, "/tmp/fake-claude")
        XCTAssertEqual(c.claudeHome.sessionsDirectory.path, "/tmp/fake-claude/sessions")
        XCTAssertEqual(c.serverPort, 8799)
        XCTAssertEqual(c.legacyUsageFile, usage)
        XCTAssertTrue(c.debugLogging)

        XCTAssertNil(MonitorConfiguration.fromEnvironment(["CLAUDE_DECK_SERVER_PORT": "off"]).serverPort)
        XCTAssertEqual(MonitorConfiguration.fromEnvironment(["CLAUDE_DECK_SERVER_PORT": "nope"]).serverPort, 8766)
        XCTAssertEqual(MonitorConfiguration.fromEnvironment(["CLAUDE_DECK_USAGE_FILE": "/u.json", "MONITOR_USAGE_FILE": "/m.json"]).usageFile?.path, "/u.json")
        XCTAssertEqual(MonitorConfiguration.fromEnvironment(["MONITOR_USAGE_FILE": "/m.json"]).usageFile?.path, "/m.json", "旧名も読む")
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
