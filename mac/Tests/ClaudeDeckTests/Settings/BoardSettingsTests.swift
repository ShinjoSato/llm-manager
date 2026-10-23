import XCTest
@testable import MonitorKit

final class BoardSettingsTests: XCTestCase {
    func testDraftTrimsAndReadsNumber() {
        XCTAssertEqual(GitHubBoard.draft(name: " overview ", owner: " ShinjoSato ", number: " 5 "),
                       GitHubBoard(name: "overview", owner: "ShinjoSato", number: 5))
        XCTAssertEqual(GitHubBoard.draft(name: "a", owner: "o", number: "").number, 0)
        XCTAssertEqual(GitHubBoard.draft(name: "a", owner: "o", number: "５").number, 0)
    }

    func testProblemsAmongBoards() {
        let existing = GitHubBoard(name: "overview", owner: "ShinjoSato", number: 5)
        let boards = [existing]
        XCTAssertEqual(SettingsValidation.boardProblems(GitHubBoard(name: "x", owner: "shinjosato", number: 5), among: boards, excluding: nil),
                       ["同じボードが既にあります"])
        // 編集中の自分とは重ならない。
        XCTAssertEqual(SettingsValidation.boardProblems(existing, among: boards, excluding: existing.id), [])
        XCTAssertEqual(SettingsValidation.boardProblems(GitHubBoard(name: "x", owner: "o", number: 6), among: boards, excluding: nil), [])
        // 欄そのものの問題が先（重なりは数えない）。
        XCTAssertEqual(SettingsValidation.boardProblems(GitHubBoard(name: "", owner: "ShinjoSato", number: 0), among: boards, excluding: nil),
                       ["名前を入れてください", "Project 番号は 1 以上の整数です"])
    }

    func testSummary() {
        XCTAssertEqual(LinkageSummary.board(GitHubBoard(name: "overview", owner: "ShinjoSato", number: 5)), "ShinjoSato #5")
        XCTAssertEqual(LinkageSummary.board(GitHubBoard(name: "x", owner: "o", number: 0)), "o")
        XCTAssertEqual(LinkageSummary.board(GitHubBoard(name: "x", owner: "", number: 0)), "なし")
    }
}

@MainActor
final class BoardSettingsStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("board-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(file: SettingsFile(url: dir.appendingPathComponent("settings.json")))
    }

    private func onDisk(_ store: SettingsStore) throws -> DeckSettings {
        guard case .loaded(let settings) = store.file.load() else {
            XCTFail("読めない")
            throw CocoaError(.coderReadCorrupt)
        }
        return settings
    }

    func testAddEditRemoveArePersisted() throws {
        let store = makeStore()
        store.addBoard(GitHubBoard(name: "overview", owner: "o", number: 5))
        store.addBoard(GitHubBoard(name: "dup", owner: "O", number: 5))
        XCTAssertEqual(try onDisk(store).boards, [GitHubBoard(name: "overview", owner: "o", number: 5)])

        let id = store.settings.boards[0].id
        store.scheduleBoard(id: id, GitHubBoard(name: "renamed", owner: "o2", number: 6))
        XCTAssertEqual(try onDisk(store).boards[0].name, "overview")
        store.flushPending(force: true)
        XCTAssertEqual(try onDisk(store).boards, [GitHubBoard(name: "renamed", owner: "o2", number: 6)])
        XCTAssertEqual(store.settings.boards[0].id, id)

        store.scheduleBoard(id: id, GitHubBoard(name: "途中", owner: "o2", number: 6))
        store.removeBoard(id: id)
        store.flushPending(force: true)
        XCTAssertEqual(try onDisk(store).boards, [])
    }

    /// 外で同じボードが変わっていれば、溜めていた入力より外の値を残す。
    func testExternalEditOfSameBoardWins() throws {
        let store = makeStore()
        store.addBoard(GitHubBoard(name: "overview", owner: "o", number: 5))
        store.add(paths: ["/p/a"])
        let id = store.settings.boards[0].id
        store.scheduleBoard(id: id, GitHubBoard(name: "mine", owner: "o", number: 5))
        var external = try onDisk(store)
        external.boards[0].name = "byClaude"
        try SettingsFile(url: store.file.url).save(external)
        store.flushPending(force: true)
        XCTAssertEqual(try onDisk(store).boards.map(\.name), ["byClaude"])
        XCTAssertEqual(store.settings.boards.map(\.name), ["byClaude"])
        XCTAssertNotNil(store.notice)
    }
}
