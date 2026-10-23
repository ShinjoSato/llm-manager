import XCTest
@testable import MonitorKit

/// `GET /v1/projects` の中身: 表示に要る分だけを送り、手元のパスや開けないリンクは送らない。
final class RemoteProjectsBuilderTests: XCTestCase {
    private func room(_ id: String, _ cwd: String, _ status: SessionStatus = .idle, at: Double? = nil) -> ProjectRoomKey {
        ProjectRoomKey(key: RoomKey(id: id, name: id, status: status, activityAt: at, searchText: ""), cwd: cwd)
    }

    private let secretPath = "/Users/someone/secret-folder/mirio"

    private func sampleProjects() -> [ManagedProject] {
        let links = [
            ProjectLink(name: "LP", url: "  https://mirio.example/  ", kind: .dashboard, pinned: true, note: "  本番  "),
            ProjectLink(name: "スクリプト", url: "javascript:alert(1)"),
            ProjectLink(name: "ファイル", url: "file:///etc/hosts"),
            ProjectLink(name: "資格情報", url: "https://user:pw@example.com"),
            ProjectLink(name: "  ", url: "https://no-name.example"),
            ProjectLink(name: "LP", url: "https://duplicate.example"),
            ProjectLink(name: "Docs", url: "http://docs.example/a", note: "   "),
        ]
        return [
            ManagedProject(name: "mirio", path: secretPath, status: .active, note: "手元のメモ",
                           github: GitHubLink(owner: "ShinjoSato", repo: "mirio", projectNumber: 4), links: links,
                           site: ProjectSite(path: "site"), xcode: .path("ios/App.xcodeproj"),
                           appStoreApps: [AppStoreAppLink(appId: "123", name: "本番")],
                           commands: [ProjectCommand(name: "build", command: "npm run build")]),
            ManagedProject(name: "old", path: "/Users/someone/old", status: .archived, github: GitHubLink(owner: " ")),
        ]
    }

    func testSendsDisplayFieldsInDirectoryOrder() throws {
        let projects = sampleProjects()
        let rooms = [room("h:a", secretPath, .working, at: 5), room("e:b", secretPath + "/ios", .permission, at: 1),
                     room("e:c", "/Users/someone/old", .stopped), room("e:x", "/elsewhere")]
        let list = RemoteProjectList(directories: ProjectDirectories.directories(projects: projects, rooms: rooms))
        XCTAssertEqual(list.projects.map(\.name), ["mirio", "old"])
        let mirio = list.projects[0]
        XCTAssertEqual(mirio.id, projects[0].id.uuidString)
        XCTAssertEqual(mirio.status, .active)
        XCTAssertEqual(mirio.github, RemoteGitHubSummary(owner: "ShinjoSato", repo: "mirio", projectNumber: 4))
        XCTAssertEqual(mirio.roomIds, ["e:b", "h:a"], "要対応 → 稼働中の順（mac のスレッドと同じ）")
        XCTAssertEqual(list.projects[1].status, .archived)
        XCTAssertNil(list.projects[1].github, "owner の無い紐づけは送らない")
        XCTAssertEqual(list.projects[1].roomIds, ["e:c"], "終了したルームもスレッドに出す")
    }

    func testOnlyOpenableLinksAreSent() {
        let links = RemoteProjectLink.openable(sampleProjects()[0].links)
        XCTAssertEqual(links, [
            RemoteProjectLink(name: "LP", url: "https://mirio.example/", kind: .dashboard, pinned: true, note: "本番"),
            RemoteProjectLink(name: "Docs", url: "http://docs.example/a", kind: .other, pinned: false, note: nil),
        ], "javascript: / file: / 資格情報付き / 名前なし / 同じ名前の 2 件目は送らない")
    }

    func testLocalInformationIsNotSent() throws {
        let project = sampleProjects()[0]
        let list = RemoteProjectList(directories: ProjectDirectories.directories(projects: [project], rooms: []))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let json = try XCTUnwrap(String(data: encoder.encode(list), encoding: .utf8))
        for secret in [secretPath, "/Users", "secret-folder", "手元のメモ", "ios/App.xcodeproj", "npm run build", "\"site\"", "\"123\""] {
            XCTAssertFalse(json.contains(secret), "\(secret) は送らない: \(json)")
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let first = try XCTUnwrap((object["projects"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(first.keys), ["id", "name", "status", "github", "links", "roomIds"])
        let link = try XCTUnwrap((first["links"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(link.keys), ["name", "url", "kind", "pinned", "note"])
    }
}
