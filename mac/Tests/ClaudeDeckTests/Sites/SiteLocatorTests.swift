import XCTest
@testable import MonitorKit

final class SiteLocatorTests: XCTestCase {
    var dir: URL!
    var project: String { dir.appendingPathComponent("proj").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("site-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir.appendingPathComponent("proj").path, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func touch(_ relative: String, in base: String? = nil) throws {
        let path = ((base ?? project) as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
    }

    func testNormalizesRelativePaths() {
        XCTAssertEqual(SiteLocator.normalizedRelativePath("site").path, "site")
        XCTAssertEqual(SiteLocator.normalizedRelativePath(" ./site/ ").path, "site")
        XCTAssertEqual(SiteLocator.normalizedRelativePath("apps//web").path, "apps/web")
        XCTAssertEqual(SiteLocator.normalizedRelativePath(".").path, ".")
        XCTAssertEqual(SiteLocator.normalizedRelativePath("./").path, ".")
    }

    func testRejectsAbsoluteAndEscapingPaths() {
        for bad in ["", "  ", "/Users/x/site", "~/site", "../other", "site/../../x", "a/..", "a\\b"] {
            XCTAssertNotNil(SiteLocator.normalizedRelativePath(bad).failure, bad)
            XCTAssertNotNil(SettingsValidation.sitePathProblem(bad), bad)
        }
        XCTAssertNil(SettingsValidation.sitePathProblem("site"))
    }

    func testDetectsSubdirectorySiteAndPrefersExported() throws {
        try touch("site/next.config.ts")
        try touch("site/out/index.html")
        try touch("docs/next.config.mjs")
        try touch("site/node_modules/pkg/next.config.js")
        XCTAssertEqual(SiteLocator.candidates(projectPath: project), ["site", "docs"])
        let lookup = SiteLocator.lookup(projectPath: project, configured: nil)
        XCTAssertEqual(lookup.location?.relativePath, "site")
        XCTAssertEqual(lookup.location?.source, .detected)
        XCTAssertEqual(lookup.location?.exportDir, (project as NSString).appendingPathComponent("site/out"))
    }

    func testDetectsRootSiteAndDoesNotLookInsideIt() throws {
        try touch("next.config.ts")
        try touch("examples/demo/next.config.js")
        XCTAssertEqual(SiteLocator.candidates(projectPath: project), ["."])
        XCTAssertEqual(SiteLocator.lookup(projectPath: project, configured: nil).location?.root, project)
    }

    func testPackageJSONWithExportCountsAsSite() throws {
        try touch("web/package.json")
        try touch("web/out/index.html")
        try touch("server/package.json")
        try touch(".hidden/next.config.js")
        try touch("out/next.config.js")
        XCTAssertEqual(SiteLocator.candidates(projectPath: project), ["web"])
    }

    func testSearchesOnlyShallowDepth() throws {
        try touch("a/b/next.config.js")
        try touch("a/b/c/d/next.config.js")
        XCTAssertEqual(SiteLocator.candidates(projectPath: project), ["a/b"])
    }

    func testNothingFound() {
        let lookup = SiteLocator.lookup(projectPath: project, configured: nil)
        XCTAssertNil(lookup.location)
        XCTAssertEqual(lookup.candidates, [])
        XCTAssertNil(lookup.problem)
    }

    func testConfiguredWinsOverDetection() throws {
        try touch("site/next.config.ts")
        try touch("lp/index.html")
        let lookup = SiteLocator.lookup(projectPath: project, configured: "lp")
        XCTAssertEqual(lookup.location?.relativePath, "lp")
        XCTAssertEqual(lookup.location?.source, .configured)
        XCTAssertEqual(lookup.candidates, ["site"])
    }

    func testConfiguredProblems() throws {
        XCTAssertNotNil(SiteLocator.lookup(projectPath: project, configured: "missing").problem)
        XCTAssertNil(SiteLocator.lookup(projectPath: project, configured: "missing").location)
        XCTAssertNotNil(SiteLocator.lookup(projectPath: project, configured: "../x").problem)
        // シンボリックリンクでプロジェクトの外を指すものは使わない。
        let outside = dir.appendingPathComponent("outside").path
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: (project as NSString).appendingPathComponent("link"), withDestinationPath: outside)
        let lookup = SiteLocator.lookup(projectPath: project, configured: "link")
        XCTAssertNil(lookup.location)
        XCTAssertNotNil(lookup.problem)
    }

    func testDetectionDoesNotFollowSymlinkedDirectories() throws {
        let outside = dir.appendingPathComponent("outside").path
        try touch("next.config.js", in: outside)
        try FileManager.default.createSymbolicLink(atPath: (project as NSString).appendingPathComponent("link"), withDestinationPath: outside)
        XCTAssertEqual(SiteLocator.candidates(projectPath: project), [])
    }

    func testRelativePathOfChosenFolder() throws {
        try FileManager.default.createDirectory(atPath: (project as NSString).appendingPathComponent("site"), withIntermediateDirectories: true)
        XCTAssertEqual(SiteLocator.relativePath(of: (project as NSString).appendingPathComponent("site"), in: project), "site")
        XCTAssertEqual(SiteLocator.relativePath(of: project, in: project), ".")
        XCTAssertNil(SiteLocator.relativePath(of: dir.path, in: project))
    }

    func testSiteIsWrittenOnlyWhenPresentAndRoundTrips() throws {
        var settings = DeckSettings(projects: [ManagedProject(name: "a", path: "/a", site: ProjectSite(path: "site")),
                                               ManagedProject(name: "b", path: "/b")])
        let data = try settings.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
        XCTAssertEqual((projects[0]["site"] as? [String: Any])?["path"] as? String, "site")
        XCTAssertNil(projects[1]["site"], "無いプロジェクトにはキーを出さない")
        XCTAssertEqual(object["version"] as? Int, 1)
        guard case .loaded(let loaded) = SettingsFile.decode(data) else { return XCTFail() }
        XCTAssertEqual(loaded, settings)
        // 不正な相対パスは警告として読める（上書きはしない）。
        settings.projects[1].site = ProjectSite(path: "../x")
        XCTAssertEqual(SettingsValidation.warnings(settings).count, 1)
        XCTAssertEqual(SettingsValidation.blockingProblems(settings), [])
    }

    func testBrokenSiteShapeIsUnreadable() {
        let head = #"{"version":1,"projects":[{"id":"\#(UUID().uuidString)","name":"a","path":"/a","status":"active","site":"#
        for site in [#""site""#, "{}", #"{"path":1}"#] {
            guard case .unreadable = SettingsFile.decode(Data((head + site + "}]}").utf8)) else { return XCTFail(site) }
        }
        guard case .loaded(let settings) = SettingsFile.decode(Data((head + "null}]}").utf8)) else { return XCTFail() }
        XCTAssertNil(settings.projects[0].site)
    }

    func testImportFillsSiteOnlyWhenMissing() throws {
        let path = "/p"
        let mine = DeckSettings(projects: [ManagedProject(name: "p", path: path)])
        let incoming = DeckSettings(projects: [ManagedProject(name: "p", path: path, site: ProjectSite(path: "site"))])
        let (merged, _) = try SettingsImport.merge(incoming.encoded(), into: mine)
        XCTAssertEqual(merged.projects[0].site, ProjectSite(path: "site"))
        var kept = mine
        kept.projects[0].site = ProjectSite(path: "lp")
        let (unchanged, _) = try SettingsImport.merge(incoming.encoded(), into: kept)
        XCTAssertEqual(unchanged.projects[0].site, ProjectSite(path: "lp"))
    }
}
