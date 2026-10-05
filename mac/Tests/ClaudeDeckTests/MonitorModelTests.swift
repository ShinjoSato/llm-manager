import XCTest
@testable import MonitorKit

final class MonitorModelTests: XCTestCase {
    func testConfigurationFromEnvironment() {
        let base = MonitorConfiguration.fromEnvironment(["HOME": "/x"])
        XCTAssertEqual(base.serverPort, 8766, "フックの宛先（:8766）をそのまま受ける")
        XCTAssertFalse(base.debugLogging)
        XCTAssertEqual(base.usageFile?.path, "/x/Library/Application Support/claude-deck/usage.json", "statusline.sh の既定と同じ場所")

        let c = MonitorConfiguration.fromEnvironment(["CLAUDE_HOME": "/tmp/fake-claude", "CLAUDE_DECK_SERVER_PORT": "8799",
                                                      "CLAUDE_DECK_MONITOR_DEBUG": "1"])
        XCTAssertEqual(c.claudeHome.root.path, "/tmp/fake-claude")
        XCTAssertEqual(c.claudeHome.sessionsDirectory.path, "/tmp/fake-claude/sessions")
        XCTAssertEqual(c.serverPort, 8799)
        XCTAssertTrue(c.debugLogging)

        XCTAssertNil(MonitorConfiguration.fromEnvironment(["CLAUDE_DECK_SERVER_PORT": "off"]).serverPort)
        XCTAssertEqual(MonitorConfiguration.fromEnvironment(["CLAUDE_DECK_SERVER_PORT": "nope"]).serverPort, 8766)
        XCTAssertEqual(MonitorConfiguration.fromEnvironment(["CLAUDE_DECK_USAGE_FILE": "/u.json", "MONITOR_USAGE_FILE": "/m.json"]).usageFile?.path, "/u.json")
        XCTAssertNotEqual(MonitorConfiguration.fromEnvironment(["MONITOR_USAGE_FILE": "/m.json"]).usageFile?.path, "/m.json", "スクリプトが読まない旧名は読まない")
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
