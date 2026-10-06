import XCTest
@testable import MonitorKit

final class SettingsFileTests: XCTestCase {
    private var dir: URL!
    private var file: SettingsFile!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString)", isDirectory: true)
        file = SettingsFile(url: dir.appendingPathComponent("conf/settings.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sample() -> DeckSettings {
        DeckSettings(projects: [
            ManagedProject(name: "mirio", path: "/tmp/mirio", status: .active, note: "中心",
                           github: GitHubLink(owner: "ShinjoSato", repo: "ailovei", projectNumber: 4)),
            ManagedProject(name: "infra", path: "/tmp/infra", status: .paused),
        ], boards: [GitHubBoard(name: "overview", owner: "ShinjoSato", number: 5)])
    }

    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testDefaultURLHonorsEnvironment() {
        XCTAssertEqual(SettingsFile.defaultURL(environment: ["CLAUDE_DECK_SETTINGS": "/tmp/x/s.json"]).path, "/tmp/x/s.json")
        XCTAssertEqual(SettingsFile.defaultURL(environment: [:]).lastPathComponent, "settings.json")
        XCTAssertEqual(SettingsFile.defaultURL(environment: [:]).deletingLastPathComponent(), DeckPaths.applicationSupport)
    }

    func testSaveAndLoadRoundTripWithPrivatePermissions() throws {
        let settings = sample()
        let restricted = SettingsFile(url: file.url, restrictsDirectory: true)
        try restricted.save(settings)
        XCTAssertEqual(restricted.load(), .loaded(settings))
        XCTAssertEqual(try mode(file.url), 0o600)
        XCTAssertEqual(try mode(file.url.deletingLastPathComponent()), 0o700)
        // 書きかけの一時ファイルを残さない（置き換えで書く）。
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.url.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["settings.json"])
    }

    func testCustomLocationKeepsDirectoryPermissions() throws {
        let parent = file.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertFalse(file.restrictsDirectory)
        try file.save(sample())
        XCTAssertEqual(try mode(file.url), 0o600)
        XCTAssertEqual(try mode(parent), 0o755)
        XCTAssertTrue(SettingsFile(url: DeckPaths.applicationSupport.appendingPathComponent("settings.json")).restrictsDirectory)
    }

    func testSaveReplacesFileAtomically() throws {
        try file.save(sample())
        let before = try FileManager.default.attributesOfItem(atPath: file.url.path)[.systemFileNumber] as? Int
        var next = sample()
        next.projects.removeLast()
        try file.save(next)
        let after = try FileManager.default.attributesOfItem(atPath: file.url.path)[.systemFileNumber] as? Int
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(file.load(), .loaded(next))
    }

    func testFileShape() throws {
        try file.save(sample())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        let project = try XCTUnwrap((object["projects"] as? [[String: Any]])?.first)
        XCTAssertNotNil(UUID(uuidString: project["id"] as? String ?? ""))
        XCTAssertEqual(project["status"] as? String, "active")
        let github = try XCTUnwrap(project["github"] as? [String: Any])
        XCTAssertEqual(github["owner"] as? String, "ShinjoSato")
        XCTAssertEqual(github["projectNumber"] as? Int, 4)
        let second = try XCTUnwrap((object["projects"] as? [[String: Any]])?.last)
        XCTAssertNil(second["github"])
        XCTAssertEqual((object["boards"] as? [[String: Any]])?.first?.keys.sorted(), ["name", "number", "owner"])
    }

    func testLinksAreWrittenOnlyWhenPresent() throws {
        var settings = sample()
        settings.projects[0].links = [ProjectLink(name: "LP", url: "https://example.com/lp"),
                                      ProjectLink(name: "Figma", url: "https://www.figma.com/file/x")]
        try file.save(settings)
        XCTAssertEqual(file.load(), .loaded(settings))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
        let projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
        let links = try XCTUnwrap(projects[0]["links"] as? [[String: Any]])
        XCTAssertEqual(links.map { $0["name"] as? String }, ["LP", "Figma"])
        XCTAssertEqual(links[0].keys.sorted(), ["name", "url"])
        // 無いプロジェクトには links を書かない（手で書いたファイルの形を変えない）。
        XCTAssertNil(projects[1]["links"])
        // links の無いファイルも読める。
        let json = #"{"version":1,"projects":[{"id":"\#(UUID().uuidString)","name":"a","path":"/a","status":"active"}]}"#
        guard case .loaded(let loaded) = SettingsFile.decode(Data(json.utf8)) else { return XCTFail() }
        XCTAssertEqual(loaded.projects[0].links, [])
    }

    func testBadLinksStillLoadAsWarnings() {
        let json = #"{"version":1,"projects":[{"id":"\#(UUID().uuidString)","name":"a","path":"/a","status":"active","links":[{"name":"","url":"ftp://x"},{"name":"LP","url":"https://example.com"},{"name":"LP","url":"https://example.org"}]}]}"#
        guard case .loaded(let settings) = SettingsFile.decode(Data(json.utf8)) else { return XCTFail() }
        XCTAssertEqual(settings.projects[0].links.count, 3)
        // 名前が空・URL の形・同じ名前の 3 件。
        XCTAssertEqual(SettingsValidation.warnings(settings).count, 3)
    }

    func testMissingGithubAndRepoAreOptional() throws {
        let json = #"{"version":1,"projects":[{"id":"\#(UUID().uuidString)","name":"a","path":"/a","status":"archived","github":{"owner":"o","projectNumber":3}}]}"#
        guard case .loaded(let s) = SettingsFile.decode(Data(json.utf8)) else { return XCTFail() }
        XCTAssertEqual(s.projects[0].github, GitHubLink(owner: "o", repo: nil, projectNumber: 3))
        XCTAssertEqual(s.projects[0].note, "")
        XCTAssertEqual(s.boards, [])
    }

    func testUnknownVersionIsNotOverwritten() throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"version":2,"projects":[]}"#.utf8)
        try original.write(to: file.url)
        guard case .unreadable(let reason) = file.load() else { return XCTFail() }
        XCTAssertTrue(reason.contains("version 2"))
        XCTAssertThrowsError(try file.save(sample()))
        XCTAssertEqual(try Data(contentsOf: file.url), original)
    }

    func testBrokenFileIsNotOverwritten() throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for text in ["{not json", #"{"projects":[]}"#, #"{"version":1,"projects":[{"name":"a"}]}"#,
                     #"{"version":1,"projects":[{"id":"\#(UUID().uuidString)","name":"a","path":"/a","status":"done"}]}"#] {
            let original = Data(text.utf8)
            try original.write(to: file.url)
            guard case .unreadable = file.load() else { return XCTFail(text) }
            XCTAssertThrowsError(try file.save(sample()), text)
            XCTAssertEqual(try Data(contentsOf: file.url), original, text)
        }
    }

    func testBootstrapMigratesLegacyProjectsAndKeepsIt() throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = Data(#"""
        [{"name":"mirio","path":"/p/mirio","status":"active","note":"中心","ghOwner":"x","ghNumber":4},
         {"name":"old","path":"/p/old","status":"weird","note":""},
         {"name":"dup","path":"/p/mirio/","status":"paused","note":""},
         {"name":"rel","path":"relative/path","status":"active","note":""}]
        """#.utf8)
        try legacy.write(to: file.legacyProjectsURL)
        let boot = file.bootstrap()
        guard case .loaded(let settings) = boot.result else { return XCTFail() }
        XCTAssertNil(boot.saveFailure)
        XCTAssertNil(boot.legacyProblem)
        XCTAssertEqual(settings.projects.map(\.name), ["mirio", "old"])
        XCTAssertEqual(settings.projects.map(\.status), [.active, .active])
        XCTAssertEqual(settings.projects[0].note, "中心")
        XCTAssertNil(settings.projects[0].github)
        XCTAssertEqual(file.load(), .loaded(settings))
        XCTAssertEqual(try Data(contentsOf: file.legacyProjectsURL), legacy)
        // 2 回目は作った設定をそのまま読む（取り込み直さない）。
        XCTAssertEqual(file.bootstrap().result, .loaded(settings))
    }

    func testBootstrapWithoutAnythingStaysMissing() {
        let boot = file.bootstrap()
        XCTAssertEqual(boot.result, .missing)
        XCTAssertNil(boot.legacyProblem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testBrokenLegacyFileIsReportedAndKept() throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = Data("{broken".utf8)
        try legacy.write(to: file.legacyProjectsURL)
        let boot = file.bootstrap()
        XCTAssertEqual(boot.result, .missing)
        XCTAssertNotNil(boot.legacyProblem)
        XCTAssertEqual(try Data(contentsOf: file.legacyProjectsURL), legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testBootstrapThatCannotWriteKeepsMigratedContent() throws {
        let parent = file.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data(#"[{"name":"a","path":"/p/a","status":"paused"}]"#.utf8).write(to: file.legacyProjectsURL)
        XCTAssertEqual(chmod(parent.path, 0o500), 0)
        defer { chmod(parent.path, 0o700) }
        let boot = file.bootstrap()
        guard case .loaded(let settings) = boot.result else { return XCTFail() }
        XCTAssertEqual(settings.projects.map(\.name), ["a"])
        XCTAssertNotNil(boot.saveFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testInvalidContentIsUnreadableAndNotOverwritten() throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID().uuidString
        let cases = [
            #"{"version":1,"projects":[{"id":"\#(id)","name":"a","path":"/a","status":"active"},{"id":"\#(id)","name":"b","path":"/b","status":"active"}]}"#,
            #"{"version":1,"projects":[{"id":"\#(UUID().uuidString)","name":"a","path":"/a","status":"active"},{"id":"\#(UUID().uuidString)","name":"b","path":"/a","status":"active"}]}"#,
            #"{"version":1,"projects":[{"id":"\#(UUID().uuidString)","name":"a","path":"a/b","status":"active"}]}"#,
        ]
        for text in cases {
            let original = Data(text.utf8)
            try original.write(to: file.url)
            guard case .unreadable(let reason) = file.load() else { return XCTFail(text) }
            XCTAssertTrue(reason.contains("中身に問題"), reason)
            XCTAssertThrowsError(try file.save(sample()), text)
            XCTAssertEqual(try Data(contentsOf: file.url), original, text)
        }
    }

    func testLightProblemsStillLoad() {
        let json = #"{"version":1,"projects":[{"id":"\#(UUID().uuidString)","name":"","path":"/a","status":"active","github":{"owner":"bad_owner","repo":"r"}}],"boards":[{"name":"x","owner":"o","number":0}]}"#
        guard case .loaded(let settings) = SettingsFile.decode(Data(json.utf8)) else { return XCTFail() }
        XCTAssertEqual(SettingsValidation.warnings(settings).count, 3)
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("settings-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(file: SettingsFile(url: dir.appendingPathComponent("settings.json")))
    }

    func testAddRemoveMoveArePersisted() throws {
        let store = makeStore()
        store.add(paths: ["/p/a", "/p/b/", "/p/c", "/p/a"])
        XCTAssertEqual(store.projects.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(store.projects[1].path, "/p/b")
        store.move(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(store.projects.map(\.name), ["b", "c", "a"])
        store.move(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.projects.map(\.name), ["a", "b", "c"])
        store.remove(id: store.projects[1].id)
        store.updateProject(id: store.projects[0].id) { $0.note = "メモ" }
        let reopened = makeStore()
        XCTAssertEqual(reopened.settings, store.settings)
        XCTAssertEqual(reopened.projects.map(\.name), ["a", "c"])
        XCTAssertEqual(reopened.projects[0].note, "メモ")
    }

    func testReloadPicksUpExternalEdits() throws {
        let store = makeStore()
        store.add(paths: ["/p/a"])
        var edited = store.settings
        edited.projects[0].name = "renamed"
        edited.boards.append(GitHubBoard(name: "overview", owner: "o", number: 5))
        try SettingsFile(url: store.file.url).save(edited)
        store.reload()
        XCTAssertEqual(store.settings, edited)
    }

    func testUnreadableFileBlocksChanges() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        try Data("broken".utf8).write(to: url)
        let store = makeStore()
        XCTAssertNotNil(store.problem)
        XCTAssertFalse(store.isEditable)
        store.add(paths: ["/p/a"])
        XCTAssertEqual(store.projects, [])
        XCTAssertThrowsError(try store.importData(Data("a\t/p/a\n".utf8)))
        XCTAssertEqual(try Data(contentsOf: url), Data("broken".utf8))
        // 直されたら読み直しで使えるようになる。
        try Data(#"{"version":1,"projects":[],"boards":[]}"#.utf8).write(to: url)
        store.reload()
        XCTAssertNil(store.problem)
        store.add(paths: ["/p/a"])
        XCTAssertEqual(store.projects.count, 1)
    }

    func testExternalBreakageAfterLoadIsNotOverwritten() throws {
        let store = makeStore()
        store.add(paths: ["/p/a"])
        try Data("broken".utf8).write(to: store.file.url)
        store.add(paths: ["/p/b"])
        XCTAssertNotNil(store.problem)
        XCTAssertEqual(try Data(contentsOf: store.file.url), Data("broken".utf8))
    }

    private func external(_ store: SettingsStore, _ change: (inout DeckSettings) -> Void) throws {
        guard case .loaded(var current) = store.file.load() else { return XCTFail("読めない") }
        change(&current)
        try SettingsFile(url: store.file.url).save(current)
    }

    func testUpdateAfterExternalEditKeepsExternalAddition() throws {
        let store = makeStore()
        store.add(paths: ["/p/a"])
        try external(store) {
            $0.projects.append(ManagedProject(name: "byClaude", path: "/p/claude"))
            $0.boards.append(GitHubBoard(name: "overview", owner: "o", number: 5))
        }
        // 読み直していない古い一覧のまま編集しても、外の追加は残る。
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertTrue(store.updateProject(id: store.projects[0].id) { $0.note = "メモ" })
        XCTAssertEqual(store.projects.map(\.name), ["a", "byClaude"])
        XCTAssertEqual(store.projects[0].note, "メモ")
        guard case .loaded(let onDisk) = store.file.load() else { return XCTFail() }
        XCTAssertEqual(onDisk, store.settings)
        XCTAssertEqual(onDisk.boards.count, 1)
        XCTAssertNil(store.notice)
    }

    func testChangeThatNoLongerAppliesIsDroppedWithNotice() throws {
        let store = makeStore()
        store.add(paths: ["/p/a", "/p/b"])
        let removed = store.projects[0].id
        try external(store) { $0.projects.removeFirst() }
        XCTAssertFalse(store.updateProject(id: removed) { $0.note = "消えたもの" })
        XCTAssertNotNil(store.notice)
        XCTAssertEqual(store.projects.map(\.name), ["b"])
        guard case .loaded(let onDisk) = store.file.load() else { return XCTFail() }
        XCTAssertEqual(onDisk.projects.map(\.name), ["b"])
    }

    func testPendingEditsAreReappliedOnExternalContent() throws {
        let store = makeStore()
        store.add(paths: ["/p/a"])
        let id = store.projects[0].id
        store.scheduleProject(id: id, field: "name", \.name, "途中")
        store.scheduleProject(id: id, field: "name", \.name, "確定")
        XCTAssertTrue(store.hasPendingEdits)
        try external(store) { $0.projects.append(ManagedProject(name: "x", path: "/p/x")) }
        store.flushPending()
        XCTAssertFalse(store.hasPendingEdits)
        guard case .loaded(let onDisk) = store.file.load() else { return XCTFail() }
        XCTAssertEqual(onDisk.projects.map(\.name), ["確定", "x"])
    }

    /// 条件を満たすまで待つ（期限付き）。
    private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testPendingEditsWaitWhileComposing() async throws {
        let store = makeStore()
        store.add(paths: ["/p/a"])
        let id = store.projects[0].id
        var composing = true
        store.isComposing = { composing }
        store.scheduleProject(id: id, field: "note", \.note, "へんかんちゅう")
        try await waitUntil { store.flushAttempts >= 1 }
        XCTAssertGreaterThanOrEqual(store.flushAttempts, 1)
        XCTAssertEqual(store.projects[0].note, "")
        XCTAssertTrue(store.hasPendingEdits)
        composing = false
        try await waitUntil { store.projects[0].note == "へんかんちゅう" }
        XCTAssertEqual(store.projects[0].note, "へんかんちゅう")
        // 閉じる・終了の時は変換中でも書き切る。
        composing = true
        store.scheduleProject(id: id, field: "note", \.note, "閉じる時")
        store.flushPending(force: true)
        XCTAssertEqual(SettingsFile(url: store.file.url).load(), .loaded(store.settings))
        XCTAssertEqual(store.projects[0].note, "閉じる時")
    }

    func testImmediateChangeWhileComposingKeepsPendingUnwritten() async throws {
        let store = makeStore()
        store.add(paths: ["/p/a"])
        let id = store.projects[0].id
        var composing = true
        store.isComposing = { composing }
        store.scheduleProject(id: id, field: "note", \.note, "へんかん")
        XCTAssertTrue(store.updateProject(id: id) { $0.status = .paused })
        guard case .loaded(let onDisk) = store.file.load() else { return XCTFail() }
        XCTAssertEqual(onDisk.projects[0].status, .paused)
        XCTAssertEqual(onDisk.projects[0].note, "")
        XCTAssertTrue(store.hasPendingEdits)
        composing = false
        try await waitUntil { store.projects[0].note == "へんかん" }
        guard case .loaded(let later) = store.file.load() else { return XCTFail() }
        XCTAssertEqual(later.projects[0].note, "へんかん")
        XCTAssertEqual(later.projects[0].status, .paused)
    }

    func testCancelPendingDropsEdit() {
        let store = makeStore()
        store.add(paths: ["/p/a"])
        let id = store.projects[0].id
        store.scheduleProject(id: id, field: "name", \.name, "不正な途中")
        store.cancelPending(key: SettingsStore.projectKey(id: id, field: "name"))
        store.flushPending()
        XCTAssertEqual(store.projects[0].name, "a")
    }

    func testReloadKeepsBoardIDs() throws {
        let store = makeStore()
        store.addBoard(GitHubBoard(name: "overview", owner: "o", number: 5))
        store.addBoard(GitHubBoard(name: "other", owner: "o", number: 6))
        let ids = store.settings.boards.map(\.id)
        try external(store) {
            $0.boards[0].name = "renamed"
            $0.boards.append(GitHubBoard(name: "new", owner: "o", number: 7))
        }
        store.reload()
        XCTAssertEqual(store.settings.boards.map(\.name), ["renamed", "other", "new"])
        XCTAssertEqual(Array(store.settings.boards.map(\.id).prefix(2)), ids)
    }

    func testMoveFollowsIDsAfterExternalReorder() throws {
        let store = makeStore()
        store.add(paths: ["/p/a", "/p/b", "/p/c"])
        try external(store) { $0.projects.reverse() }
        // 画面では a, b, c のまま。a を末尾へ動かす。
        store.move(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(store.projects.map(\.name), ["c", "b", "a"])
    }

    func testRefusesToWriteBlockingContent() {
        let store = makeStore()
        store.add(paths: ["/p/a"])
        XCTAssertFalse(store.update { $0.projects.append(ManagedProject(name: "rel", path: "relative")) })
        XCTAssertNotNil(store.saveError)
        XCTAssertEqual(store.projects.count, 1)
    }

    func testMigrationRetriedOnReloadAfterWriteFailure() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"[{"name":"a","path":"/p/a","status":"active"}]"#.utf8).write(to: dir.appendingPathComponent("projects.json"))
        XCTAssertEqual(chmod(dir.path, 0o500), 0)
        defer { chmod(dir.path, 0o700) }
        let store = makeStore()
        XCTAssertNil(store.problem)
        XCTAssertNotNil(store.saveError)
        XCTAssertEqual(store.projects.map(\.name), ["a"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.url.path))
        chmod(dir.path, 0o700)
        store.reload()
        XCTAssertNil(store.saveError)
        XCTAssertEqual(store.file.load(), .loaded(store.settings))
        XCTAssertEqual(store.projects.map(\.name), ["a"])
    }

    func testBrokenLegacyIsShownAsNotice() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: dir.appendingPathComponent("projects.json"))
        let store = makeStore()
        XCTAssertNil(store.problem)
        XCTAssertNotNil(store.notice)
        XCTAssertTrue(store.isEditable)
    }

    func testWatcherPicksUpExternalEditsWithoutReload() async throws {
        let store = makeStore()
        store.add(paths: ["/p/a"])
        store.startWatching()
        defer { store.stopWatching() }
        try external(store) { $0.projects.append(ManagedProject(name: "byClaude", path: "/p/claude")) }
        try await waitUntil { store.projects.count >= 2 }
        XCTAssertEqual(store.projects.map(\.name), ["a", "byClaude"])
        // 自分の書き込みの通知では読み直さない（回数が増えない）。
        let reloads = store.reloadCount
        store.add(paths: ["/p/b"])
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.reloadCount, reloads)
        XCTAssertEqual(store.projects.map(\.name), ["a", "byClaude", "b"])
    }

    /// その場で書き換える（truncate して書く）。`>` のリダイレクトや一部のエディタの保存と同じ。
    private func overwriteInPlace(_ store: SettingsStore, _ data: Data) throws {
        let handle = try FileHandle(forWritingTo: store.file.url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    func testWatcherPicksUpInPlaceOverwrite() async throws {
        let store = makeStore()
        store.add(paths: ["/p/a"])
        store.startWatching()
        defer { store.stopWatching() }
        var edited = store.settings
        edited.projects[0].name = "inplace"
        try overwriteInPlace(store, try edited.encoded())
        try await waitUntil { store.projects.first?.name == "inplace" }
        XCTAssertEqual(store.projects.map(\.name), ["inplace"])
        // 置き換えた後の新しいファイルも、その場の書き換えを拾い続ける。
        try external(store) { $0.projects[0].note = "置き換え" }
        try await waitUntil { store.projects.first?.note == "置き換え" }
        edited = store.settings
        edited.projects[0].name = "again"
        try overwriteInPlace(store, try edited.encoded())
        try await waitUntil { store.projects.first?.name == "again" }
        XCTAssertEqual(store.projects.first?.name, "again")
    }

    func testHalfWrittenFileKeepsPendingAndSavesLater() async throws {
        let store = makeStore()
        store.add(paths: ["/p/a"])
        let id = store.projects[0].id
        store.scheduleProject(id: id, field: "note", \.note, "打った値")
        let complete = try store.settings.encoded()
        // 書きかけ（空）の間に保存しようとしても、入力は残す。
        try overwriteInPlace(store, Data())
        store.flushPending()
        XCTAssertNotNil(store.problem)
        XCTAssertTrue(store.hasPendingEdits)
        XCTAssertTrue(store.hasUnsavedInput)
        // 書き終わったら読み直して、残していた入力を書く。
        try overwriteInPlace(store, complete)
        try await waitUntil { !store.hasPendingEdits && store.problem == nil }
        XCTAssertNil(store.problem)
        XCTAssertFalse(store.hasPendingEdits)
        guard case .loaded(let onDisk) = store.file.load() else { return XCTFail() }
        XCTAssertEqual(onDisk.projects.map(\.note), ["打った値"])
    }

    func testDeletedFileIsNotMigratedAgain() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"[{"name":"legacy","path":"/p/legacy","status":"active"}]"#.utf8).write(to: dir.appendingPathComponent("projects.json"))
        let store = makeStore()
        XCTAssertEqual(store.projects.map(\.name), ["legacy"])
        try FileManager.default.removeItem(at: store.file.url)
        store.reloadIfChanged()
        XCTAssertEqual(store.projects, [])
        XCTAssertEqual(store.notice, SettingsStore.deletedNotice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.url.path))
        // 次の変更で作り直す（以前の projects.json は取り込まない）。
        store.add(paths: ["/p/new"])
        guard case .loaded(let onDisk) = store.file.load() else { return XCTFail() }
        XCTAssertEqual(onDisk.projects.map(\.name), ["new"])
    }

    func testDeletedDuringUpdateDoesNotMigrate() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"[{"name":"legacy","path":"/p/legacy","status":"active"}]"#.utf8).write(to: dir.appendingPathComponent("projects.json"))
        let store = makeStore()
        try FileManager.default.removeItem(at: store.file.url)
        store.add(paths: ["/p/new"])
        guard case .loaded(let onDisk) = store.file.load() else { return XCTFail() }
        XCTAssertEqual(onDisk.projects.map(\.name), ["new"])
        XCTAssertEqual(store.notice, SettingsStore.deletedNotice)
    }

    func testPartiallyReappliedPendingShowsNotice() throws {
        let store = makeStore()
        store.add(paths: ["/p/a", "/p/b"])
        let (a, b) = (store.projects[0].id, store.projects[1].id)
        store.scheduleProject(id: a, field: "note", \.note, "消えるもの")
        store.scheduleProject(id: b, field: "note", \.note, "残るもの")
        try external(store) { $0.projects.removeAll { $0.id == a } }
        store.flushPending()
        XCTAssertNotNil(store.notice)
        guard case .loaded(let onDisk) = store.file.load() else { return XCTFail() }
        XCTAssertEqual(onDisk.projects.map(\.note), ["残るもの"])
    }

    func testPartiallyLostChangesShowNotice() throws {
        let store = makeStore()
        store.add(paths: ["/p/a", "/p/b"])
        let (a, b) = (store.projects[0].id, store.projects[1].id)
        // 欄の照合を持たない変更でも、効かなくなったものが 1 つでもあれば知らせる。
        store.schedule(key: "a") { s in if let i = s.projects.firstIndex(where: { $0.id == a }) { s.projects[i].note = "消える" } }
        store.schedule(key: "b") { s in if let i = s.projects.firstIndex(where: { $0.id == b }) { s.projects[i].note = "残る" } }
        try external(store) { $0.projects.removeAll { $0.id == a } }
        store.flushPending()
        XCTAssertEqual(store.notice, SettingsStore.droppedNotice)
        guard case .loaded(let onDisk) = store.file.load() else { return XCTFail() }
        XCTAssertEqual(onDisk.projects.map(\.note), ["残る"])
    }

    func testExternalEditOfSameFieldWinsOnFlush() throws {
        let store = makeStore()
        store.add(paths: ["/p/a"])
        let id = store.projects[0].id
        store.scheduleProject(id: id, field: "note", \.note, "入力")
        store.scheduleProject(id: id, field: "name", \.name, "名前")
        try external(store) { $0.projects[0].note = "外" }
        store.flushPending()
        XCTAssertEqual(store.notice, SettingsStore.droppedInputNotice)
        XCTAssertEqual(store.projects[0].note, "外")
        XCTAssertEqual(store.projects[0].name, "名前")
    }

    func testExternalEditOfSameFieldWinsOnReload() throws {
        let store = makeStore()
        store.add(paths: ["/p/a"])
        let id = store.projects[0].id
        store.scheduleProject(id: id, field: "note", \.note, "入力")
        try external(store) { $0.projects[0].note = "外" }
        store.reloadIfChanged()
        XCTAssertFalse(store.hasPendingEdits)
        XCTAssertEqual(store.notice, SettingsStore.droppedInputNotice)
        XCTAssertEqual(store.projects[0].note, "外")
        // 同じ値になっただけなら入力は捨てない。
        store.scheduleProject(id: id, field: "note", \.note, "同じ")
        try external(store) { $0.projects[0].note = "同じ" }
        store.reloadIfChanged()
        XCTAssertNil(store.notice)
        XCTAssertTrue(store.hasPendingEdits)
    }

    func testNoticeAndSaveErrorClearOnReloadAndSuccess() throws {
        let store = makeStore()
        store.add(paths: ["/p/a", "/p/b"])
        let removed = store.projects[0].id
        try external(store) { $0.projects.removeFirst() }
        XCTAssertFalse(store.updateProject(id: removed) { $0.note = "x" })
        XCTAssertNotNil(store.notice)
        store.add(paths: ["/p/c"])
        XCTAssertNil(store.notice)
        XCTAssertFalse(store.update { $0.projects.append(ManagedProject(name: "rel", path: "relative")) })
        XCTAssertNotNil(store.saveError)
        store.reload()
        XCTAssertNil(store.saveError)
        try external(store) { $0.projects.removeAll() }
        XCTAssertFalse(store.updateProject(id: store.projects[0].id) { $0.note = "y" })
        XCTAssertNotNil(store.notice)
        store.dismissNotice()
        XCTAssertNil(store.notice)
    }

    func testExportThenImportRoundTrip() throws {
        let store = makeStore()
        store.add(paths: ["/p/a", "/p/b"])
        store.updateProject(id: store.projects[0].id) {
            $0.github = GitHubLink(owner: "o", repo: "r", projectNumber: 1)
            $0.status = .archived
        }
        store.addBoard(GitHubBoard(name: "overview", owner: "o", number: 5))
        let exported = try store.exportData()

        let other = SettingsStore(file: SettingsFile(url: dir.appendingPathComponent("other/settings.json")))
        let summary = try other.importData(exported)
        XCTAssertEqual(summary.format, .settingsJSON)
        XCTAssertEqual(summary.addedProjects, 2)
        XCTAssertEqual(summary.addedBoards, 1)
        XCTAssertEqual(other.settings, store.settings)
        // もう一度読んでも重複しない。
        let again = try other.importData(exported)
        XCTAssertEqual(again.addedProjects + again.addedBoards + again.linkedGitHub, 0)
        XCTAssertEqual(again.skipped, 3)
        XCTAssertEqual(other.settings, store.settings)
    }
}

final class SettingsImportTests: XCTestCase {
    private let registry = """
    # ai-manager 管理対象プロジェクト登録簿
    # 列: name <TAB> path <TAB> status <TAB> note
    # ailovei\t/Users/x/ailovei\tactive\t例

    mirio\t/p/mirio\tactive\t中心プロダクト
    sandora\t/p/sandora\tpaused\tdevelop
    infra\t/p/infra\t\t
    blog\t/p/blog
    """

    private let github = """
    # 列: name <TAB> owner <TAB> number <TAB> repo <TAB> url
    sandora\tShinjoSato\t3\tShinjoSato/random_talk\thttps://github.com/users/ShinjoSato/projects/3
    mirio\tShinjoSato\t4\tShinjoSato/ailovei\thttps://github.com/users/ShinjoSato/projects/4
    overview\tShinjoSato\t5\t-\thttps://github.com/users/ShinjoSato/projects/5
    ai-manager\tShinjoSato\t8\tShinjoSato/llm-manager\thttps://github.com/users/ShinjoSato/projects/8
    """

    func testDetectsFormats() {
        XCTAssertEqual(SettingsImport.detect(Data(registry.utf8)), .registryTSV)
        XCTAssertEqual(SettingsImport.detect(Data(github.utf8)), .githubProjectsTSV)
        XCTAssertEqual(SettingsImport.detect(Data("  \n{\"version\":1}".utf8)), .settingsJSON)
        XCTAssertNil(SettingsImport.detect(Data("hello world".utf8)))
        XCTAssertNil(SettingsImport.detect(Data("# only comments\n\n".utf8)))
        XCTAssertThrowsError(try SettingsImport.merge(Data("hello".utf8), into: DeckSettings())) { error in
            XCTAssertEqual(error as? SettingsImport.Failure, .unknownFormat)
        }
    }

    func testRegistryImport() throws {
        let (settings, summary) = try SettingsImport.merge(Data(registry.utf8), into: DeckSettings())
        XCTAssertEqual(settings.projects.map(\.name), ["mirio", "sandora", "infra", "blog"])
        XCTAssertEqual(settings.projects.map(\.status), [.active, .paused, .active, .active])
        XCTAssertEqual(settings.projects[0].note, "中心プロダクト")
        XCTAssertEqual(summary.addedProjects, 4)
        XCTAssertEqual(summary.skipped, 0)
    }

    func testRegistryDoesNotOverwriteSamePath() throws {
        let existing = DeckSettings(projects: [ManagedProject(name: "mine", path: "/p/mirio", status: .archived, note: "手元")])
        let (settings, summary) = try SettingsImport.merge(Data(registry.utf8), into: existing)
        XCTAssertEqual(settings.projects.first, existing.projects.first)
        XCTAssertEqual(settings.projects.count, 4)
        XCTAssertEqual(summary.addedProjects, 3)
        XCTAssertEqual(summary.skipped, 1)
    }

    func testGitHubProjectsImport() throws {
        let (withProjects, _) = try SettingsImport.merge(Data(registry.utf8), into: DeckSettings())
        let (settings, summary) = try SettingsImport.merge(Data(github.utf8), into: withProjects)
        XCTAssertEqual(settings.projects.first { $0.name == "mirio" }?.github,
                       GitHubLink(owner: "ShinjoSato", repo: "ailovei", projectNumber: 4))
        XCTAssertEqual(settings.projects.first { $0.name == "sandora" }?.github,
                       GitHubLink(owner: "ShinjoSato", repo: "random_talk", projectNumber: 3))
        XCTAssertNil(settings.projects.first { $0.name == "infra" }?.github)
        // repo が - のものはボードへ。repo 付きで一致するプロジェクトが無いものは取り込まない（repo を落とさないため）。
        XCTAssertEqual(settings.boards, [GitHubBoard(name: "overview", owner: "ShinjoSato", number: 5)])
        XCTAssertEqual(summary.linkedGitHub, 2)
        XCTAssertEqual(summary.addedBoards, 1)
        XCTAssertEqual(summary.unmatched, 1)
        XCTAssertTrue(summary.message.contains("先に registry.tsv を読み込んでください"))

        // 2 回目は何も足さず、手で直した紐づけも上書きしない。
        var edited = settings
        edited.projects[0].github = GitHubLink(owner: "me", repo: "other", projectNumber: 9)
        let (again, second) = try SettingsImport.merge(Data(github.utf8), into: edited)
        XCTAssertEqual(again, edited)
        XCTAssertEqual(second.linkedGitHub + second.addedBoards, 0)
        XCTAssertEqual(second.skipped, 3)
        XCTAssertEqual(second.unmatched, 1)
    }

    func testGitHubProjectsBeforeRegistryDoesNotDropRepo() throws {
        let (settings, summary) = try SettingsImport.merge(Data(github.utf8), into: DeckSettings())
        XCTAssertEqual(settings.boards.map(\.name), ["overview"])
        XCTAssertEqual(summary.unmatched, 3)
        // registry を読んでからもう一度読めば紐づく。
        let (withProjects, _) = try SettingsImport.merge(Data(registry.utf8), into: settings)
        let (linked, again) = try SettingsImport.merge(Data(github.utf8), into: withProjects)
        XCTAssertEqual(again.linkedGitHub, 2)
        XCTAssertEqual(linked.projects.first { $0.name == "mirio" }?.github?.repo, "ailovei")
    }

    func testSettingsImportRejectsBlockingContent() {
        let json = #"{"version":1,"projects":[{"id":"\#(UUID().uuidString)","name":"a","path":"rel","status":"active"}]}"#
        XCTAssertThrowsError(try SettingsImport.merge(Data(json.utf8), into: DeckSettings())) { error in
            guard case .unreadable = error as? SettingsImport.Failure else { return XCTFail() }
        }
    }

    func testBoardDedupIgnoresOwnerCase() throws {
        let existing = DeckSettings(boards: [GitHubBoard(name: "x", owner: "shinjosato", number: 5)])
        let (settings, _) = try SettingsImport.merge(Data(github.utf8), into: existing)
        XCTAssertEqual(settings.boards.filter { $0.number == 5 }.count, 1)
    }

    func testSettingsImportFillsMissingGitHubOnly() throws {
        let incoming = DeckSettings(projects: [
            ManagedProject(name: "a", path: "/p/a", github: GitHubLink(owner: "o", repo: "a", projectNumber: 1)),
            ManagedProject(name: "b", path: "/p/b", github: GitHubLink(owner: "o", repo: "b")),
        ])
        let existing = DeckSettings(projects: [
            ManagedProject(name: "a-local", path: "/p/a"),
            ManagedProject(name: "b-local", path: "/p/b", github: GitHubLink(owner: "me", projectNumber: 2)),
        ])
        let (settings, summary) = try SettingsImport.merge(try incoming.encoded(), into: existing)
        XCTAssertEqual(settings.projects.map(\.name), ["a-local", "b-local"])
        XCTAssertEqual(settings.projects[0].github, incoming.projects[0].github)
        XCTAssertEqual(settings.projects[1].github, existing.projects[1].github)
        XCTAssertEqual(summary.linkedGitHub, 1)
        XCTAssertEqual(summary.skipped, 1)
    }

    func testSettingsImportAddsMissingLinksOnly() throws {
        let incoming = DeckSettings(projects: [
            ManagedProject(name: "a", path: "/p/a", links: [ProjectLink(name: "LP", url: "https://incoming.example/lp"),
                                                           ProjectLink(name: "Docs", url: "https://incoming.example/docs")]),
            ManagedProject(name: "b", path: "/p/b", links: [ProjectLink(name: "LP", url: "https://b.example")]),
            ManagedProject(name: "c", path: "/p/c"),
        ])
        let existing = DeckSettings(projects: [
            ManagedProject(name: "a-local", path: "/p/a", links: [ProjectLink(name: "LP", url: "https://local.example/lp")]),
            ManagedProject(name: "b-local", path: "/p/b", links: [ProjectLink(name: "LP", url: "https://local.example/b")]),
            ManagedProject(name: "c-local", path: "/p/c"),
        ])
        let (settings, summary) = try SettingsImport.merge(try incoming.encoded(), into: existing)
        // 同じ名前は手元を残し、無い名前だけ末尾に足す。
        XCTAssertEqual(settings.projects[0].links, [ProjectLink(name: "LP", url: "https://local.example/lp"),
                                                    ProjectLink(name: "Docs", url: "https://incoming.example/docs")])
        XCTAssertEqual(settings.projects[1].links, existing.projects[1].links)
        XCTAssertEqual(settings.projects[2].links, [])
        XCTAssertEqual(summary.addedLinks, 1)
        XCTAssertEqual(summary.skipped, 2)
        XCTAssertTrue(summary.message.contains("リンク 1 件"))
    }

    func testSettingsImportRejectsUnknownVersion() {
        XCTAssertThrowsError(try SettingsImport.merge(Data(#"{"version":9}"#.utf8), into: DeckSettings())) { error in
            guard case .unreadable(let reason) = error as? SettingsImport.Failure else { return XCTFail() }
            XCTAssertTrue(reason.contains("version 9"))
        }
    }

    func testSummaryMessage() {
        var summary = SettingsImport.Summary(format: .registryTSV)
        XCTAssertEqual(summary.message, "足したものはありません")
        summary.addedProjects = 2
        summary.addedBoards = 1
        summary.skipped = 3
        XCTAssertEqual(summary.message, "プロジェクト 2 件・ボード 1 件を足しました（既にある・読めない 3 件は飛ばしました）")
    }
}

final class SettingsValidationTests: XCTestCase {
    func testOwner() {
        for ok in ["ShinjoSato", "a", "a-b", "a1", String(repeating: "a", count: 39)] {
            XCTAssertNil(SettingsValidation.ownerProblem(ok), ok)
        }
        for bad in ["", "-a", "a-", "a--b", "a_b", "a.b", "a b", "日本", String(repeating: "a", count: 40)] {
            XCTAssertNotNil(SettingsValidation.ownerProblem(bad), bad)
        }
    }

    func testRepo() {
        for ok in ["llm-manager", "random_talk", "a.b", ".github", "A1"] {
            XCTAssertNil(SettingsValidation.repoProblem(ok), ok)
        }
        for bad in ["", ".", "..", "a/b", "a b", "日本", String(repeating: "a", count: 101)] {
            XCTAssertNotNil(SettingsValidation.repoProblem(bad), bad)
        }
    }

    func testNumber() {
        XCTAssertNil(SettingsValidation.parseNumber(""))
        XCTAssertEqual(SettingsValidation.parseNumber(" 12 "), 12)
        XCTAssertEqual(SettingsValidation.parseNumber("abc"), 0)
        XCTAssertEqual(SettingsValidation.parseNumber("１２"), 0)
        XCTAssertNil(SettingsValidation.numberProblem(nil))
        XCTAssertNil(SettingsValidation.numberProblem(1))
        XCTAssertNotNil(SettingsValidation.numberProblem(0))
        XCTAssertNotNil(SettingsValidation.numberProblem(-3))
    }

    func testLinkNeedsRepoOrNumber() {
        XCTAssertEqual(SettingsValidation.linkProblems(GitHubLink(owner: "o", repo: "r")), [])
        XCTAssertEqual(SettingsValidation.linkProblems(GitHubLink(owner: "o", projectNumber: 1)), [])
        XCTAssertEqual(SettingsValidation.linkProblems(GitHubLink(owner: "o")).count, 1)
        XCTAssertEqual(SettingsValidation.linkProblems(GitHubLink(owner: "", repo: "r/x", projectNumber: 0)).count, 3)
    }

    func testProjectLinks() {
        XCTAssertEqual(SettingsValidation.projectLinkProblems(ProjectLink(name: "LP", url: "https://example.com")), [])
        XCTAssertEqual(SettingsValidation.projectLinkProblems(ProjectLink(name: " ", url: "https://example.com")).count, 1)
        XCTAssertEqual(SettingsValidation.projectLinkProblems(ProjectLink(name: "LP", url: "")).count, 1)
        XCTAssertEqual(SettingsValidation.projectLinkProblems(ProjectLink(name: "LP", url: "javascript:alert(1)")).count, 1)
        XCTAssertEqual(SettingsValidation.projectLinkProblems(ProjectLink(name: "", url: "file:///etc/hosts")).count, 2)
        XCTAssertNil(SettingsValidation.linkURLProblem(" https://example.com/path?q=1 "))
        XCTAssertNotNil(SettingsValidation.linkURLProblem("example.com"))
        // 同じ名前は後の行の問題になる（前後の空白は同じ名前とみなす）。
        let rows = SettingsValidation.projectLinkRowProblems([ProjectLink(name: "LP", url: "https://a.example"),
                                                              ProjectLink(name: "Docs", url: "https://b.example"),
                                                              ProjectLink(name: " LP ", url: "https://c.example")])
        XCTAssertEqual(rows.map(\.count), [0, 0, 1])
        var project = ManagedProject(name: "a", path: "/p/a", links: [ProjectLink(name: "LP", url: "https://a.example")])
        XCTAssertEqual(SettingsValidation.projectProblems(project), [])
        project.links.append(ProjectLink(name: "LP", url: "nope"))
        XCTAssertEqual(SettingsValidation.projectProblems(project).count, 2)
        // 読めない扱いにはしない。
        XCTAssertEqual(SettingsValidation.blockingProblems(DeckSettings(projects: [project])), [])
    }

    func testWholeSettings() {
        var settings = DeckSettings(projects: [ManagedProject(name: "a", path: "/p/a")],
                                    boards: [GitHubBoard(name: "b", owner: "o", number: 1)])
        XCTAssertEqual(SettingsValidation.problems(settings), [])
        settings.projects.append(ManagedProject(name: " ", path: "relative"))
        settings.projects.append(ManagedProject(name: "dup", path: "/p/a"))
        settings.boards.append(GitHubBoard(name: "", owner: "-x", number: 0))
        settings.boards.append(GitHubBoard(name: "b2", owner: "O", number: 1))
        // 相対パス・同じパスは読めない扱い、残り（名前が空・ボードの 3 件・同じボード）は警告。
        XCTAssertEqual(SettingsValidation.blockingProblems(settings).count, 2)
        XCTAssertEqual(SettingsValidation.warnings(settings).count, 5)
        XCTAssertEqual(SettingsValidation.problems(settings).count, 7)
        settings.projects.append(ManagedProject(id: settings.projects[0].id, name: "same-id", path: "/p/other"))
        XCTAssertEqual(SettingsValidation.blockingProblems(settings).count, 3)
    }
}
