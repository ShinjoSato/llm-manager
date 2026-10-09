import XCTest
@testable import MonitorKit

final class XcodeSelectionTests: XCTestCase {
    private let release = RunningXcode(pid: 100, bundlePath: "/Applications/Xcode.app")
    private let beta = RunningXcode(pid: 200, bundlePath: "/Applications/Xcode-beta.app/")

    func testNoneRunning() {
        XCTAssertNil(XcodeSelection.target(running: [], selectedDeveloperDir: "/Applications/Xcode.app/Contents/Developer"))
    }

    func testSingleXcodeIsUsedWithItsDeveloperDir() {
        // xcode-select と違う版でも、動いている Xcode の mcpbridge を使う。
        let target = XcodeSelection.target(running: [beta], selectedDeveloperDir: "/Applications/Xcode.app/Contents/Developer")
        XCTAssertEqual(target, XcodeBridgeTarget(pid: 200, developerDir: "/Applications/Xcode-beta.app/Contents/Developer"))
        XCTAssertNil(target?.notice)
    }

    func testMultiplePrefersXcodeSelect() {
        let target = XcodeSelection.target(running: [beta, release], selectedDeveloperDir: "/Applications/Xcode.app/Contents/Developer/")
        XCTAssertEqual(target, XcodeBridgeTarget(pid: 100, developerDir: "/Applications/Xcode.app/Contents/Developer"))
    }

    func testMultipleWithoutSelectedPassesNoPidAndShowsNotice() {
        let other = RunningXcode(pid: 300, bundlePath: "/Applications/Xcode-26.app")
        for selected in ["/Applications/Xcode-old.app/Contents/Developer", nil] {
            let target = XcodeSelection.target(running: [beta, other], selectedDeveloperDir: selected)
            XCTAssertNil(target?.pid)
            XCTAssertNil(target?.developerDir)
            XCTAssertEqual(target?.notice, XcodeSelection.ambiguousNotice)
        }
    }

    func testRecountingPicksUpNewPid() {
        // 起動のたびに数え直すので、Xcode を起動し直せば別の PID になり、mcpbridge を作り直す。
        let before = XcodeSelection.target(running: [release], selectedDeveloperDir: nil)!
        let restarted = XcodeSelection.target(running: [RunningXcode(pid: 101, bundlePath: "/Applications/Xcode.app")], selectedDeveloperDir: nil)!
        XCTAssertFalse(before.sameConnection(as: restarted))
        XCTAssertTrue(before.sameConnection(as: XcodeSelection.target(running: [release], selectedDeveloperDir: nil)!))
        // 版を替えた（同じ PID でも別の Developer フォルダ）時も作り直す。
        XCTAssertFalse(before.sameConnection(as: XcodeBridgeTarget(pid: 100, developerDir: "/Applications/Xcode-beta.app/Contents/Developer")))
    }

    func testEnvironment() {
        let base = ["PATH": "/usr/bin", "MCP_XCODE_PID": "1", "DEVELOPER_DIR": "/old"]
        let env = XcodeBridgeTarget(pid: 42, developerDir: "/Applications/Xcode.app/Contents/Developer").environment(base: base)
        XCTAssertEqual(env["DEVELOPER_DIR"], "/Applications/Xcode.app/Contents/Developer")
        XCTAssertEqual(env["PATH"], "/usr/bin")
        // PID は渡さない（GUI の Xcode へ直につなぐ形はウィンドウが無いと断られる）。親の環境にあっても消す。
        XCTAssertNil(env["MCP_XCODE_PID"])
        // どれにつなぐか決められない時は、xcode-select（親の DEVELOPER_DIR）のまま。
        let none = XcodeBridgeTarget(pid: nil, developerDir: nil).environment(base: base)
        XCTAssertNil(none["MCP_XCODE_PID"])
        XCTAssertEqual(none["DEVELOPER_DIR"], "/old")
    }

    func testSelectedDeveloperDirPrefersEnvironment() {
        XCTAssertEqual(XcodeSelection.selectedDeveloperDir(environment: ["DEVELOPER_DIR": "/x/Developer"]), "/x/Developer")
    }
}

final class PreviewQueueRulesTests: XCTestCase {
    func testStallStopsAfterTwoInARow() {
        var stalls = PreviewStallCounter()
        XCTAssertFalse(stalls.record(.timedOut(300)))
        XCTAssertTrue(stalls.record(.packagesLoading))
        // 止めたら数え直す。
        XCTAssertFalse(stalls.record(.timedOut(300)))
        // 間に別の結果（成功・別の失敗）が入れば続けてとはみなさない。
        XCTAssertFalse(stalls.record(nil))
        XCTAssertFalse(stalls.record(.timedOut(300)))
        XCTAssertFalse(stalls.record(.renderFailed("x")))
        XCTAssertFalse(stalls.record(.packagesLoading))
        XCTAssertTrue(stalls.record(.packagesLoading))
        XCTAssertTrue(PreviewStallCounter.message(.timedOut(300)).contains("300"))
    }

    func testSectionPresencePerProject() {
        let a = UUID(), b = UUID()
        var sections = PreviewSectionPresence()
        XCTAssertFalse(sections.anyOpen)
        sections.open(a)
        sections.open(a)
        sections.open(b)
        XCTAssertFalse(sections.close(a))
        XCTAssertTrue(sections.isOpen(a))
        // 別のプロジェクトへ移った（a の節が全部閉じた）ら a は閉じたとみなす。b は開いたまま。
        XCTAssertTrue(sections.close(a))
        XCTAssertFalse(sections.isOpen(a))
        XCTAssertTrue(sections.anyOpen)
        XCTAssertTrue(sections.close(b))
        XCTAssertFalse(sections.anyOpen)
        // 開いていないものを閉じても何も起きない。
        XCTAssertFalse(sections.close(b))
    }
}
