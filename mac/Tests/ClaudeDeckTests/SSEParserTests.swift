import XCTest
@testable import MonitorKit

final class SSEParserTests: XCTestCase {
    private func parse(_ chunks: [String]) -> [SSEEvent] {
        var parser = SSEParser()
        return chunks.flatMap { parser.feed(Array($0.utf8)) }
    }

    func testBasicEvent() {
        let events = parse(["event: sessions\ndata: []\n\n"])
        XCTAssertEqual(events, [SSEEvent(event: "sessions", data: "[]")])
    }

    func testDefaultEventNameAndMultilineData() {
        let events = parse(["data: a\ndata: b\n\n"])
        XCTAssertEqual(events, [SSEEvent(event: "message", data: "a\nb")])
    }

    func testChunkBoundariesAnywhere() {
        let whole = "event: feed\ndata: {\"x\":\"日本語\"}\n\nevent: usage\ndata: null\n\n"
        let bytes = Array(whole.utf8)
        // 1 バイトずつ流しても（マルチバイト文字の途中で切れても）同じ結果になる。
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for b in bytes { events += parser.feed([b]) }
        XCTAssertEqual(events, [SSEEvent(event: "feed", data: "{\"x\":\"日本語\"}"), SSEEvent(event: "usage", data: "null")])
    }

    func testCRLFAndCRLineEndings() {
        XCTAssertEqual(parse(["event: a\r\ndata: 1\r\n\r\n"]), [SSEEvent(event: "a", data: "1")])
        XCTAssertEqual(parse(["event: a\rdata: 1\r\r"]), [SSEEvent(event: "a", data: "1")])
        // CR と LF がチャンクをまたいでも空行と誤認しない。
        XCTAssertEqual(parse(["event: a\r", "\ndata: 1\r", "\n\r", "\n"]), [SSEEvent(event: "a", data: "1")])
    }

    func testCommentsAndUnknownFieldsIgnored() {
        XCTAssertEqual(parse([": keepalive\nfoo: bar\ndata: x\n\n"]), [SSEEvent(event: "message", data: "x")])
    }

    func testNoSpaceAfterColonAndEmptyData() {
        XCTAssertEqual(parse(["event:x\ndata:1\n\ndata\n\n"]),
                       [SSEEvent(event: "x", data: "1"), SSEEvent(event: "message", data: "")])
    }

    func testBlankLineWithoutDataDoesNotDispatchAndResetsEventName() {
        XCTAssertEqual(parse(["event: a\n\ndata: 1\n\n"]), [SSEEvent(event: "message", data: "1")])
    }

    func testIncompleteEventIsHeldUntilBlankLine() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed(Array("event: a\ndata: 1\n".utf8)), [])
        XCTAssertEqual(parser.feed(Array("\n".utf8)), [SSEEvent(event: "a", data: "1")])
    }

    func testIdAndRetry() {
        var parser = SSEParser()
        let events = parser.feed(Array("id: 7\nretry: 3000\nretry: abc\ndata: x\n\n".utf8))
        XCTAssertEqual(events, [SSEEvent(event: "message", data: "x", id: "7")])
        XCTAssertEqual(parser.retryMillis, 3000)
    }

    func testLeadingBOMIsStripped() {
        XCTAssertEqual(parse(["\u{FEFF}event: a\ndata: 1\n\n"]), [SSEEvent(event: "a", data: "1")])
    }
}
