import XCTest
@testable import MonitorKit

/// `mac/scripts/statusline.sh` を偽の入力で動かす。保存先は一時ディレクトリに差し替え、実データには書かない。
final class StatusLineScriptTests: XCTestCase {
    private var macRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var script: URL { macRoot.appendingPathComponent("scripts/statusline.sh") }

    /// スクリプトに渡す PATH。swift test の PATH に Homebrew が無くても、手元の jq を見つけられるようにする。
    private var searchPath: String {
        let base = ProcessInfo.processInfo.environment["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin:/bin"
        return base + ":/opt/homebrew/bin:/usr/local/bin"
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("statusline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func run(_ input: String, env extra: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_DECK_USAGE_FILE"] = nil
        env["PATH"] = searchPath
        env["HOME"] = dir.appendingPathComponent("home").path
        env.merge(extra) { _, new in new }
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: out, as: UTF8.self)
    }

    private func requireJQ() throws {
        // スクリプトと同じ PATH で探す。
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "jq"]
        which.environment = ["PATH": searchPath]
        which.standardOutput = FileHandle.nullDevice
        which.standardError = FileHandle.nullDevice
        try which.run()
        which.waitUntilExit()
        try XCTSkipUnless(which.terminationStatus == 0, "jq が無い環境ではスクリプトが値を読めない")
    }

    private func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testShowsAndSavesToOverriddenFile() throws {
        try requireJQ()
        let target = dir.appendingPathComponent("deck/usage.json")
        let reset = Int(Date().timeIntervalSince1970) + 2 * 3600 + 5 * 60 + 30
        let input = #"{"rate_limits":{"five_hour":{"used_percentage":42.7,"resets_at":\#(reset)},"seven_day":{"used_percentage":61.2}}}"#
        let shown = try run(input, env: ["CLAUDE_DECK_USAGE_FILE": target.path])
        XCTAssertEqual(shown, "セッション: 43% (リセット: 2時間5分後) | 週間: 61%")

        let saved = try XCTUnwrap(UsageReader.read(target), "アプリの UsageReader がそのまま読める形")
        XCTAssertEqual(saved.fiveHour, UsageWindow(usedPercentage: 42.7, resetsAt: Double(reset) * 1000))
        XCTAssertEqual(saved.sevenDay, UsageWindow(usedPercentage: 61.2, resetsAt: nil))
        XCTAssertEqual(saved.fetchedAt, (Date().timeIntervalSince1970 * 1000).rounded(), accuracy: 10_000)
        XCTAssertEqual(try mode(target.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try mode(target), 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["usage.json"], "一時ファイルを残さない")

        // 値が 1 つも無い入力では、表示も記録の上書きもしない。
        XCTAssertEqual(try run(#"{"model":{"id":"x"}}"#, env: ["CLAUDE_DECK_USAGE_FILE": target.path]), "")
        XCTAssertEqual(UsageReader.read(target), saved)
    }

    func testDefaultsToApplicationSupport() throws {
        try requireJQ()
        let shown = try run(#"{"rate_limits":{"seven_day":{"used_percentage":5}}}"#, env: [:])
        XCTAssertEqual(shown, "週間: 5%")
        let expected = UsageReader.defaultFile(["HOME": dir.appendingPathComponent("home").path])!
        XCTAssertEqual(expected.path, dir.appendingPathComponent("home/Library/Application Support/claude-deck/usage.json").path)
        XCTAssertEqual(UsageReader.read(expected)?.sevenDay?.usedPercentage, 5, "アプリの既定の読み取り先と同じ場所に書く")
    }
}
