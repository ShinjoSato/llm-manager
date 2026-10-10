import XCTest
@testable import MonitorKit

final class DirectoryTabsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DirectoryTabsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testOrderAndLabels() {
        XCTAssertEqual(DirectoryTab.allCases, [.site, .images, .iosPreviews, .links, .threads])
        XCTAssertEqual(DirectoryTab.allCases.map(\.label), ["サイト", "画像", "iPhone", "リンク", "スレッド"])
        XCTAssertEqual(Set(DirectoryTab.allCases.map(\.symbol)).count, DirectoryTab.allCases.count)
    }

    func testAvailableHidesSiteAndIPhoneWhenMissing() {
        XCTAssertEqual(DirectoryTabs.available(hasSite: true, hasXcodeProject: true),
                       [.site, .images, .iosPreviews, .links, .threads])
        XCTAssertEqual(DirectoryTabs.available(hasSite: false, hasXcodeProject: true),
                       [.images, .iosPreviews, .links, .threads])
        XCTAssertEqual(DirectoryTabs.available(hasSite: true, hasXcodeProject: false),
                       [.site, .images, .links, .threads])
        XCTAssertEqual(DirectoryTabs.available(hasSite: false, hasXcodeProject: false),
                       [.images, .links, .threads])
    }

    /// 探している間はサイトを出しておき、無いと分かってから消す（並びが後からずれない）。
    func testSiteStaysUntilKnown() {
        XCTAssertEqual(DirectoryTabs.available(hasSite: nil, hasXcodeProject: false),
                       [.site, .images, .links, .threads])
    }

    func testHasSiteFromLookup() {
        let location = SiteLocation(relativePath: "lp", root: "/tmp/p/lp", source: .detected)
        XCTAssertTrue(DirectoryTabs.hasSite(SiteLookup(location: location, candidates: ["lp"])))
        XCTAssertFalse(DirectoryTabs.hasSite(SiteLookup(location: nil, candidates: [])))
        // 設定の場所が使えない時は理由を見せるために出す。
        XCTAssertTrue(DirectoryTabs.hasSite(SiteLookup(location: nil, candidates: [], problem: "指定のフォルダ（lp）が見つかりません")))
    }

    func testResolveKeepsRememberedTab() {
        let all = DirectoryTabs.available(hasSite: true, hasXcodeProject: true)
        XCTAssertEqual(DirectoryTabs.resolve(remembered: .links, available: all), .links)
        XCTAssertEqual(DirectoryTabs.resolve(remembered: .iosPreviews, available: all), .iosPreviews)
    }

    func testResolveStartsAtFirstAvailable() {
        XCTAssertEqual(DirectoryTabs.resolve(remembered: nil, available: [.site, .images, .links, .threads]), .site)
        XCTAssertEqual(DirectoryTabs.resolve(remembered: nil, available: [.images, .links, .threads]), .images)
        XCTAssertEqual(DirectoryTabs.resolve(remembered: nil, available: []), .images)
    }

    func testResolveFallsBackToFirstWhenRememberedIsGone() {
        // Xcode のプロジェクトを消した・サイトが無くなった時は先頭へ戻る。
        XCTAssertEqual(DirectoryTabs.resolve(remembered: .iosPreviews, available: [.site, .images, .links, .threads]), .site)
        XCTAssertEqual(DirectoryTabs.resolve(remembered: .site, available: [.images, .iosPreviews, .links, .threads]), .images)
        // サイトを探している間は覚えたサイトのまま開き、無いと分かったら先頭へ。
        XCTAssertEqual(DirectoryTabs.resolve(remembered: .site,
                                             available: DirectoryTabs.available(hasSite: nil, hasXcodeProject: false)), .site)
        XCTAssertEqual(DirectoryTabs.resolve(remembered: .site,
                                             available: DirectoryTabs.available(hasSite: false, hasXcodeProject: false)), .images)
    }

    func testMemoryIsPerProject() {
        let memory = DirectoryTabMemory(defaults: defaults)
        let a = UUID()
        let b = UUID()
        XCTAssertNil(memory.remembered(for: a))
        memory.remember(.links, for: a)
        memory.remember(.threads, for: b)
        XCTAssertEqual(memory.remembered(for: a), .links)
        XCTAssertEqual(memory.remembered(for: b), .threads)
        memory.remember(.images, for: a)
        XCTAssertEqual(memory.remembered(for: a), .images)
        XCTAssertEqual(defaults.string(forKey: DirectoryTabMemory.key(for: a)), "images")
        XCTAssertTrue(DirectoryTabMemory.key(for: a).hasPrefix(DirectoryTabMemory.keyPrefix))
    }

    func testMemoryIgnoresUnknownValues() {
        let memory = DirectoryTabMemory(defaults: defaults)
        let id = UUID()
        defaults.set("overview", forKey: DirectoryTabMemory.key(for: id))
        XCTAssertNil(memory.remembered(for: id))
        let tab = DirectoryTabs.resolve(remembered: memory.remembered(for: id),
                                        available: DirectoryTabs.available(hasSite: false, hasXcodeProject: true))
        XCTAssertEqual(tab, .images)
    }
}
