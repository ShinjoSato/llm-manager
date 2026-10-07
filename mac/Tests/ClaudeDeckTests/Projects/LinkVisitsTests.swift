import XCTest
@testable import MonitorKit

final class LinkVisitsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("link-visits-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testKeyUsesProjectIDAndNormalizedURL() {
        let id = UUID()
        XCTAssertEqual(LinkVisits.key(projectID: id, url: "  https://example.com/lp "), "\(id.uuidString)|https://example.com/lp")
        XCTAssertEqual(LinkVisits.key(projectID: id, url: "https://例え.jp/"), "\(id.uuidString)|https://xn--r8jz45g.jp/")
        XCTAssertNil(LinkVisits.key(projectID: id, url: "javascript:x"))
        XCTAssertNil(LinkVisits.key(projectID: id, url: ""))
    }

    func testRecordAndLastOpened() {
        let id = UUID()
        var visits = LinkVisits()
        let at = Date(timeIntervalSince1970: 1_700_000_000.5)
        visits.record(projectID: id, url: "https://a.example", at: at)
        XCTAssertEqual(visits.lastOpened(projectID: id, url: "https://a.example")?.timeIntervalSince1970 ?? 0, at.timeIntervalSince1970, accuracy: 0.001)
        // 同じ URL は前後の空白が違っても同じ記録。別のプロジェクトは別。
        XCTAssertNotNil(visits.lastOpened(projectID: id, url: " https://a.example "))
        XCTAssertNil(visits.lastOpened(projectID: UUID(), url: "https://a.example"))
        XCTAssertNil(visits.lastOpened(projectID: id, url: "https://b.example"))
        // 開けない URL は記録しない。
        visits.record(projectID: id, url: "nope", at: at)
        XCTAssertEqual(visits.visits.count, 1)
    }

    func testCarryCopiesToNewURLWithoutOverwriting() {
        let id = UUID()
        var visits = LinkVisits()
        visits.record(projectID: id, url: "https://old.example", at: Date(timeIntervalSince1970: 100))
        visits.carry(projectID: id, from: "https://old.example", to: "https://new.example")
        XCTAssertEqual(visits.lastOpened(projectID: id, url: "https://new.example")?.timeIntervalSince1970, 100)
        // 古い方は残る（起動時の片付けで消える）。
        XCTAssertEqual(visits.lastOpened(projectID: id, url: "https://old.example")?.timeIntervalSince1970, 100)
        // 新しい方に記録があればそのまま。
        visits.record(projectID: id, url: "https://newer.example", at: Date(timeIntervalSince1970: 500))
        visits.carry(projectID: id, from: "https://old.example", to: "https://newer.example")
        XCTAssertEqual(visits.lastOpened(projectID: id, url: "https://newer.example")?.timeIntervalSince1970, 500)
        // 元に記録が無い・開けない URL なら何もしない。
        let before = visits
        visits.carry(projectID: id, from: "https://none.example", to: "https://x.example")
        visits.carry(projectID: id, from: "https://old.example", to: "nope")
        XCTAssertEqual(visits, before)
    }

    func testPruneKeepsOnlyLinksInSettings() {
        let a = ManagedProject(name: "a", path: "/p/a", links: [ProjectLink(name: "LP", url: "https://a.example/lp"),
                                                               ProjectLink(name: "Bad", url: "nope")])
        let b = ManagedProject(name: "b", path: "/p/b")
        var visits = LinkVisits()
        let at = Date(timeIntervalSince1970: 1)
        visits.record(projectID: a.id, url: "https://a.example/lp", at: at)
        visits.record(projectID: a.id, url: "https://a.example/gone", at: at)
        visits.record(projectID: b.id, url: "https://a.example/lp", at: at)
        let pruned = visits.pruned(keeping: LinkVisits.keys(in: [a, b]))
        XCTAssertEqual(pruned.visits.keys.sorted(), [LinkVisits.key(projectID: a.id, url: "https://a.example/lp")!])
        XCTAssertEqual(pruned.version, LinkVisits.currentVersion)
    }

    func testSaveAndLoadRoundTripWithOwnerOnlyPermissions() throws {
        // 既定の置き場所と同じく、ディレクトリも締める。
        let file = LinkVisitsFile(url: dir.appendingPathComponent("link-visits.json"), restrictsDirectory: true)
        let id = UUID()
        var visits = LinkVisits()
        visits.record(projectID: id, url: "https://a.example/lp?x=1", at: Date(timeIntervalSince1970: 1_700_000_000))
        try file.save(visits)
        XCTAssertEqual(file.load(), visits)
        XCTAssertEqual(try mode(file.url), 0o600)
        XCTAssertEqual(try mode(dir), 0o700)
        // 人が読める形（キーに / をエスケープしない）。
        let text = try String(contentsOf: file.url, encoding: .utf8)
        XCTAssertTrue(text.contains("https://a.example/lp?x=1"), text)
        XCTAssertTrue(text.contains("\"version\" : 1"), text)
    }

    func testMissingBrokenOrUnknownVersionIsEmpty() throws {
        let url = dir.appendingPathComponent("link-visits.json")
        let file = LinkVisitsFile(url: url)
        XCTAssertEqual(file.load(), LinkVisits())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: url)
        XCTAssertEqual(file.load(), LinkVisits())
        try Data(#"{"version":2,"visits":{}}"#.utf8).write(to: url)
        XCTAssertEqual(file.load(), LinkVisits())
    }

    func testEnvironmentOverridesDefaultLocation() {
        XCTAssertEqual(LinkVisitsFile.defaultURL(environment: [LinkVisitsFile.environmentKey: "/tmp/x/visits.json"]).path, "/tmp/x/visits.json")
        XCTAssertEqual(LinkVisitsFile.defaultURL(environment: [:]).lastPathComponent, "link-visits.json")
        XCTAssertEqual(LinkVisitsFile.defaultURL(environment: [:]).deletingLastPathComponent().path, DeckPaths.applicationSupport.path)
        XCTAssertTrue(LinkVisitsFile(url: LinkVisitsFile.defaultURL(environment: [:])).restrictsDirectory)
        XCTAssertFalse(LinkVisitsFile(url: URL(fileURLWithPath: "/tmp/x/visits.json")).restrictsDirectory)
    }
}
