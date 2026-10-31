import XCTest
@testable import MonitorKit

/// 1 回あたりの重さ（claude は動かさない）。`CLAUDE_DECK_BENCH=1` の時だけ走らせ、中央値と p95 を出す。
final class PerfBenchTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["CLAUDE_DECK_BENCH"] == "1" else {
            throw XCTSkip("CLAUDE_DECK_BENCH=1 の時だけ走らせる")
        }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("perf-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - 測り方

    /// `body` を `runs` 回（先に 1 回の空回し）測り、中央値と p95 を出す。
    @discardableResult
    private func bench(_ name: String, runs: Int, _ body: () -> Void) -> (median: Double, p95: Double) {
        body()
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let p95 = samples[min(samples.count - 1, Int((Double(samples.count - 1) * 0.95).rounded()))]
        print(String(format: "PerfBench %@: median=%.3fms p95=%.3fms runs=%d", name, median, p95, runs))
        return (median, p95)
    }

    // MARK: - 一覧の作り直し

    /// ChatModel.buildRooms と同じ走査（feed から最新の行と未読数・並べ替えの鍵・見出しの組み分け・プロジェクトへの振り分け）の代用。
    func testPerfBenchRoomListRebuildEquivalent() {
        for roomCount in [1, 5, 10] {
            let sessionIds = (0..<roomCount).map { "session-\($0)" }
            let kinds: [FeedKind] = [.tool, .message, .prompt, .status]
            let feed = (0..<500).map { index in
                FeedItem(id: index, sessionId: sessionIds[index % roomCount], project: "p\(index % roomCount)",
                         at: 1_760_000_000_000 + Double(index) * 1000, kind: kinds[index % kinds.count],
                         text: "ツールを実行しました \(index) " + String(repeating: "x", count: 60), tool: "Bash", local: nil)
            }
            let projects = (0..<roomCount).map { ManagedProject(name: "p\($0)", path: "/tmp/bench/p\($0)") }
            let lastSeen = Dictionary(uniqueKeysWithValues: sessionIds.map { ($0, 1_760_000_100_000.0) })
            bench("roomList rooms=\(roomCount) feed=500", runs: 200) {
                var latestLine: [String: String] = [:]
                for item in feed where !item.text.isEmpty { latestLine[item.sessionId] = item.text }
                let unread = RoomGrouping.unreadCounts(feed: feed, since: lastSeen, defaultSince: 0)
                let keys = sessionIds.enumerated().map { index, id in
                    RoomKey(id: "e:\(id)", name: "p\(index)", status: index % 2 == 0 ? .working : .idle,
                            activityAt: 1_760_000_000_000 + Double(index),
                            searchText: ["main", "タイトル", latestLine[id] ?? "", "/tmp/bench/p\(index)"].joined(separator: " "))
                }
                let entries = RoomGrouping.entries(RoomGrouping.group(keys, query: ""))
                let dirs = ProjectDirectories.directories(projects: projects, rooms: keys.enumerated().map {
                    ProjectRoomKey(key: $1, cwd: "/tmp/bench/p\($0)")
                })
                XCTAssertEqual(entries.count >= roomCount, true)
                XCTAssertEqual(dirs.count, roomCount)
                XCTAssertFalse(unread.isEmpty)
            }
        }
    }

    // MARK: - 会話の組み立て

    func testPerfBenchChatTimelineEntries() {
        for count in [500, 2000, 5000] {
            let items = (0..<count).map { index -> TranscriptItem in
                switch index % 4 {
                case 0: return TranscriptItem(id: "u\(index)", kind: .user, at: Double(index), text: "依頼 \(index)", tool: nil, parentId: nil)
                case 1: return TranscriptItem(id: "a\(index)", kind: .assistant, at: Double(index),
                                              text: String(repeating: "返答の本文。", count: 40), tool: nil, parentId: "u\(index - 1)")
                default: return TranscriptItem(id: "t\(index)", kind: .tool, at: Double(index), text: nil,
                                               tool: TranscriptTool(name: "Bash", description: "ls", target: nil), parentId: "a\(index - 1)")
                }
            }
            bench("chatTimeline items=\(count)", runs: 100) {
                XCTAssertFalse(ChatTimeline.entries(from: items, notes: [], pending: []).isEmpty)
            }
        }
    }

    // MARK: - 画面判定

    /// 0.3 秒ごとに 1 セッション分で回る判定一式（mainPane・権限・メニュー・上限表示）。
    func testPerfBenchScreenEvaluation() throws {
        let menu = try ScreenFixture.load("r1-app-01").map { String($0.prefix(160)) }
        var busy = (0..<34).map { index in
            "  ⏺ 出力の行 \(index) " + String(repeating: "abcdefghij", count: 14)
        }
        busy += ["", "✻ Working… (12s · esc to interrupt)", String(repeating: "─", count: 160), "> ",
                 String(repeating: "─", count: 160), "  ? for shortcuts"]
        for (name, screen) in [("menu", menu), ("busy", busy)] {
            let padded = (screen + Array(repeating: "", count: max(0, 40 - screen.count))).prefix(40).map { $0 }
            bench("screenEvaluation \(name) 40x160", runs: 500) {
                let pane = TerminalScreen.mainPane(padded)
                let prompt = PermissionPrompt.parse(screen: pane)
                let showing = prompt == nil && ChoiceMenu.isShowing(screen: pane)
                _ = LimitGuard.screenLimitLine(padded)
                _ = showing
            }
        }
    }

    // MARK: - ログの読み

    private static func toolResultLine(uuid: String, bytes: Int) -> String {
        let body = String(repeating: "r", count: bytes)
        return #"{"type":"user","uuid":"\#(uuid)","timestamp":"2026-10-31T00:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_\#(uuid)","content":"\#(body)"}]}}"#
    }

    private static func assistantLine(uuid: String, index: Int) -> String {
        #"{"type":"assistant","uuid":"\#(uuid)","timestamp":"2026-10-31T00:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"返答 \#(index) \#(String(repeating: "text ", count: 80))"},{"type":"tool_use","id":"toolu_\#(index)","name":"Bash","input":{"command":"ls -la","description":"一覧"}}]}}"#
    }

    private static func userLine(uuid: String, index: Int) -> String {
        #"{"type":"user","uuid":"\#(uuid)","timestamp":"2026-10-31T00:00:00.000Z","message":{"role":"user","content":"依頼 \#(index)"}}"#
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// 実況層の差分読み（1MB の tool_result 行を含む追記）。
    func testPerfBenchTranscriptReaderAppend() throws {
        let url = dir.appendingPathComponent("reader.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        try append((0..<200).map { Self.assistantLine(uuid: "a\($0)", index: $0) }, to: url)
        let reader = TranscriptReader(path: url.path)
        _ = reader.read()
        var serial = 0
        var samples: [Double] = []
        for _ in 0..<30 {
            serial += 1
            try append([Self.toolResultLine(uuid: "r\(serial)", bytes: 1_000_000),
                        Self.assistantLine(uuid: "a-\(serial)", index: serial),
                        Self.userLine(uuid: "u-\(serial)", index: serial)], to: url)
            let start = DispatchTime.now().uptimeNanoseconds
            XCTAssertFalse(reader.read().isEmpty)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        samples.sort()
        print(String(format: "PerfBench transcriptReader append=1MB tool_result+2 lines: median=%.3fms p95=%.3fms runs=%d",
                     samples[samples.count / 2], samples[Int((Double(samples.count - 1) * 0.95).rounded())], samples.count))
    }

    /// ルームを開いた時の全件読み（合成した 50MB）と、初回のメタ読み。
    func testPerfBenchTranscriptLogFullRead() throws {
        let url = dir.appendingPathComponent("full.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        var written = 0
        var index = 0
        while written < 50 * 1024 * 1024 {
            var lines: [String] = []
            for _ in 0..<50 {
                index += 1
                lines.append(Self.userLine(uuid: "u\(index)", index: index))
                lines.append(Self.assistantLine(uuid: "a\(index)", index: index))
                lines.append(Self.toolResultLine(uuid: "r\(index)", bytes: index % 10 == 0 ? 200_000 : 4_000))
            }
            try append(lines, to: url)
            written += lines.reduce(0) { $0 + $1.utf8.count + 1 }
        }
        let megabytes = written / 1024 / 1024
        bench("transcriptLog fullRead \(megabytes)MB", runs: 5) {
            let log = TranscriptLog(path: url.path)
            XCTAssertFalse(log.read().isEmpty)
        }
        bench("primeMeta \(megabytes)MB", runs: 5) {
            _ = TranscriptTail.primeMeta(path: url.path)
        }
    }
}
