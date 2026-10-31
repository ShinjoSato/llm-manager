import XCTest
@testable import MonitorKit

final class PerfProbeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func collector() -> (PerfCollector, URL) {
        let url = dir.appendingPathComponent("perf.log")
        return (PerfCollector(log: MenuOpsLog(url: url, keep: PerfCollector.maxLines)), url)
    }

    /// 環境変数か印のファイルがある時だけ有効にする。
    func testRequestedByEnvironmentOrMarker() throws {
        let marker = dir.appendingPathComponent("perf.on")
        XCTAssertFalse(PerfProbe.isRequested(environment: [:], marker: marker))
        XCTAssertFalse(PerfProbe.isRequested(environment: ["CLAUDE_DECK_PERF": "0"], marker: marker))
        XCTAssertTrue(PerfProbe.isRequested(environment: ["CLAUDE_DECK_PERF": "1"], marker: marker))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        XCTAssertTrue(PerfProbe.isRequested(environment: [:], marker: marker))
    }

    /// 無効の時は区間を作らず、値も評価せず、何も書かない。
    func testDisabledDoesNothing() {
        XCTAssertFalse(PerfProbe.isEnabled)
        XCTAssertNil(PerfProbe.begin("test.disabled"))
        XCTAssertEqual(PerfProbe.measure("test.disabled") { 42 }, 42)
        PerfProbe.end(nil, value: { XCTFail("無効の時に値を評価した"); return 0 }())
        PerfProbe.count("test.disabled", value: { XCTFail("無効の時に値を評価した"); return 0 }())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    /// 同じラベルは回数・合計・最大をまとめ、メインとそれ以外を分ける。
    func testAggregatesByLabelAndThread() {
        let (collector, _) = collector()
        collector.add("test.span", ns: 2_000_000, value: 10, main: true)
        collector.add("test.span", ns: 5_000_000, value: 5, main: true)
        collector.add("test.span", ns: 1_000_000, value: 0, main: false)
        collector.add("test.count", ns: nil, value: 3, main: true)
        let drained = collector.drain()
        let main = drained.rows.first { $0.name == "test.span" && $0.main }
        XCTAssertEqual(main?.count, 2)
        XCTAssertEqual(main?.totalNs, 7_000_000)
        XCTAssertEqual(main?.maxNs, 5_000_000)
        XCTAssertEqual(main?.value, 15)
        XCTAssertEqual(drained.rows.first { $0.name == "test.span" && !$0.main }?.count, 1)
        let count = drained.rows.first { $0.name == "test.count" }
        XCTAssertEqual(count?.timed, false)
        XCTAssertEqual(count?.value, 3)
        // メインの合計時間の多い順。
        XCTAssertEqual(drained.rows.first?.name, "test.span")
        XCTAssertTrue(collector.drain().rows.isEmpty)
    }

    /// どのスレッドから同時に呼んでも数を落とさない。
    func testConcurrentRecording() {
        let (collector, _) = collector()
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            let span = collector.begin("test.concurrent")
            collector.end(span, value: 1)
            collector.count("test.concurrentCount", value: 2)
        }
        let rows = collector.drain().rows
        XCTAssertEqual(rows.filter { $0.name == "test.concurrent" }.reduce(0) { $0 + $1.count }, 200)
        XCTAssertEqual(rows.filter { $0.name == "test.concurrent" }.reduce(0) { $0 + $1.value }, 200)
        XCTAssertEqual(rows.filter { $0.name == "test.concurrentCount" }.reduce(0) { $0 + $1.value }, 400)
    }

    /// 詰まりは p50 / p95 / 最大と 250ms 以上の回数を出す。
    func testStallLine() {
        let lags: [UInt64] = (1...19).map { UInt64($0) * 1_000_000 } + [400_000_000]
        let lines = PerfCollector.lines(rows: [], lags: lags, context: [("hosted", 3)], seconds: 10)
        XCTAssertEqual(lines[0].0, "ctx")
        XCTAssertTrue(lines[0].1.contains { $0 == ("hosted", "3") })
        XCTAssertEqual(lines[1].0, "stall")
        let stall = Dictionary(uniqueKeysWithValues: lines[1].1)
        XCTAssertEqual(stall["samples"], "20")
        XCTAssertEqual(stall["over250"], "1")
        XCTAssertEqual(stall["max_ms"], "400.00")
        XCTAssertEqual(stall["p50_ms"], "11.00")
        XCTAssertEqual(stall["p95_ms"], "19.00")
        XCTAssertEqual(PerfCollector.percentile([], 0.5), 0)
    }

    /// 書き出しは 0600 で、ラベルと数だけ（測った処理の中身やパスは入らない）。
    func testFlushWritesOnlyLabelsAndNumbers() throws {
        let (collector, url) = collector()
        let secret = "/Users/someone/project 本文 0f4c2c9e-6d2b-4e57-9a51-7d4c9f2a1b33"
        let span = collector.begin("test.flush")
        _ = secret.count
        collector.end(span, value: 1234)
        collector.count("test.flushCount", value: 0)
        collector.addLag(3_000_000)
        collector.flush(seconds: 10)
        collector.log.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].contains(" ctx sec=10.0"))
        XCTAssertTrue(lines[1].contains(" stall samples=1 "))
        XCTAssertTrue(lines.contains { $0.contains(" span name=test.flush thread=") && $0.contains(" value=1234") && $0.contains(" total_ms=") })
        XCTAssertTrue(lines.contains { $0.contains(" count name=test.flushCount ") && !$0.contains("total_ms") })
        XCTAssertFalse(text.contains("/Users"))
        XCTAssertFalse(text.contains("本文"))
        XCTAssertFalse(text.contains("0f4c2c9e"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // 取り出した後は空の回として書く（区間の行は出ない）。
        collector.flush(seconds: 10)
        collector.log.flush()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 6)
    }

    /// 文脈はメインで取って同じ回の先頭の行に付ける。
    func testFlushAddsContextFromMain() throws {
        let (collector, url) = collector()
        collector.setContext { [("hosted", 2), ("feed", 500)] }
        collector.flush(seconds: 10)
        let written = expectation(description: "main")
        DispatchQueue.main.async { written.fulfill() }
        wait(for: [written], timeout: 2)
        collector.log.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(" ctx sec=10.0 hosted=2 feed=500\n"))
    }

    /// 見張りを始めるとメインへの印の遅れが溜まる。
    func testStallWatcherSamplesMain() {
        let (collector, _) = collector()
        collector.start()
        defer { collector.stop() }
        let waited = expectation(description: "samples")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waited.fulfill() }
        wait(for: [waited], timeout: 3)
        collector.stop()
        XCTAssertGreaterThan(collector.drain().lags.count, 0)
    }

    func testDefaultLocations() {
        XCTAssertEqual(PerfProbe.logURL, DeckPaths.logs.appendingPathComponent("perf.log"))
        XCTAssertEqual(PerfProbe.markerURL, DeckPaths.logs.appendingPathComponent("perf.on"))
        XCTAssertEqual(PerfCollector.maxLines, 3000)
    }
}
