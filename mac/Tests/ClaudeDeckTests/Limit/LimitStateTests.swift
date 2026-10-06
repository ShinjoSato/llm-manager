import XCTest
@testable import MonitorKit

final class LimitStateTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("limit-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func usage(_ percent: Double, age: TimeInterval) -> UsageSnapshot {
        UsageSnapshot(fetchedAt: (now.timeIntervalSince1970 - age) * 1000,
                      fiveHour: UsageWindow(usedPercentage: percent, resetsAt: (now.timeIntervalSince1970 + 3600) * 1000),
                      sevenDay: nil)
    }

    func testSaveLoadAndClearWithOwnerOnlyPermissions() throws {
        let file = LimitStateFile(url: dir.appendingPathComponent("limit-state.json"))
        let record = LimitStateRecord(until: now.addingTimeInterval(3600), reason: "5 時間の使用率が 100% に達しました")
        try file.save(record)
        XCTAssertEqual(file.load(now: now), record)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // 解けた後の記録は読まない。
        XCTAssertNil(file.load(now: now.addingTimeInterval(3600)))
        try file.save(nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        // 無いものを消しても失敗しない。
        try file.save(nil)
    }

    func testBrokenOrUnknownVersionIsIgnored() throws {
        let url = dir.appendingPathComponent("limit-state.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: url)
        XCTAssertNil(LimitStateFile(url: url).load(now: now))
        try Data(#"{"version":9,"until":9999999999999}"#.utf8).write(to: url)
        XCTAssertNil(LimitStateFile(url: url).load(now: now))
    }

    func testEnvironmentOverridesDefaultLocation() {
        XCTAssertEqual(LimitStateFile.defaultURL(environment: [LimitStateFile.environmentKey: "/tmp/x/limit.json"]).path, "/tmp/x/limit.json")
        XCTAssertEqual(LimitStateFile.defaultURL(environment: [:]).deletingLastPathComponent().path, DeckPaths.applicationSupport.path)
    }

    func testRestoredLatchWinsOverStaleUsageUntilReset() {
        let record = LimitStateRecord(until: now.addingTimeInterval(1800))
        var latch = UsageLimitLatch(restoring: record, now: now)
        XCTAssertTrue(latch.update(with: nil, now: now))
        XCTAssertTrue(latch.update(with: usage(3, age: LimitGuard.freshness + 60), now: now))
        XCTAssertEqual(latch.record?.untilDate, record.untilDate)
        XCTAssertFalse(latch.update(with: nil, now: now.addingTimeInterval(1800)))
        XCTAssertNil(latch.record)
    }

    func testFreshUsageBelowLimitClearsRestoredLatch() {
        var latch = UsageLimitLatch(restoring: LimitStateRecord(until: now.addingTimeInterval(1800)), now: now)
        XCTAssertFalse(latch.update(with: usage(10, age: 5), now: now))
    }

    func testExpiredRecordDoesNotRestore() {
        var latch = UsageLimitLatch(restoring: LimitStateRecord(until: now.addingTimeInterval(-1)), now: now)
        XCTAssertFalse(latch.update(with: nil, now: now))
    }

    func testFreshHitIsRecordedWithReason() {
        var latch = UsageLimitLatch()
        XCTAssertTrue(latch.update(with: usage(100, age: 5), now: now))
        XCTAssertEqual(latch.record?.untilDate, now.addingTimeInterval(3600))
        XCTAssertEqual(latch.record?.reason, "5 時間の使用率が 100% に達しました")
    }

    func testAlertMessageCombinesNamesIntoOne() {
        XCTAssertTrue(LimitAlertText.message(names: ["a", "b", "a"]).hasPrefix("「a」「b」のセッションを強制終了しました。"))
        XCTAssertTrue(LimitAlertText.message(names: ["a", "b", "c", "d", "e"]).hasPrefix("「a」「b」「c」 ほか 2 件のセッション"))
    }
}
