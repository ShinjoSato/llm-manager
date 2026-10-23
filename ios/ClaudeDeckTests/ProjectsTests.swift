import DeckCore
import XCTest
@testable import ClaudeDeck

#if DEBUG
/// ディレクトリ・リンクの一覧の取り方（いつ取るか・古い mac・取り直しの失敗・ペアリングを替えた時）。
@MainActor
final class ProjectsLoadingTests: XCTestCase {
    private var keychain: PairingKeychain!

    override func setUp() {
        keychain = PairingKeychain(service: PairingKeychain.serviceName(suffix: "tests.\(UUID().uuidString)"))
    }

    override func tearDown() {
        keychain.delete()
    }

    private static func room(_ id: String, status: SessionStatus = .idle) -> RemoteRoom {
        RemoteRoom(id: id, kind: .hosted, phase: .idle, name: id, branch: nil, status: status, line: "", activityAt: nil,
                   sessionId: nil, cwd: "/", ended: nil, session: nil, permissions: [], terminalPermission: nil, menu: nil,
                   unreadableMenu: nil, busy: false, send: RemoteSendState(mode: .input, disabledReason: nil))
    }

    private static func state(_ ids: [String], status: SessionStatus = .idle) -> RemoteState {
        RemoteState(rooms: ids.map { room($0, status: status) }, usage: nil, monitoring: true)
    }

    private static let list = RemoteProjectList(projects: [
        RemoteProject(id: "p1", name: "mirio", status: .active,
                      links: [RemoteProjectLink(name: "LP", url: "https://mirio.example/", pinned: true)], roomIds: ["h:2", "h:1"]),
        RemoteProject(id: "p2", name: "old", status: .archived),
    ])

    private func model(_ loader: Loader) -> AppModel {
        let model = AppModel(keychain: keychain, startMonitoring: false)
        model.projectsLoader = { try await loader.load() }
        return model
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("時間内に揃いませんでした") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testDirectoryLoadsWhenConnectedAndAgainWhenRoomsChange() async throws {
        let loader = Loader(.success(Self.list))
        let model = model(loader)
        model.sidebarMode = .directory
        XCTAssertEqual(loader.calls, 0, "つながる前は取りに行かない")
        XCTAssertEqual(model.projectsStatus, .idle)

        model.simulateReceived(Self.state(["h:1", "h:2"]))
        try await waitUntil { model.projectsStatus == .loaded }
        XCTAssertEqual(loader.calls, 1)
        XCTAssertEqual(model.projects, Self.list)
        let project = try XCTUnwrap(model.project("p1"))
        XCTAssertEqual(model.rooms(of: project).map(\.id), ["h:2", "h:1"], "スレッドは mac の振り分けの順で、状態は一覧の最新")

        model.simulateReceived(Self.state(["h:1", "h:2"], status: .working))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(loader.calls, 1, "状態が変わっただけでは取り直さない")

        model.simulateReceived(Self.state(["h:1", "h:2", "h:3"]))
        try await waitUntil { loader.calls == 2 }
        model.simulateReceived(Self.state(["h:1"]))
        try await waitUntil { loader.calls == 3 }
        XCTAssertEqual(model.rooms(of: project).map(\.id), ["h:1"], "閉じたルームはすぐにスレッドから外れる")

        model.sidebarMode = .rooms
        model.simulateReceived(Self.state(["h:9"]))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(loader.calls, 3, "ルームの一覧を見ている間は取らない")
        model.sidebarMode = .links
        try await waitUntil { loader.calls == 4 }
    }

    func testOldMacIsReportedAsOutdated() async throws {
        let loader = Loader(.failure(RemoteClientError.http(status: 404, error: "not_found", message: "not found")))
        let model = model(loader)
        model.simulateReceived(Self.state([]))
        model.sidebarMode = .links
        try await waitUntil { model.projectsStatus == .outdatedMac }
        XCTAssertNil(model.projects)
        XCTAssertTrue(AppModel.outdatedMacText.hasPrefix("この Mac の claude-deck は古いため表示できません"))
    }

    func testFailedReloadKeepsThePreviousList() async throws {
        let loader = Loader(.success(Self.list))
        let model = model(loader)
        model.simulateReceived(Self.state([]))
        model.sidebarMode = .directory
        try await waitUntil { model.projectsStatus == .loaded }
        loader.result = .failure(RemoteClientError.transport(.timedOut))
        await model.reloadProjects()
        guard case .failed = model.projectsStatus else { return XCTFail("取り直しの失敗を出す: \(model.projectsStatus)") }
        XCTAssertEqual(model.projects, Self.list, "前に読めた一覧は残す")
        loader.result = .success(RemoteProjectList(projects: []))
        await model.reloadProjects()
        XCTAssertEqual(model.projectsStatus, .loaded)
        XCTAssertEqual(model.projects?.projects, [])
    }

    func testForgettingThePairingDropsProjectsAndLateResults() async throws {
        let loader = Loader(.success(Self.list), delay: .milliseconds(200))
        let model = model(loader)
        model.simulateReceived(Self.state([]))
        model.sidebarMode = .directory
        try await waitUntil { loader.calls == 1 }
        model.projectTabs["p1"] = .threads
        model.forget()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(model.projects, "前の Mac への取得の結果は捨てる")
        XCTAssertEqual(model.projectsStatus, .idle)
        XCTAssertEqual(model.projectTab("p1"), .links)
    }
}

/// 試験用の取り方（呼ばれた回数と返す結果を差し替える）。
private final class Loader: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: Result<RemoteProjectList, Error>
    private var _calls = 0
    private let delay: Duration

    init(_ result: Result<RemoteProjectList, Error>, delay: Duration = .zero) {
        _result = result
        self.delay = delay
    }

    var calls: Int { lock.withLock { _calls } }

    var result: Result<RemoteProjectList, Error> {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    func load() async throws -> RemoteProjectList {
        let result = lock.withLock {
            _calls += 1
            return _result
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        return try result.get()
    }
}
#endif
