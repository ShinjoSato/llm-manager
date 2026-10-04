import XCTest
@testable import MonitorKit

// 移植元: 旧 monitor（削除済み）の test/transcriptApi.test.ts・transcriptImages.test.ts と同じ観点。
final class TranscriptFormatTests: XCTestCase {
    typealias F = FakeClaudeHome
    let at = millis(FakeClaudeHome.timestamp)

    private func obj(_ line: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
    }

    private func items(_ line: String, _ key: String = "lineX", parent: inout String?) -> [TranscriptItem] {
        TranscriptFormat.items(fromLine: obj(line), lineKey: key, parentId: &parent)
    }

    private func items(_ line: String, _ key: String = "lineX") -> [TranscriptItem] {
        var parent: String?
        return items(line, key, parent: &parent)
    }

    func testLineShapes() {
        var parent: String?
        let prompt = items(F.user("u1", "こんにちは"), "line1", parent: &parent)
        XCTAssertEqual(prompt, [TranscriptItem(id: "u1:0", kind: .user, at: at, text: "こんにちは", tool: nil, parentId: nil, images: [])])
        XCTAssertEqual(parent, "u1:0")

        let tool = items(F.assistant("a1", [["type": "tool_use", "name": "Read", "input": ["file_path": "/x/a.ts"]]]), "line2", parent: &parent)
        XCTAssertEqual(tool.first?.parentId, "u1:0", "応答前のツールはプロンプトにぶら下がる")
        XCTAssertEqual(tool.first?.tool, TranscriptTool(name: "Read", description: nil, target: "/x/a.ts"))

        let text = items(F.assistant("a2", [["type": "text", "text": " 読みました "]]), "line3", parent: &parent)
        XCTAssertEqual(text.first?.kind, .assistant)
        XCTAssertEqual(text.first?.text, "読みました")
        let next = items(F.assistant("a3", [["type": "tool_use", "name": "Bash", "input": ["command": "ls\npwd", "description": "一覧"]]]), "line4", parent: &parent)
        XCTAssertEqual(next.first?.parentId, "a2:0")
        XCTAssertEqual(next.first?.tool, TranscriptTool(name: "Bash", description: "一覧", target: "ls"))

        let multi = items(F.assistant("a4", [["type": "thinking", "thinking": ""], ["type": "text", "text": "A"],
                                              ["type": "tool_use", "name": "Glob", "input": ["pattern": "*.ts"]]]), "line5")
        XCTAssertEqual(multi.map(\.id), ["a4:1", "a4:2"])
        XCTAssertEqual(multi.map(\.kind), [.assistant, .tool])
        XCTAssertEqual(multi.map(\.parentId), [nil, "a4:1"])
    }

    func testSkippedLines() {
        XCTAssertTrue(items(F.user("u", [["type": "tool_result", "tool_use_id": "x", "content": "ok"]])).isEmpty)
        XCTAssertTrue(items(F.user("u", "meta", extra: ["isMeta": true])).isEmpty)
        XCTAssertTrue(items(F.user("u", "<system-reminder>x</system-reminder>")).isEmpty)
        XCTAssertTrue(items(F.user("u", "hi", extra: ["isSidechain": true])).isEmpty)
        XCTAssertTrue(items(F.user("u", "summary", extra: ["isCompactSummary": true])).isEmpty)
        XCTAssertTrue(items(F.assistant("a", [["type": "thinking", "thinking": "..."]])).isEmpty)
        XCTAssertTrue(items(F.user("u", "   ")).isEmpty)
        XCTAssertTrue(items(F.json(["type": "system", "message": ["content": "x"]])).isEmpty)
        XCTAssertFalse(items(F.user("u", "hi", extra: ["isMeta": 1])).isEmpty, "isMeta は真偽値の true の時だけ")
    }

    func testCommandsAndImages() {
        let cmd = items(F.user("u", "<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>42</command-args>"))
        XCTAssertEqual(cmd.first?.text, "/review 42")
        let img = items(F.user("u", [["type": "text", "text": "これ見て"], ["type": "image", "source": [:] as [String: Any]]]))
        XCTAssertEqual(img.first?.text, "これ見て\n[画像]")
        let noUuid = items(F.json(["type": "user", "message": ["content": "x"]]), "line7")
        XCTAssertEqual(noUuid.first?.id, "line7:0")
        XCTAssertNil(noUuid.first?.at)
    }

    func testSummarizeTool() {
        XCTAssertEqual(TranscriptFormat.summarizeTool(name: "Grep", input: ["pattern": "foo", "path": "src"]).target, "foo (src)")
        XCTAssertEqual(TranscriptFormat.summarizeTool(name: "Skill", input: ["skill": "developer-plugin:dev-done"]).target, "developer-plugin:dev-done")
        XCTAssertEqual(TranscriptFormat.summarizeTool(name: "Agent", input: ["subagent_type": "Explore", "description": "探す"]),
                       TranscriptTool(name: "Agent", description: "探す", target: "Explore"))
        XCTAssertEqual(TranscriptFormat.summarizeTool(name: "TodoWrite", input: nil), TranscriptTool(name: "TodoWrite", description: nil, target: nil))
        XCTAssertEqual(TranscriptFormat.summarizeTool(name: "Bash", input: ["command": String(repeating: "x", count: 500)]).target?.count, 301)
    }

    func testIdsAndImageCatalog() {
        XCTAssertTrue(TranscriptFormat.isValidSessionId("9c5a73ea-48db-4aef-9ca5-a772f22c89a0"))
        XCTAssertFalse(TranscriptFormat.isValidSessionId("../etc"))
        XCTAssertFalse(TranscriptFormat.isValidSessionId(""))
        XCTAssertTrue(TranscriptFormat.isValidItemId("9ebe6f6b-8bb4-4b6f-ae38-23c465ae94a0:0"))
        XCTAssertTrue(TranscriptFormat.isValidItemId("line12:0"))
        XCTAssertFalse(TranscriptFormat.isValidItemId("abc"))
        XCTAssertFalse(TranscriptFormat.isValidItemId("../x:0"))

        let content: [Any] = [F.image("image/png", F.png), ["type": "text", "text": "コンフリクトしてる"],
                              F.image("image/svg+xml", Data("<svg/>".utf8)),
                              ["type": "image", "source": ["type": "url", "url": "https://example.com/a.png"]],
                              F.image("image/jpeg", F.jpeg)]
        XCTAssertEqual(TranscriptFormat.images(of: content), [TranscriptImage(index: 0, mediaType: "image/png"),
                                                              TranscriptImage(index: 3, mediaType: "image/jpeg")])
        XCTAssertEqual(TranscriptFormat.images(of: "hi"), [])
        XCTAssertEqual(TranscriptFormat.imageData(of: content, index: 0)?.data, F.png)
        XCTAssertNil(TranscriptFormat.imageData(of: content, index: 1), "SVG は返さない")
        XCTAssertNil(TranscriptFormat.imageData(of: content, index: 2), "base64 以外は返さない")
        XCTAssertNil(TranscriptFormat.imageData(of: content, index: 9))

        let item = items(F.user("u1", content), "line1").first
        XCTAssertEqual(item?.images.map(\.index), [0, 3])
        XCTAssertEqual(item?.text, "[画像]\nコンフリクトしてる\n[画像]\n[画像]\n[画像]")
        let encoded = try! JSONEncoder().encode(item!)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(F.png.base64EncodedString()), "本文に base64 を流さない")
        XCTAssertTrue(items(F.user("u3", [["type": "tool_result", "tool_use_id": "x", "content": [F.pngBlock]]])).isEmpty)
    }
}

final class TranscriptLogTests: XCTestCase {
    typealias F = FakeClaudeHome
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func append(_ url: URL, _ text: String) throws { try append(url, Data(text.utf8)) }

    private func append(_ url: URL, _ data: Data) throws { try appendToFile(data, at: url) }

    func testIncrementalReadAndSince() throws {
        let url = dir.appendingPathComponent("s1.jsonl")
        try append(url, "\(F.user("u1", "一つ目"))\n\(F.json(["type": "attachment"]))\n\(F.assistant("a1", [["type": "text", "text": "はい"]]))\n")
        let log = TranscriptLog(path: url.path)
        XCTAssertEqual(log.read().map(\.id), ["u1:0", "a1:0"])
        XCTAssertEqual(log.read().count, 0)

        // 書きかけの行は持ち越し、書き終わってから出す（マルチバイトの途中で切っても壊れない）。
        let half = Data(F.user("u2", "二つ目 🎉").utf8)
        let cut = half.range(of: Data("🎉".utf8))!.lowerBound + 2
        try append(url, half.prefix(cut))
        XCTAssertEqual(log.read().count, 0)
        try append(url, half.suffix(from: cut) + Data("\n".utf8))
        XCTAssertEqual(log.read().map(\.text), ["二つ目 🎉"])

        XCTAssertEqual(log.since(nil).items.count, 3)
        XCTAssertEqual(log.since("a1:0").items.map(\.id), ["u2:0"])
        XCTAssertTrue(log.since("u2:0").items.isEmpty)
        XCTAssertEqual(log.since("nope").items.count, 3)
        XCTAssertTrue(log.since("nope").reset)
    }

    func testStoreSubscriptionAndGet() async throws {
        let url = dir.appendingPathComponent("s1.jsonl")
        try append(url, "\(F.user("u1", "一つ目"))\n\(F.user("u2", "二つ目"))\n")
        let store = TranscriptStore(resolve: { id, _ in id == "s1" ? url.path : nil })
        await store.setKnown([.init(sessionId: "s1", cwd: dir.path)])
        let events = Box<[TranscriptEvent]>([])
        let off = await store.subscribe(.sessions(["s1"])) { e in events.mutate { $0.append(e) } }
        XCTAssertNotNil(off)
        XCTAssertTrue(events.value.isEmpty, "購読時点までは既読扱い")

        try append(url, "\(F.assistant("a2", [["type": "tool_use", "name": "Edit", "input": ["file_path": "/p/q.ts"]]]))\n")
        await store.poll()
        XCTAssertEqual(events.value.map(\.sessionId), ["s1"])
        XCTAssertEqual(events.value.first?.items.map(\.id), ["a2:0"])
        XCTAssertEqual(events.value.first?.items.first?.parentId, "u2:0")

        try append(url, "\(F.user("u3", "三つ目"))\n")
        let got = await store.get("s1", after: "a2:0")
        XCTAssertEqual(got?.items.map(\.id), ["u3:0"])
        XCTAssertEqual(events.value.last?.items.map(\.id), ["u3:0"], "取得で読んだ分も購読者に届く")
        let none = await store.get("s2")
        XCTAssertNil(none)
        let invalid = await store.get("a..b")
        XCTAssertNil(invalid)

        let others = Box<[TranscriptEvent]>([])
        let all = await store.subscribe(.all) { e in others.mutate { $0.append(e) } }
        let other = await store.subscribe(.sessions(["zzz"])) { _ in XCTFail("別セッションの購読者に届いてはいけない") }
        let invalidSubscription = await store.subscribe(.sessions(["../x"])) { _ in }
        XCTAssertNil(invalidSubscription, "不正な id しか無ければ購読しない")
        try append(url, "\(F.assistant("a3", [["type": "text", "text": "完了"]]))\n")
        await store.poll()
        XCTAssertEqual(others.value.map { $0.items.map(\.id) }, [["a3:0"]])
        for id in [off, all, other].compactMap({ $0 }) { await store.unsubscribe(id) }
        try append(url, "\(F.user("u4", "四つ目"))\n")
        await store.poll()
        XCTAssertEqual(events.value.count, 3)
        XCTAssertEqual(others.value.count, 1)
        await store.stop()
    }

    func testImagesAreReadBackByByteOffset() throws {
        let url = dir.appendingPathComponent("s1.jsonl")
        // 先に日本語・絵文字の行を置き、バイト位置の計算がずれないことを確かめる。
        try append(url, "\(F.user("u0", "前置き 🎉 日本語"))\n\(F.json(["type": "attachment"]))\n")
        let log = TranscriptLog(path: url.path)
        _ = log.read()
        try append(url, "\(F.user("u1", [F.image("image/png", F.png), ["type": "text", "text": "見て"], F.image("image/jpeg", F.jpeg)]))\n")
        let half = F.user("u2", [F.pngBlock])
        try append(url, String(half.prefix(40)))
        XCTAssertEqual(log.read().map { "\($0.id):\($0.images.count)" }, ["u1:0:2"])
        try append(url, "\(half.dropFirst(40))\n\(F.assistant("a1", [["type": "text", "text": "了解 ✅"]]))\n")
        _ = log.read()
        XCTAssertEqual(log.image(itemId: "u1:0", index: 0)?.data, F.png)
        XCTAssertEqual(log.image(itemId: "u1:0", index: 1), TranscriptImageData(mediaType: "image/jpeg", data: F.jpeg))
        XCTAssertEqual(log.image(itemId: "u2:0", index: 0)?.data, F.png, "書きかけを跨いだ行も取り出せる")
        XCTAssertNil(log.image(itemId: "u0:0", index: 0))
        XCTAssertNil(log.image(itemId: "zz:0", index: 0))

        // 位置がずれていたら uuid で探し直し、覚え直す。
        let broken = TranscriptLog(path: url.path)
        _ = broken.read()
        broken.imageLines["u2:0"] = .init(offset: 0, length: 10, uuid: "u2")
        XCTAssertEqual(broken.image(itemId: "u2:0", index: 0)?.data, F.png)
        XCTAssertGreaterThan(broken.imageLines["u2:0"]!.offset, 0)
        broken.clearDecoded()
        let before = broken.lineReads
        _ = broken.image(itemId: "u2:0", index: 0)
        XCTAssertEqual(broken.lineReads - before, 1)

        // 同じ発話の複数枚は 1 回の読み込みで返す。
        let multi = TranscriptLog(path: url.path)
        _ = multi.read()
        _ = multi.image(itemId: "u1:0", index: 0)
        _ = multi.image(itemId: "u1:0", index: 1)
        _ = multi.image(itemId: "u1:0", index: 0)
        XCTAssertEqual(multi.lineReads, 1)
    }

    func testDecodedImagesAreLRU() throws {
        let url = dir.appendingPathComponent("s.jsonl")
        try append(url, (0..<6).map { F.user("r\($0)", [F.pngBlock]) }.joined(separator: "\n") + "\n")
        let log = TranscriptLog(path: url.path)
        _ = log.read()
        for i in 0..<6 { _ = log.image(itemId: "r\(i):0", index: 0) }
        XCTAssertEqual(log.decodedOrder, ["r2:0", "r3:0", "r4:0", "r5:0"])
        _ = log.image(itemId: "r3:0", index: 0)
        _ = log.image(itemId: "r0:0", index: 0)
        XCTAssertEqual(log.decodedOrder, ["r4:0", "r5:0", "r3:0", "r0:0"])
        XCTAssertEqual(log.lineReads, 7)
        XCTAssertEqual(log.decodedBytes, F.png.count * 4)
    }

    func testInvalidUTF8DoesNotShiftOffsets() throws {
        let url = dir.appendingPathComponent("s.jsonl")
        var bad = Data(#"{"type":"attachment","x":""#.utf8)
        bad.append(contentsOf: [0xff, 0xfe, 0xc3])
        bad.append(Data("\"}\n".utf8))
        try append(url, bad + Data("\(F.user("v1", [F.pngBlock]))\n".utf8))
        let log = TranscriptLog(path: url.path)
        _ = log.read()
        XCTAssertEqual(log.imageLines["v1:0"]?.offset, bad.count, "行の位置はバイトで数える")
        XCTAssertEqual(log.image(itemId: "v1:0", index: 0)?.data, F.png)
        XCTAssertEqual(log.lineReads, 1)

        let url2 = dir.appendingPathComponent("t.jsonl")
        try append(url2, bad + Data("\(F.json(["type": "user", "message": ["role": "user", "content": [F.pngBlock]]]))\n".utf8))
        let noUuid = TranscriptLog(path: url2.path)
        _ = noUuid.read()
        XCTAssertEqual(noUuid.image(itemId: "line2:0", index: 0)?.data, F.png)
        noUuid.clearDecoded()
        noUuid.imageLines["line2:0"] = .init(offset: 0, length: bad.count - 1, uuid: nil)
        XCTAssertNil(noUuid.image(itemId: "line2:0", index: 0), "uuid の無い行は位置がずれたら取り違えを避ける")
    }
}

/// 壊れ気味の値でも落ちない・行を失わない。
final class TranscriptRobustnessTests: XCTestCase {
    typealias F = FakeClaudeHome

    func testTokenCountsOutOfRangeDoNotTrap() {
        let ev = TranscriptTail.parse(["type": "assistant", "message": ["content": [] as [Any], "usage": [
            "input_tokens": 1e20, "output_tokens": Double.nan, "cache_read_input_tokens": -3,
        ] as [String: Any]]])
        XCTAssertEqual(ev.usage, TokenUsage(input: Int.max, output: 0, cacheRead: 0))
        let strings = TranscriptTail.parse(["type": "assistant", "message": ["content": [] as [Any], "usage": [
            "input_tokens": "1e400", "output_tokens": "-1e30", "cache_read_input_tokens": "12",
        ] as [String: Any]]])
        XCTAssertEqual(strings.usage, TokenUsage(input: 0, output: 0, cacheRead: 12))
        XCTAssertEqual(JSONLoose.clampedInt(-1e300), Int.min)
        XCTAssertEqual(JSONLoose.clampedInt(.infinity), 0)
        XCTAssertEqual(JSONLoose.clampedInt(.nan), 0)
        XCTAssertEqual(JSONLoose.clampedInt(42.9), 42)
        // ログの数値は JSON の上でも範囲外になりうる。
        let line = #"{"type":"assistant","message":{"content":[],"usage":{"input_tokens":1e20,"output_tokens":-5,"cache_read_input_tokens":99999999999999999999999}}}"#
        XCTAssertEqual(TranscriptTail.parseLine(Array(line.utf8))?.usage, TokenUsage(input: Int.max, output: 0, cacheRead: Int.max))
    }

    func testLoneSurrogatesAreReplacedInsteadOfDroppingTheLine() throws {
        func text(_ json: String) -> String? { (JSONLoose.object(Array(json.utf8)) as? [String: Any])?["a"] as? String }
        XCTAssertEqual(text(#"{"a":"x\ud83dy"}"#), "x\u{FFFD}y")
        XCTAssertEqual(text(#"{"a":"\udc00"}"#), "\u{FFFD}")
        XCTAssertEqual(text(#"{"a":"\ud83d\ud83d"}"#), "\u{FFFD}\u{FFFD}")
        XCTAssertEqual(text(#"{"a":"\uD83DA"}"#), "\u{FFFD}A")
        XCTAssertEqual(text(#"{"a":"😀"}"#), "😀", "対になっていればそのまま")
        XCTAssertEqual(text(#"{"a":"\\ud83d"}"#), #"\ud83d"#, "エスケープされた \\ の後ろはただの文字")
        XCTAssertNil(JSONLoose.object(Array(#"{"a":"\ud83d"#.utf8)), "壊れた JSON は救わない")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sur-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.jsonl")
        let cut = #"{"type":"assistant","uuid":"a1","timestamp":"2026-06-01T00:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"途中で切れた\ud83d"}]}}"#
        try Data((cut + "\n").utf8).write(to: url)
        let log = TranscriptLog(path: url.path)
        XCTAssertEqual(log.read().map(\.text), ["途中で切れた\u{FFFD}"], "その行を会話から落とさない")
        XCTAssertEqual(TranscriptTail.parseLine(Array(cut.utf8))?.text, "途中で切れた\u{FFFD}")
    }

    /// 購読の差し替えは 1 回の呼び出しで行い、間に書かれた追記を落とさない。
    func testReplacingSubscriptionKeepsAppends() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = ["s1", "s2"].map { dir.appendingPathComponent("\($0).jsonl") }
        for (i, url) in urls.enumerated() { try Data("\(F.user("u0-\(i)", "最初"))\n".utf8).write(to: url) }
        let store = TranscriptStore(resolve: { id, _ in urls.first { $0.lastPathComponent == "\(id).jsonl" }?.path })
        let events = Box<[TranscriptEvent]>([])
        let first = await store.subscribe(.sessions(["s1"])) { e in events.mutate { $0.append(e) } }
        let handle = try FileHandle(forWritingTo: urls[0])
        handle.seekToEndOfFile()
        handle.write(Data("\(F.user("u1", "差し替えの直前"))\n".utf8))
        try handle.close()
        let second = await store.subscribe(.sessions(["s1", "s2"]), replacing: first) { e in events.mutate { $0.append(e) } }
        XCTAssertEqual(events.value.flatMap { $0.items.map(\.id) }, ["u1:0"], "差し替え前の購読に届く")
        XCTAssertFalse(events.value.contains { $0.sessionId == "s2" }, "新しく加えた分の既存の行は既読扱い")
        let count = await store.subscriberCount
        XCTAssertEqual(count, 1)
        let cleared = await store.subscribe(.none, replacing: second) { _ in }
        XCTAssertNil(cleared)
        let none = await store.subscriberCount
        XCTAssertEqual(none, 0)
        await store.stop()
    }

    /// 購読していないログは上限を超えたら手放す。
    func testUnwatchedLogsAreBounded() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lru-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptStore(resolve: { id, _ in dir.appendingPathComponent("\(id).jsonl").path })
        for i in 0..<(TranscriptStore.maxLogs + 4) {
            let id = "s\(i)"
            try Data("\(F.user("u\(i)", "x"))\n".utf8).write(to: dir.appendingPathComponent("\(id).jsonl"))
            _ = await store.get(id)
        }
        let count = await store.logCount
        XCTAssertEqual(count, TranscriptStore.maxLogs)
    }
}

/// 試験で非同期の受け口から値を集める箱。
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&stored) } }
}
