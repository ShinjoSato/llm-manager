import XCTest
@testable import MonitorKit

final class XcodeLinksTests: XCTestCase {
    var dir: URL!
    var project: String { dir.appendingPathComponent("proj").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcode-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func mkdir(_ relative: String, in base: String? = nil) throws {
        try FileManager.default.createDirectory(atPath: ((base ?? project) as NSString).appendingPathComponent(relative),
                                                withIntermediateDirectories: true)
    }

    private func real(_ relative: String, in base: String? = nil) -> String? {
        FilePaths.realPath(((base ?? project) as NSString).appendingPathComponent(relative))
    }

    private func managed(_ xcode: XcodeLink?) -> ManagedProject {
        ManagedProject(name: "p", path: project, xcode: xcode)
    }

    // MARK: - 解決

    func testAutoUsesFinder() throws {
        try mkdir("ios/App.xcodeproj")
        try mkdir("Top.xcworkspace")
        let resolution = XcodeLinks.resolve(project: managed(nil), cwd: project)
        XCTAssertEqual(resolution, XcodeResolution(path: real("Top.xcworkspace"), source: .detected))
        XCTAssertEqual(XcodeLinks.resolve(project: nil, cwd: project).path, real("Top.xcworkspace"), "登録の無い cwd も自動")
    }

    func testConfiguredPathIsUsedOverAutomatic() throws {
        try mkdir("Top.xcworkspace")
        try mkdir("ios/App.xcodeproj")
        let resolution = XcodeLinks.resolve(project: managed(.path("./ios//App.xcodeproj")), cwd: project)
        XCTAssertEqual(resolution, XcodeResolution(path: real("ios/App.xcodeproj"), source: .configured))
    }

    func testDisabledGivesNothing() throws {
        try mkdir("App.xcodeproj")
        XCTAssertEqual(XcodeLinks.resolve(project: managed(.disabled), cwd: project), XcodeResolution(path: nil, source: .disabled))
    }

    func testMissingConfiguredPathGivesReason() throws {
        try mkdir("Other.xcodeproj")
        let resolution = XcodeLinks.resolve(project: managed(.path("ios/Gone.xcodeproj")), cwd: project)
        XCTAssertNil(resolution.path, "無ければ自動に落とさない")
        XCTAssertEqual(resolution.source, .configured)
        XCTAssertNotNil(resolution.problem)
        XCTAssertTrue(DirectoryTabs.hasXcodeProject(resolution), "理由を見せるため iPhone のタブは出す")
        XCTAssertFalse(DirectoryTabs.hasXcodeProject(XcodeResolution(path: nil, source: .disabled)))
        XCTAssertFalse(DirectoryTabs.hasXcodeProject(XcodeResolution(path: nil, source: .detected)))
    }

    func testConfiguredPathOutsideFolderIsRefused() throws {
        let outside = dir.appendingPathComponent("outside").path
        try mkdir("Out.xcodeproj", in: outside)
        for raw in ["../outside/Out.xcodeproj", "/abs/App.xcodeproj", "~/App.xcodeproj"] {
            let resolution = XcodeLinks.resolve(project: managed(.path(raw)), cwd: project)
            XCTAssertNil(resolution.path, raw)
            XCTAssertNotNil(resolution.problem, raw)
        }
        // シンボリックリンクで外を指すものも使わない。
        try FileManager.default.createSymbolicLink(atPath: (project as NSString).appendingPathComponent("Link.xcodeproj"),
                                                   withDestinationPath: (outside as NSString).appendingPathComponent("Out.xcodeproj"))
        let linked = XcodeLinks.resolve(project: managed(.path("Link.xcodeproj")), cwd: project)
        XCTAssertNil(linked.path)
        XCTAssertNotNil(linked.problem)
    }

    func testConfiguredPathMustBeXcodeBundle() throws {
        try mkdir("ios")
        FileManager.default.createFile(atPath: (project as NSString).appendingPathComponent("Fake.xcodeproj"), contents: Data())
        for raw in ["ios", "Fake.xcodeproj", "App.xcodeproj/project.xcworkspace", ""] {
            let resolution = XcodeLinks.resolve(project: managed(.path(raw)), cwd: project)
            XCTAssertNil(resolution.path, raw)
            XCTAssertNotNil(resolution.problem, raw)
        }
    }

    func testWorktreeRoomPrefersItsOwnCopy() throws {
        try mkdir("ios/App.xcodeproj")
        let tree = (project as NSString).appendingPathComponent(".claude/worktrees/wt")
        try mkdir("ios/App.xcodeproj", in: tree)
        FileManager.default.createFile(atPath: (tree as NSString).appendingPathComponent(".git"), contents: Data("gitdir: /x\n".utf8))
        let link = managed(.path("ios/App.xcodeproj"))
        XCTAssertEqual(XcodeLinks.resolve(project: link, cwd: (tree as NSString).appendingPathComponent("ios")).path,
                       real("ios/App.xcodeproj", in: tree))
        // 作業ツリーに無ければプロジェクトのものを使う。
        try FileManager.default.removeItem(atPath: (tree as NSString).appendingPathComponent("ios"))
        XCTAssertEqual(XcodeLinks.resolve(project: link, cwd: tree).path, real("ios/App.xcodeproj"))
        // 作業ツリーでない下のフォルダはプロジェクトからの相対で引く。
        XCTAssertEqual(XcodeLinks.resolve(project: link, cwd: (project as NSString).appendingPathComponent("ios")).path,
                       real("ios/App.xcodeproj"))
    }

    func testPathProblemsAndNormalizing() {
        XCTAssertNil(XcodeLinks.pathProblem("ios/App.xcodeproj"))
        XCTAssertNil(XcodeLinks.pathProblem("App.XCWORKSPACE"))
        XCTAssertEqual(XcodeLinks.normalizedPath(" ./ios//App.xcodeproj/ "), "ios/App.xcodeproj")
        for bad in ["", "/a/App.xcodeproj", "~/App.xcodeproj", "../App.xcodeproj", "a/../App.xcodeproj",
                    "ios", "App.swift", "a\\b.xcodeproj", "App.xcodeproj/project.xcworkspace"] {
            XCTAssertNotNil(XcodeLinks.pathProblem(bad), bad)
            XCTAssertNil(XcodeLinks.normalizedPath(bad), bad)
        }
    }

    func testRelativePathOfChosenFile() throws {
        try mkdir("ios/App.xcodeproj")
        let outside = dir.appendingPathComponent("outside/Out.xcodeproj").path
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        XCTAssertEqual(try XcodeLinks.relativePath(of: (project as NSString).appendingPathComponent("ios/App.xcodeproj"), in: project).get(),
                       "ios/App.xcodeproj")
        XCTAssertThrowsError(try XcodeLinks.relativePath(of: outside, in: project).get(), "フォルダの外は選べない")
        XCTAssertThrowsError(try XcodeLinks.relativePath(of: (project as NSString).appendingPathComponent("ios"), in: project).get())
    }

    func testCandidatesAreShallowFirstWithFinderExclusions() throws {
        try mkdir("Root.xcodeproj")
        try mkdir("ios/App.xcodeproj")
        try mkdir("ios/App.xcworkspace")
        try mkdir("Pods/Pods.xcodeproj")
        try mkdir("node_modules/x/X.xcodeproj")
        try mkdir(".hidden/H.xcodeproj")
        try mkdir("a/b/c/d/Deep.xcodeproj")
        XCTAssertEqual(XcodeLinks.candidates(in: project), ["Root.xcodeproj", "ios/App.xcworkspace", "ios/App.xcodeproj"])
    }

    // MARK: - settings.json の互換

    func testXcodeKeyRoundTripsAndIsOmittedWhenAbsent() throws {
        let settings = DeckSettings(projects: [
            ManagedProject(name: "a", path: "/a", xcode: .path("ios/App.xcodeproj")),
            ManagedProject(name: "b", path: "/b", xcode: .disabled),
            ManagedProject(name: "c", path: "/c"),
        ])
        let data = try settings.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
        XCTAssertEqual(projects[0]["xcode"] as? [String: String], ["path": "ios/App.xcodeproj"])
        XCTAssertEqual(projects[1]["xcode"] as? [String: Bool], ["disabled": true])
        XCTAssertNil(projects[2]["xcode"], "無いプロジェクトにはキーを出さない")
        XCTAssertEqual(object["version"] as? Int, DeckSettings.currentVersion)
        guard case .loaded(let loaded) = SettingsFile.decode(data) else { return XCTFail() }
        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(SettingsValidation.warnings(loaded), [])
    }

    func testMissingKeyMeansAuto() throws {
        let json = #"{"version":1,"projects":[{"id":"\#(UUID().uuidString)","name":"a","path":"/a","status":"active"}]}"#
        guard case .loaded(let settings) = SettingsFile.decode(Data(json.utf8)) else { return XCTFail() }
        XCTAssertNil(settings.projects[0].xcode)
        XCTAssertEqual(SettingsValidation.warnings(settings), [])
    }

    func testBrokenXcodeShapeIsIgnoredWithWarning() throws {
        let head = #"{"version":1,"projects":[{"id":"\#(UUID().uuidString)","name":"a","path":"/a","status":"active","xcode":"#
        for xcode in [#""ios/App.xcodeproj""#, "{}", #"{"path":1}"#, #"{"disabled":"yes"}"#, #"{"disabled":false}"#, "[]", "true"] {
            guard case .loaded(let settings) = SettingsFile.decode(Data((head + xcode + "}]}").utf8)) else { return XCTFail(xcode) }
            XCTAssertNil(settings.projects[0].xcode, xcode)
            XCTAssertEqual(SettingsValidation.warnings(settings).count, 1, xcode)
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: settings.encoded()) as? [String: Any])
            XCTAssertNil((saved["projects"] as? [[String: Any]])?.first?["xcode"], "読めなかった xcode は書かない")
        }
        guard case .loaded(let nullXcode) = SettingsFile.decode(Data((head + "null}]}").utf8)) else { return XCTFail() }
        XCTAssertNil(nullXcode.projects[0].xcode)
        XCTAssertEqual(SettingsValidation.warnings(nullXcode), [])
        // 両方あれば使わない方。
        guard case .loaded(let both) = SettingsFile.decode(Data((head + #"{"path":"A.xcodeproj","disabled":true}}]}"#).utf8)) else { return XCTFail() }
        XCTAssertEqual(both.projects[0].xcode, .disabled)
    }

    func testInvalidConfiguredPathIsWarning() {
        let settings = DeckSettings(projects: [ManagedProject(name: "a", path: "/a", xcode: .path("../x.xcodeproj"))])
        XCTAssertEqual(SettingsValidation.warnings(settings).count, 1)
        XCTAssertEqual(SettingsValidation.blockingProblems(settings), [])
    }

    func testImportFillsXcodeOnlyWhenMissing() throws {
        let path = "/p"
        let incoming = DeckSettings(projects: [ManagedProject(name: "p", path: path, xcode: .disabled)])
        let (merged, _) = try SettingsImport.merge(incoming.encoded(), into: DeckSettings(projects: [ManagedProject(name: "p", path: path)]))
        XCTAssertEqual(merged.projects[0].xcode, .disabled)
        let mine = DeckSettings(projects: [ManagedProject(name: "p", path: path, xcode: .path("A.xcodeproj"))])
        let (kept, _) = try SettingsImport.merge(incoming.encoded(), into: mine)
        XCTAssertEqual(kept.projects[0].xcode, .path("A.xcodeproj"))
    }
}
