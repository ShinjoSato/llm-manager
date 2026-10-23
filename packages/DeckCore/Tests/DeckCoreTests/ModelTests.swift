import XCTest
@testable import DeckCore

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

    /// 終了の印は省略できる（古い mac は送らず、古い iPhone は読み飛ばす）。
    func testMenuOptionExitsIsOptional() throws {
        let old = #"{"menuId":"m","context":[],"question":"Trust?","cursor":0,"footer":"","isMultiSelect":false,"isReview":false,"cancelExits":true,"options":[{"index":0,"number":null,"label":"No, exit","detail":[],"isSubmit":false,"selectable":true}]}"#
        let fromOldMac = try decode(RemoteMenu.self, old)
        XCTAssertNil(fromOldMac.options[0].exits)
        XCTAssertFalse(fromOldMac.choiceExits(0), "印が無ければ押す前には確かめない（mac に断られてから確かめる）")

        let new = old.replacingOccurrences(of: #""selectable":true}"#, with: #""selectable":true,"exits":true}"#)
        let fromNewMac = try decode(RemoteMenu.self, new)
        XCTAssertEqual(fromNewMac.options[0].exits, true)
        XCTAssertTrue(fromNewMac.choiceExits(0))
        XCTAssertFalse(fromNewMac.choiceExits(1), "無い位置は終了ではない")
        XCTAssertEqual(fromNewMac.label(of: 0), "No, exit")
        XCTAssertNil(fromNewMac.label(of: 1))

        let encoded = String(decoding: try JSONEncoder().encode(fromOldMac), as: UTF8.self)
        XCTAssertFalse(encoded.contains("exits\""), "印が無ければ鍵ごと出さない")
        XCTAssertEqual(try decode(RemoteMenu.self, String(decoding: try JSONEncoder().encode(fromNewMac), as: UTF8.self)), fromNewMac)
    }

    func testRemainingPercentage() {
        XCTAssertEqual(UsageWindow(usedPercentage: 35.5, resetsAt: nil).remainingPercentage, 64.5, accuracy: 0.001)
        XCTAssertEqual(UsageWindow(usedPercentage: 120, resetsAt: nil).remainingPercentage, 0)
    }
}

final class RemotePairingPayloadTests: XCTestCase {
    func testPairingPayloadRoundTripsThroughURL() {
        let payload = RemotePairingPayload(host: "192.168.1.5", port: 8767, token: "abc-_DEF", fingerprint: String(repeating: "ab", count: 32),
                                           name: "Shinjo の MacBook", expiresAt: 1_800_000_000_000, localHostName: "mac.local")
        XCTAssertEqual(payload.url.scheme, "claude-deck")
        XCTAssertEqual(RemotePairingPayload(url: payload.url), payload)
        var bad = URLComponents(url: payload.url, resolvingAgainstBaseURL: false)!
        bad.queryItems = bad.queryItems!.map { $0.name == "fp" ? URLQueryItem(name: "fp", value: "zz") : $0 }
        XCTAssertNil(RemotePairingPayload(url: bad.url!), "指紋の形が違えば読まない")
        XCTAssertNil(RemotePairingPayload(url: URL(string: "https://example.com/pair")!))
        XCTAssertEqual(RemotePinning.display("abcd"), "AB:CD")
        XCTAssertEqual(RemotePinning.normalize("AB:CD"), "abcd")
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(RemotePinning.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(RemotePinning.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(RemotePinning.constantTimeEqual(Data([1, 2]), Data([1, 2, 3])))
    }
}
