import XCTest
@testable import MonitorKit

/// `mac/scripts/perf-summary.sh` を集計器が書いた perf.log で動かす（一時ディレクトリだけを使う）。
final class PerfSummaryScriptTests: XCTestCase {
    private var macRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var script: URL { macRoot.appendingPathComponent("scripts/perf-summary.sh") }
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("perf-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = script
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": dir.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    func testIsExecutable() {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path))
    }

    /// メインの合計時間の多い順に並べ、回数/秒・詰まり・文脈を出す。
    func testSummarizesCollectorOutput() throws {
        let url = dir.appendingPathComponent("perf.log")
        let collector = PerfCollector(log: MenuOpsLog(url: url, keep: PerfCollector.maxLines))
        for _ in 0..<2 {
            collector.add("test.heavy", ns: 30_000_000, value: 0, main: true)
            collector.add("test.light", ns: 1_000_000, value: 7, main: true)
            collector.add("test.background", ns: 50_000_000, value: 0, main: false)
            collector.add("test.body", ns: nil, value: 0, main: true)
            collector.addLag(300_000_000)
            collector.addLag(1_000_000)
            collector.flush(seconds: 10)
        }
        collector.log.flush()
        let (status, output) = try run([url.path])
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.contains("2 回・20 秒"), output)
        XCTAssertTrue(output.contains("250ms 以上 2 回"), output)
        let heavy = try XCTUnwrap(output.range(of: "test.heavy"))
        let light = try XCTUnwrap(output.range(of: "test.light（14）"))
        XCTAssertLessThan(heavy.lowerBound, light.lowerBound)
        let background = try XCTUnwrap(output.range(of: "メイン以外の区間"))
        XCTAssertLessThan(light.lowerBound, background.lowerBound)
        XCTAssertTrue(output.contains("test.body"), output)
    }

    /// 既定は最後の起動の分だけ、`-a` で全部を読む。
    func testReadsLastLaunchUnlessAll() throws {
        let url = dir.appendingPathComponent("perf.log")
        let log = MenuOpsLog(url: url, keep: PerfCollector.maxLines)
        for (launch, label) in [(0, "old"), (1, "new")] {
            log.record("start")
            log.record("ctx", [("sec", "10.0"), ("hosted", String(launch))])
            log.record("span", [("name", "test.\(label)"), ("thread", "main"), ("n", "1"), ("total_ms", "5.00"), ("max_ms", "5.00")])
        }
        log.flush()
        let last = try run([url.path])
        XCTAssertEqual(last.status, 0, last.output)
        XCTAssertTrue(last.output.contains("1 回・10 秒・最後の起動から"), last.output)
        XCTAssertTrue(last.output.contains("test.new"), last.output)
        XCTAssertFalse(last.output.contains("test.old"), last.output)
        let all = try run(["-a", url.path])
        XCTAssertTrue(all.output.contains("2 回・20 秒・全部の起動"), all.output)
        XCTAssertTrue(all.output.contains("test.old"), all.output)
    }

    func testFailsWithoutLog() throws {
        XCTAssertEqual(try run([dir.appendingPathComponent("missing.log").path]).status, 1)
        XCTAssertEqual(try run(["-t", "x"]).status, 2)
    }
}
