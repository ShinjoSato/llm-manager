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
        try file.save(settings)
        XCTAssertEqual(file.load(), .loaded(settings))
        XCTAssertEqual(try mode(file.url), 0o600)
        XCTAssertEqual(try mode(file.url.deletingLastPathComponent()), 0o700)
        // 書きかけの一時ファイルを残さない（置き換えで書く）。
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.url.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["settings.json"])
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
         {"name":"dup","path":"/p/mirio","status":"paused","note":""}]
        """#.utf8)
        try legacy.write(to: file.legacyProjectsURL)
        guard case .loaded(let settings) = file.bootstrap() else { return XCTFail() }
        XCTAssertEqual(settings.projects.map(\.name), ["mirio", "old"])
        XCTAssertEqual(settings.projects.map(\.status), [.active, .active])
        XCTAssertEqual(settings.projects[0].note, "中心")
        XCTAssertNil(settings.projects[0].github)
        XCTAssertEqual(file.load(), .loaded(settings))
        XCTAssertEqual(try Data(contentsOf: file.legacyProjectsURL), legacy)
        // 2 回目は作った設定をそのまま読む（取り込み直さない）。
        XCTAssertEqual(file.bootstrap(), .loaded(settings))
    }

    func testBootstrapWithoutAnythingStaysMissing() {
        XCTAssertEqual(file.bootstrap(), .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
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
        // repo が - のものと、一致するプロジェクトが無いものはボードへ。
        XCTAssertEqual(settings.boards, [GitHubBoard(name: "overview", owner: "ShinjoSato", number: 5),
                                         GitHubBoard(name: "ai-manager", owner: "ShinjoSato", number: 8)])
        XCTAssertEqual(summary.linkedGitHub, 2)
        XCTAssertEqual(summary.addedBoards, 2)

        // 2 回目は何も足さず、手で直した紐づけも上書きしない。
        var edited = settings
        edited.projects[0].github = GitHubLink(owner: "me", repo: "other", projectNumber: 9)
        let (again, second) = try SettingsImport.merge(Data(github.utf8), into: edited)
        XCTAssertEqual(again, edited)
        XCTAssertEqual(second.linkedGitHub + second.addedBoards, 0)
        XCTAssertEqual(second.skipped, 4)
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

    func testWholeSettings() {
        var settings = DeckSettings(projects: [ManagedProject(name: "a", path: "/p/a")],
                                    boards: [GitHubBoard(name: "b", owner: "o", number: 1)])
        XCTAssertEqual(SettingsValidation.problems(settings), [])
        settings.projects.append(ManagedProject(name: " ", path: "relative"))
        settings.projects.append(ManagedProject(name: "dup", path: "/p/a"))
        settings.boards.append(GitHubBoard(name: "", owner: "-x", number: 0))
        XCTAssertEqual(SettingsValidation.problems(settings).count, 6)
    }
}
