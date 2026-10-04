import XCTest
import DeckCore

final class TranscriptBufferTests: XCTestCase {
    private func item(_ id: String, _ kind: TranscriptItemKind = .assistant, parent: String? = nil) -> TranscriptItem {
        TranscriptItem(id: id, kind: kind, at: nil, text: id, tool: kind == .tool ? TranscriptTool(name: "Bash", description: nil, target: "ls") : nil,
                       parentId: parent)
    }

    private func response(_ ids: [String], reset: Bool = false) -> TranscriptResponse {
        TranscriptResponse(sessionId: "s", items: ids.map { item($0) }, reset: reset)
    }

    func testFullFetchThenSSEDeduplicates() {
        var buffer = TranscriptBuffer()
        buffer.beginFetch()
        buffer.apply(response(["a", "b"]), fullReplace: true)
        buffer.append([item("b"), item("c")])
        XCTAssertEqual(buffer.items.map(\.id), ["a", "b", "c"])
    }

    func testSSEDuringFetchIsKeptAfterResponseOrder() {
        var buffer = TranscriptBuffer()
        buffer.beginFetch()
        // GET の応答より先に SSE が届いた（d は GET に含まれない新しい分、c は両方に含まれる）。
        buffer.append([item("c"), item("d")])
        buffer.apply(response(["a", "b", "c"]), fullReplace: true)
        XCTAssertEqual(buffer.items.map(\.id), ["a", "b", "c", "d"])
    }

    func testDeltaFetchAppendsAfterExisting() {
        var buffer = TranscriptBuffer()
        buffer.apply(response(["a", "b"]), fullReplace: true)
        buffer.beginFetch()
        buffer.append([item("d")])
        buffer.apply(response(["c", "d"]), fullReplace: false)
        XCTAssertEqual(buffer.items.map(\.id), ["a", "b", "c", "d"])
    }

    func testResetReplacesEverything() {
        var buffer = TranscriptBuffer()
        buffer.apply(response(["a", "b"]), fullReplace: true)
        buffer.beginFetch()
        buffer.apply(response(["x", "y"], reset: true), fullReplace: false)
        XCTAssertEqual(buffer.items.map(\.id), ["x", "y"])
        buffer.append([item("a")])
        XCTAssertEqual(buffer.items.map(\.id), ["x", "y", "a"], "置き換え後は古い id を重複扱いしない")
    }
}
