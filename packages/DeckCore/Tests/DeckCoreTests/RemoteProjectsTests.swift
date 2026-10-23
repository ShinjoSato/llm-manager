import XCTest
@testable import DeckCore

final class RemoteProjectsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testDecodesFullShape() throws {
        let json = """
        {"projects":[{"id":"A1","name":"mirio","status":"active","github":{"owner":"o","repo":"r","projectNumber":3},
          "links":[{"name":"LP","url":"https://mirio.example","kind":"dashboard","pinned":true,"note":"本番"}],
          "roomIds":["h:1","e:s2"]}]}
        """
        let list = try decode(RemoteProjectList.self, json)
        let project = try XCTUnwrap(list.project("A1"))
        XCTAssertEqual(project.status, .active)
        XCTAssertEqual(project.github?.label, "o/r #3")
        XCTAssertEqual(project.links, [RemoteProjectLink(name: "LP", url: "https://mirio.example", kind: .dashboard, pinned: true, note: "本番")])
        XCTAssertEqual(project.roomIds, ["h:1", "e:s2"])
    }

    /// 省いた項目・知らない値でも読める（mac が新しくなって値が増えても一覧ごと落とさない）。
    func testMissingAndUnknownValuesDecode() throws {
        let json = """
        {"projects":[{"id":"A","name":"x","status":"frozen","links":[{"name":"L","url":"https://a.example","kind":"video"}]},
                     {"id":"B","name":"y"}],"extra":1}
        """
        let list = try decode(RemoteProjectList.self, json)
        XCTAssertEqual(list.projects[0].status, .unknown)
        XCTAssertEqual(list.projects[0].links[0].kind, .other)
        XCTAssertFalse(list.projects[0].links[0].pinned)
        XCTAssertNil(list.projects[0].links[0].note)
        XCTAssertEqual(list.projects[0].roomIds, [])
        XCTAssertEqual(list.projects[1].links, [])
        XCTAssertEqual(list.projects[1].status, .unknown)
        XCTAssertEqual(try decode(RemoteProjectList.self, "{}").projects, [])
    }

    func testRoundTripOmitsMissingNote() throws {
        let link = RemoteProjectLink(name: "Docs", url: "https://docs.example/a", kind: .docs)
        let data = try JSONEncoder().encode(link)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["note"])
        XCTAssertEqual(try JSONDecoder().decode(RemoteProjectLink.self, from: data), link)
    }

    func testGitHubLabelSkipsMissingParts() {
        XCTAssertEqual(RemoteGitHubSummary(owner: "o").label, "o")
        XCTAssertEqual(RemoteGitHubSummary(owner: "o", projectNumber: 5).label, "o #5")
        XCTAssertEqual(RemoteGitHubSummary(owner: "o", repo: "r").label, "o/r")
    }

    func testOnlyWebLinksOpen() {
        XCTAssertEqual(WebLink.openableURL(" https://a.example/x ")?.absoluteString, "https://a.example/x")
        XCTAssertNotNil(WebLink.openableURL("http://192.168.1.2:3000"))
        XCTAssertNil(WebLink.openableURL("javascript:alert(1)"))
        XCTAssertNil(WebLink.openableURL("file:///etc/passwd"))
        XCTAssertNil(WebLink.openableURL("https://user:pw@a.example"))
        XCTAssertNil(WebLink.openableURL("https://"))
        XCTAssertNil(WebLink.openableURL("https://a.example/a b"))
        XCTAssertNil(WebLink.openableURL("tel:123"))
        XCTAssertEqual(RemoteProjectLink(name: "a", url: " https://a.example ").openableURL, WebLink.openableURL("https://a.example"))
        XCTAssertEqual(RemoteProjectLink(name: "a", url: "https://www.vercel.com/x").hostLabel, "vercel.com")
    }

    func testLinkSectionsPutPinsFirstAndSkipProjectsWithoutLinks() {
        let a = RemoteProject(id: "a", name: "A", status: .active, links: [
            RemoteProjectLink(name: "1", url: "https://1.example"),
            RemoteProjectLink(name: "2", url: "https://2.example", pinned: true),
            RemoteProjectLink(name: "3", url: "https://3.example"),
            RemoteProjectLink(name: "4", url: "https://4.example", pinned: true),
        ])
        let b = RemoteProject(id: "b", name: "B", status: .active)
        let c = RemoteProject(id: "c", name: "C", status: .paused, links: [RemoteProjectLink(name: "x", url: "https://x.example")])
        let list = RemoteProjectList(projects: [a, b, c])
        XCTAssertEqual(list.linkSections.map(\.id), ["a", "c"])
        XCTAssertEqual(list.linkSections[0].links.map(\.name), ["2", "4", "1", "3"])
        XCTAssertEqual(list.active.map(\.id), ["a", "b"])
        XCTAssertEqual(list.inactive.map(\.id), ["c"])
    }

    func testRoomsOfProjectFollowProjectOrderAndSkipVanished() {
        let project = RemoteProject(id: "p", name: "P", status: .active, roomIds: ["h:2", "e:gone", "h:1"])
        let rooms = ["h:1", "h:2", "h:3"].map { id in
            RemoteRoom(id: id, kind: .hosted, phase: .idle, name: id, branch: nil, status: .idle, line: "", activityAt: nil,
                       sessionId: nil, cwd: "", ended: nil, session: nil, permissions: [], terminalPermission: nil, menu: nil,
                       unreadableMenu: nil, busy: false, send: RemoteSendState(mode: .input, disabledReason: nil))
        }
        XCTAssertEqual(RemoteProjectList.rooms(of: project, in: rooms).map(\.id), ["h:2", "h:1"])
    }

    func testProjectsRequestAndOldMacDetection() throws {
        let req = try RemoteRequestBuilder(host: "192.168.1.5", port: 8767, token: "tok").projects()
        XCTAssertEqual(req.url?.absoluteString, "https://192.168.1.5:8767/v1/projects")
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertNil(req.httpBody)
        XCTAssertTrue(RemoteClientError.http(status: 404, error: "not_found", message: nil).isMissingEndpoint)
        XCTAssertFalse(RemoteClientError.http(status: 503, error: "unavailable", message: nil).isMissingEndpoint)
        XCTAssertFalse(RemoteClientError.decoding.isMissingEndpoint)
    }
}
