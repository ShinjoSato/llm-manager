import XCTest
@testable import MonitorKit

final class AppStoreCandidatesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("asc-cand-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, _ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func pbxproj(_ settings: [String]) -> String {
        """
        // !$*UTF8*$!
        {
            objects = {
                1A /* Debug */ = {
                    isa = XCBuildConfiguration;
                    buildSettings = {
        \(settings.map { "                \($0);" }.joined(separator: "\n"))
                    };
                };
            };
        }
        """
    }

    private let apps = [
        AppStoreApp(id: "111", name: "Notes", bundleId: "com.example.notes"),
        AppStoreApp(id: "222", name: "Notes Dev", bundleId: "com.example.notes.dev"),
        AppStoreApp(id: "333", name: "Other", bundleId: "org.sample.other"),
        AppStoreApp(id: "444", name: "Deck", bundleId: "local.sample.ios"),
    ]

    func testReadsAppStoreJSONAndLiteralBundleIDs() throws {
        try write(#"{"appId": "333", "platform": "ios"}"#, ".claude/appstore.json")
        try write(pbxproj(["PRODUCT_BUNDLE_IDENTIFIER = com.example.notes", "PRODUCT_BUNDLE_IDENTIFIER = \"com.example.notes.tests\""]),
                  "App/Notes.xcodeproj/project.pbxproj")
        let hints = AppStoreCandidates.hints(projectPath: root.path)
        XCTAssertEqual(hints.configuredAppId, "333")
        XCTAssertEqual(hints.configuredPlatform, "IOS")
        XCTAssertEqual(hints.bundleIdentifiers, ["com.example.notes", "com.example.notes.tests"])
        XCTAssertTrue(hints.bundleTemplates.isEmpty)
        let candidates = AppStoreCandidates.match(apps: apps, hints: hints)
        XCTAssertEqual(candidates.map(\.app.id), ["333", "111"])
        XCTAssertEqual(candidates.map(\.reason), [.appStoreJSON, .bundleID("com.example.notes")])
    }

    func testResolvesVariablesFromXcconfigAndProject() throws {
        try write("DECK_BUNDLE_PREFIX = local.sample // 既定\n#include \"Local.xcconfig\"\n", "config/Deck.xcconfig")
        try write(pbxproj(["PRODUCT_BUNDLE_IDENTIFIER = \"$(DECK_BUNDLE_PREFIX).ios\"",
                           "PRODUCT_BUNDLE_IDENTIFIER = \"${BASE_ID:lower}.dev\"",
                           "BASE_ID = COM.EXAMPLE.NOTES"]),
                  "ios/Deck.xcodeproj/project.pbxproj")
        let hints = AppStoreCandidates.hints(projectPath: root.path)
        XCTAssertEqual(Set(hints.bundleIdentifiers), ["local.sample.ios", "com.example.notes.dev"])
        let candidates = AppStoreCandidates.match(apps: apps, hints: hints)
        XCTAssertEqual(Set(candidates.map(\.app.id)), ["444", "222"])
    }

    /// 解決できない変数は、決まった前の部分が十分ある時だけ、1 件にだけ合う場合に当てる。
    func testUnresolvedTemplatesAreConservative() throws {
        try write(pbxproj(["PRODUCT_BUNDLE_IDENTIFIER = \"org.sample.$(PRODUCT_NAME:rfc1034identifier)\"",
                           "PRODUCT_BUNDLE_IDENTIFIER = \"$(UNKNOWN_PREFIX).ios\"",
                           "PRODUCT_BUNDLE_IDENTIFIER = \"com.example.$(TARGET_NAME)\""]),
                  "A.xcodeproj/project.pbxproj")
        let hints = AppStoreCandidates.hints(projectPath: root.path)
        XCTAssertTrue(hints.bundleIdentifiers.isEmpty)
        XCTAssertEqual(hints.bundleTemplates.count, 3)
        let candidates = AppStoreCandidates.match(apps: apps, hints: hints)
        // org.sample.* は 1 件だけ合う。$(X).ios は前が無いので当てない。com.example.* は 2 件に合うので当てない。
        XCTAssertEqual(candidates.map(\.app.id), ["333"])
        XCTAssertEqual(candidates.first?.reason, .bundleTemplate("org.sample.$(PRODUCT_NAME:rfc1034identifier)"))
        XCTAssertNil(AppStoreCandidates.templateRegex("$(A).b.c"))
        XCTAssertNil(AppStoreCandidates.templateRegex("com.$(A)"))
        XCTAssertNotNil(AppStoreCandidates.templateRegex("com.example.$(A)"))
    }

    func testSkipsDependencyFoldersAndDeepTrees() throws {
        try write(pbxproj(["PRODUCT_BUNDLE_IDENTIFIER = com.example.notes"]), "node_modules/pkg/X.xcodeproj/project.pbxproj")
        try write(pbxproj(["PRODUCT_BUNDLE_IDENTIFIER = com.example.notes"]), ".build/X.xcodeproj/project.pbxproj")
        try write(pbxproj(["PRODUCT_BUNDLE_IDENTIFIER = com.example.notes"]), "a/b/c/d/e/X.xcodeproj/project.pbxproj")
        let hints = AppStoreCandidates.hints(projectPath: root.path)
        XCTAssertTrue(hints.isEmpty)
        XCTAssertTrue(AppStoreCandidates.match(apps: apps, hints: hints).isEmpty)
    }

    func testBrokenAppStoreJSONIsIgnored() throws {
        try write(#"{"appId": "not-a-number"}"#, ".claude/appstore.json")
        XCTAssertNil(AppStoreCandidates.hints(projectPath: root.path).configuredAppId)
        try write("[1, 2]", ".claude/appstore.json")
        XCTAssertNil(AppStoreCandidates.hints(projectPath: root.path).configuredAppId)
        try write(#"{"appId": 123456}"#, ".claude/appstore.json")
        XCTAssertEqual(AppStoreCandidates.hints(projectPath: root.path).configuredAppId, "123456")
        try write(#"{"appId": true}"#, ".claude/appstore.json")
        XCTAssertNil(AppStoreCandidates.hints(projectPath: root.path).configuredAppId)
    }

    func testConfiguredAppIdNotInListIsNotACandidate() {
        let hints = AppStoreProjectHints(configuredAppId: "999")
        XCTAssertTrue(AppStoreCandidates.match(apps: apps, hints: hints).isEmpty)
    }

    func testTemplateSplitAndResolve() {
        XCTAssertEqual(BuildSettingTemplate.split("a.$(B).${C:lower}"),
                       [.literal("a."), .variable(name: "B", modifier: nil), .literal("."), .variable(name: "C", modifier: "lower")])
        XCTAssertEqual(BuildSettingTemplate.resolve("x.$(A)", settings: ["A": ["$(inherited) y", "z"]]), ["x.y", "x.z"])
        XCTAssertNil(BuildSettingTemplate.resolve("x.$(A)", settings: [:]))
        XCTAssertNil(BuildSettingTemplate.resolve("x.$(A:suffix)", settings: ["A": ["y"]]))
        // 自分を指す値で回り続けない。
        XCTAssertNil(BuildSettingTemplate.resolve("$(A)", settings: ["A": ["$(A)"]]))
        XCTAssertEqual(BuildSettingTemplate.resolve("p.$(A:rfc1034identifier)", settings: ["A": ["My App"]]), ["p.My-App"])
    }
}
