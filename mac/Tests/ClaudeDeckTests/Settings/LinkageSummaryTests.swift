import XCTest
@testable import MonitorKit

final class LinkageSummaryTests: XCTestCase {
    func testGitHub() {
        XCTAssertEqual(LinkageSummary.github(nil), "なし")
        XCTAssertEqual(LinkageSummary.github(GitHubLink(owner: "ShinjoSato", repo: "llm-manager", projectNumber: 8)), "ShinjoSato/llm-manager #8")
        XCTAssertEqual(LinkageSummary.github(GitHubLink(owner: "ShinjoSato", projectNumber: 3)), "ShinjoSato #3")
        XCTAssertEqual(LinkageSummary.github(GitHubLink(owner: " o ", repo: " ")), "o")
        XCTAssertEqual(LinkageSummary.github(GitHubLink(owner: "", projectNumber: 2)), "#2")
        XCTAssertEqual(LinkageSummary.github(GitHubLink(owner: "")), "なし")
        XCTAssertEqual(LinkageSummary.github(GitHubLink(owner: " ", repo: "llm-manager")), "llm-manager")
        XCTAssertEqual(LinkageSummary.github(GitHubLink(owner: "", repo: "llm-manager", projectNumber: 8)), "llm-manager #8")
    }

    func testXcode() {
        XCTAssertEqual(LinkageSummary.xcode(nil, detected: "ios/App.xcodeproj", scanned: true), "自動（ios/App.xcodeproj）")
        XCTAssertEqual(LinkageSummary.xcode(nil, detected: nil, scanned: true), "自動（見つかりません）")
        XCTAssertEqual(LinkageSummary.xcode(nil, detected: nil, scanned: false), "自動（探しています…）")
        XCTAssertEqual(LinkageSummary.xcode(.path("App.xcworkspace"), detected: "ios/App.xcodeproj", scanned: true), "指定（App.xcworkspace）")
        XCTAssertEqual(LinkageSummary.xcode(.disabled, detected: "ios/App.xcodeproj", scanned: true), "使わない")
        XCTAssertEqual(LinkageSummary.xcode(nil, detected: nil, scanned: true, choosing: true), "指定（未選択）")
        XCTAssertEqual(LinkageSummary.xcode(.disabled, detected: nil, scanned: true, choosing: true), "指定（未選択）")
        XCTAssertEqual(LinkageSummary.xcode(.path("A.xcodeproj"), detected: nil, scanned: true, choosing: true), "指定（A.xcodeproj）")
    }

    func testSite() {
        let detected = SiteLookup(location: SiteLocation(relativePath: "site", root: "/p/site", source: .detected), candidates: ["site"])
        XCTAssertEqual(LinkageSummary.site(configured: nil, lookup: detected, exported: true), "自動（site）")
        XCTAssertEqual(LinkageSummary.site(configured: nil, lookup: detected, exported: false), "自動（site） · 書き出しなし")
        let root = SiteLookup(location: SiteLocation(relativePath: ".", root: "/p", source: .configured), candidates: [])
        XCTAssertEqual(LinkageSummary.site(configured: ProjectSite(path: "."), lookup: root, exported: true), "指定（直下）")
        XCTAssertEqual(LinkageSummary.site(configured: nil, lookup: SiteLookup(location: nil, candidates: []), exported: false), "見つかりません")
        let broken = SiteLookup(location: nil, candidates: [], problem: "見つかりません")
        XCTAssertEqual(LinkageSummary.site(configured: ProjectSite(path: "web"), lookup: broken, exported: false), "指定（web）")
        XCTAssertEqual(LinkageSummary.site(configured: nil, lookup: nil, exported: false), "自動（探しています…）")
        XCTAssertEqual(LinkageSummary.site(configured: ProjectSite(path: "web"), lookup: nil, exported: false), "指定（web）")
    }

    func testCount() {
        XCTAssertEqual(LinkageSummary.count(0), "なし")
        XCTAssertEqual(LinkageSummary.count(2), "2 件")
    }

    func testFirstLine() {
        XCTAssertEqual(LinkageSummary.firstLine("npm run dev"), "npm run dev")
        XCTAssertEqual(LinkageSummary.firstLine("\n  cd site \nnpm run dev\n"), "cd site …")
        XCTAssertEqual(LinkageSummary.firstLine(" \n "), "")
    }
}
