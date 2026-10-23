import XCTest
@testable import MonitorKit

final class MenuOpsLogTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_760_000_000)

    func testLineHasTimeEventAndFields() {
        let line = MenuOpsLog.line("press", [("key", "menu:ABC"), ("card", "m-123"), ("choice", "2")], date: date)
        XCTAssertEqual(line, "2025-10-09T08:53:20.000Z press key=menu:ABC card=m-123 choice=2")
    }

    /// 値の空白・改行・`=` は 1 行・1 項目に収め、長い値は切る（取り違えて本文を渡しても長く残さない）。
    func testValuesAreKeptOnOneLineAndShort() {
        let line = MenuOpsLog.line("x", [("a b", "1 2\n3=4"), ("long", String(repeating: "あ", count: 200)), ("empty", "")], date: date)
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.contains(" a_b=1_2_3_4 "))
        XCTAssertTrue(line.contains(" long=" + String(repeating: "あ", count: MenuOpsLog.maxValueLength) + " "))
        XCTAssertTrue(line.hasSuffix(" empty=-"))
    }

    func testAppendingKeepsLatestLines() {
        var log = ""
        for index in 0..<10 { log = MenuOpsLog.appending(["line \(index)"], to: log, keep: 4) }
        XCTAssertEqual(log, "line 6\nline 7\nline 8\nline 9\n")
        XCTAssertEqual(MenuOpsLog.appending(["a", "b"], to: "\n\nold\n", keep: 10), "old\na\nb\n")
    }

    /// 本人だけが読める 0600 で書き、直近の行だけを残す。
    func testWritesOwnerOnlyAndTrims() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("menu-ops-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("menu-ops.log")
        let log = MenuOpsLog(url: url, keep: 3)
        for index in 0..<5 { log.record("e\(index)", [("n", "\(index)")], date: date) }
        log.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").map { String($0.split(separator: " ")[1]) }, ["e2", "e3", "e4"])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        log.record("e5", date: date)
        log.flush()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 3)
    }

    func testDefaultLocationIsLogsDirectory() {
        XCTAssertEqual(MenuOpsLog.shared.url, DeckPaths.logs.appendingPathComponent("menu-ops.log"))
        XCTAssertEqual(MenuOpsLog.maxLines, 500)
    }
}

final class ClaudeCodeVersionsTests: XCTestCase {
    func testVerifiedVersions() {
        XCTAssertEqual(ClaudeCodeVersions.verified, ["2.1.286", "2.1.288", "2.1.300"])
        for version in ["2.1.286", "2.1.288", "2.1.300", "v2.1.300", " 2.1.300 "] {
            XCTAssertEqual(ClaudeCodeVersions.isVerified(version), true, version)
            XCTAssertNil(ClaudeCodeVersions.untestedNote(version), version)
        }
    }

    func testUntestedVersionGetsNote() {
        XCTAssertEqual(ClaudeCodeVersions.isVerified("2.1.296"), false)
        let note = ClaudeCodeVersions.untestedNote("2.1.296")
        XCTAssertEqual(note, "この版の Claude Code（2.1.296）は未確認です。うまく答えられない時は端末の画面から答えてください。")
    }

    /// 版が分からない時は案内しない（読めないだけで未確認とは言えない）。
    func testUnknownVersionHasNoNote() {
        XCTAssertNil(ClaudeCodeVersions.isVerified(nil))
        XCTAssertNil(ClaudeCodeVersions.isVerified(""))
        XCTAssertNil(ClaudeCodeVersions.untestedNote(nil))
    }

    /// セッションファイルの version を読む（型が違っても記録ごと落とさない）。
    func testSessionRecordReadsVersion() throws {
        let json = #"{"pid":42,"sessionId":"s1","version":"2.1.300","status":"waiting"}"#
        let record = try JSONDecoder().decode(ClaudeSessionRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.version, "2.1.300")
        let odd = #"{"pid":42,"sessionId":"s1","version":2}"#
        let lenient = try JSONDecoder().decode(ClaudeSessionRecord.self, from: Data(odd.utf8))
        XCTAssertNil(lenient.version)
        XCTAssertEqual(lenient.sessionId, "s1")
    }
}
