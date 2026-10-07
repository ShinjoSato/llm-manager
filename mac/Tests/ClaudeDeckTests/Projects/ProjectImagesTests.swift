import XCTest
@testable import MonitorKit

final class ProjectImagesTests: XCTestCase {
    var dir: URL!
    var project: String { dir.appendingPathComponent("proj").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("project-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func touch(_ relative: String, in base: String? = nil, bytes: Int = 1) throws {
        let path = ((base ?? project) as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 0, count: bytes))
    }

    private func paths(_ scan: ProjectImageScan) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: scan.groups.map { ($0.relativePath, $0.images.map(\.relativePath)) })
    }

    func testCollectsImagesByExtensionIgnoringCaseAndOtherFiles() throws {
        try touch("logo.png", bytes: 12)
        try touch("photo.JPG")
        try touch("icon.svg")
        try touch("readme.md")
        try touch("Contents.json")
        try touch("movie.mp4")
        let scan = ProjectImages.scan(projectPath: project)
        XCTAssertEqual(paths(scan), [".": ["icon.svg", "logo.png", "photo.JPG"]])
        XCTAssertFalse(scan.truncated)
        XCTAssertEqual(scan.count, 3)
        let logo = scan.groups[0].images.first { $0.name == "logo.png" }
        XCTAssertEqual(logo?.fileSize, 12)
        XCTAssertEqual(logo?.path, (project as NSString).appendingPathComponent("logo.png"))
        XCTAssertNotNil(logo?.modified)
    }

    func testSkipsHiddenAndBuildFolders() throws {
        try touch("assets/a.png")
        try touch(".git/objects/x.png")
        try touch(".hidden.png")
        for skipped in ["node_modules", ".next", "out", "build", "dist", "Pods", "DerivedData", "vendor", ".build", ".swiftpm"] {
            try touch("\(skipped)/pkg/img.png")
            try touch("site/\(skipped)/img.png")
        }
        let scan = ProjectImages.scan(projectPath: project)
        XCTAssertEqual(paths(scan), ["assets": ["assets/a.png"]])
    }

    func testGroupsXcassetsAsOneFolderAndOrdersShallowThenName() throws {
        try touch("ios/App/Assets.xcassets/AppIcon.appiconset/icon-60.png")
        try touch("ios/App/Assets.xcassets/AppIcon.appiconset/Contents.json")
        try touch("ios/App/Assets.xcassets/Logo.imageset/logo@2x.png")
        try touch("ios/App/Assets.xcassets/Contents.json")
        try touch("web/public/hero.webp")
        try touch("docs/b.png")
        try touch("docs/a10.png")
        try touch("docs/a2.png")
        try touch("top.gif")
        let scan = ProjectImages.scan(projectPath: project)
        XCTAssertEqual(scan.groups.map(\.relativePath), [".", "docs", "web/public", "ios/App/Assets.xcassets"])
        XCTAssertEqual(scan.groups[1].images.map(\.name), ["a2.png", "a10.png", "b.png"])
        XCTAssertEqual(scan.groups[3].images.map(\.relativePath),
                       ["ios/App/Assets.xcassets/AppIcon.appiconset/icon-60.png", "ios/App/Assets.xcassets/Logo.imageset/logo@2x.png"])
    }

    func testGroupPath() {
        XCTAssertEqual(ProjectImages.groupPath(for: "a.png"), ".")
        XCTAssertEqual(ProjectImages.groupPath(for: "x/y/a.png"), "x/y")
        XCTAssertEqual(ProjectImages.groupPath(for: "x/A.xcassets/B.imageset/a.png"), "x/A.xcassets")
        XCTAssertEqual(ProjectImages.groupPath(for: "x/A.XCASSETS/a.png"), "x/A.XCASSETS")
    }

    func testDepthLimit() throws {
        try touch("d1/d2/d3/deep.png")
        try touch("d1/d2/d3/d4/deeper.png")
        let scan = ProjectImages.scan(projectPath: project, maxDepth: 3)
        XCTAssertEqual(paths(scan), ["d1/d2/d3": ["d1/d2/d3/deep.png"]])
        XCTAssertFalse(scan.truncated)
        XCTAssertEqual(ProjectImages.scan(projectPath: project).count, 2)
    }

    func testCountLimitStopsAtShallowFilesAndFlagsTruncation() throws {
        try touch("a.png")
        try touch("b.png")
        try touch("sub/c.png")
        try touch("sub/d.png")
        let scan = ProjectImages.scan(projectPath: project, maxCount: 3)
        XCTAssertTrue(scan.truncated)
        XCTAssertEqual(scan.count, 3)
        XCTAssertEqual(paths(scan), [".": ["a.png", "b.png"], "sub": ["sub/c.png"]])
        let exact = ProjectImages.scan(projectPath: project, maxCount: 4)
        XCTAssertFalse(exact.truncated)
        XCTAssertEqual(exact.count, 4)
    }

    func testSymlinksOutsideProjectAreNotFollowed() throws {
        let outside = dir.appendingPathComponent("outside").path
        try touch("secret.png", in: outside)
        try touch("imgs/real.png", in: outside)
        try touch("inside/target.png", bytes: 5)
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: (project as NSString).appendingPathComponent("linked.png"),
                                  withDestinationPath: (outside as NSString).appendingPathComponent("secret.png"))
        try fm.createSymbolicLink(atPath: (project as NSString).appendingPathComponent("linkdir"),
                                  withDestinationPath: (outside as NSString).appendingPathComponent("imgs"))
        try fm.createSymbolicLink(atPath: (project as NSString).appendingPathComponent("alias.png"),
                                  withDestinationPath: (project as NSString).appendingPathComponent("inside/target.png"))
        try fm.createSymbolicLink(atPath: (project as NSString).appendingPathComponent("loop"), withDestinationPath: project)
        let scan = ProjectImages.scan(projectPath: project)
        XCTAssertEqual(paths(scan), [".": ["alias.png"], "inside": ["inside/target.png"]])
        XCTAssertEqual(scan.groups[0].images[0].fileSize, 5)
    }

    func testMissingProjectYieldsEmptyScan() {
        let scan = ProjectImages.scan(projectPath: dir.appendingPathComponent("nope").path)
        XCTAssertTrue(scan.groups.isEmpty)
        XCTAssertFalse(scan.truncated)
    }
}
