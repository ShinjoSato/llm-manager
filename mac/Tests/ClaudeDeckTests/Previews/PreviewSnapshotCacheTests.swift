import XCTest
@testable import MonitorKit

final class PreviewSnapshotCacheTests: XCTestCase {
    private let project = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ios-previews-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testKeyIgnoresVariantOrderAndChangesWithSource() {
        let a = PreviewRenderRequest(relativePath: "A/V.swift", index: 1, variants: ["Color Scheme": "Dark Appearance", "Orientation": "Portrait"])
        let b = PreviewRenderRequest(relativePath: "A/V.swift", index: 1, variants: ["Orientation": "Portrait", "Color Scheme": "Dark Appearance"])
        let date = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(PreviewCacheKey(projectId: project, request: a, sourceModified: date).fileStem,
                       PreviewCacheKey(projectId: project, request: b, sourceModified: date).fileStem)
        let edited = PreviewCacheKey(projectId: project, request: a, sourceModified: date.addingTimeInterval(1))
        XCTAssertEqual(edited.slot, PreviewCacheKey(projectId: project, request: a, sourceModified: date).slot)
        XCTAssertNotEqual(edited.fileStem, PreviewCacheKey(projectId: project, request: a, sourceModified: date).fileStem)
        let other = PreviewRenderRequest(relativePath: "A/V.swift", index: 2)
        XCTAssertNotEqual(PreviewCacheKey(projectId: project, request: other, sourceModified: date).slot,
                          PreviewCacheKey(projectId: project, request: PreviewRenderRequest(relativePath: "A/V.swift", index: 1), sourceModified: date).slot)
        XCTAssertNotEqual(PreviewCacheKey(projectId: project, request: PreviewRenderRequest(relativePath: "A/V.swift", index: 1, locale: "ja"), sourceModified: date).slot,
                          PreviewCacheKey(projectId: project, request: PreviewRenderRequest(relativePath: "A/V.swift", index: 1), sourceModified: date).slot)
        XCTAssertTrue(PreviewRenderRequest(relativePath: "a", index: 0).isDefault)
        XCTAssertFalse(a.isDefault)
    }

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])

    func testStoreLookupAndReplaceOlderVersion() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("snapshot.png")
        try Self.png.write(to: source)
        let request = PreviewRenderRequest(relativePath: "A/V.swift", index: 0)
        let info = PreviewSnapshotInfo(displayName: "V", destination: RenderedDestination(deviceModelName: "iPhone 18 Pro", systemVersion: "27.0"),
                                       renderedAt: Date(timeIntervalSince1970: 10), sourceLineNumber: 3,
                                       supportedVariants: ["Color Scheme": ["Light Appearance"]], supportedLocalizations: [])
        let old = PreviewCacheKey(projectId: project, request: request, sourceModified: Date(timeIntervalSince1970: 1))
        let stored = try PreviewSnapshotCache.store(snapshotPath: source.path, info: info, key: old, base: base)
        XCTAssertEqual(try Data(contentsOf: stored), Self.png)
        XCTAssertEqual(PreviewSnapshotCache.lookup(old, base: base)?.info, info)
        let mode = try FileManager.default.attributesOfItem(atPath: stored.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(stored.deletingLastPathComponent().lastPathComponent, project.uuidString.lowercased())

        // ソースを書き換えて描き直したら、同じ指定の古い版は消える（別の指定は残る）。
        let otherKey = PreviewCacheKey(projectId: project, request: PreviewRenderRequest(relativePath: "A/V.swift", index: 1), sourceModified: nil)
        try PreviewSnapshotCache.store(snapshotPath: source.path, info: info, key: otherKey, base: base)
        let new = PreviewCacheKey(projectId: project, request: request, sourceModified: Date(timeIntervalSince1970: 2))
        try PreviewSnapshotCache.store(snapshotPath: source.path, info: info, key: new, base: base)
        XCTAssertNil(PreviewSnapshotCache.lookup(old, base: base))
        XCTAssertNotNil(PreviewSnapshotCache.lookup(new, base: base))
        XCTAssertNotNil(PreviewSnapshotCache.lookup(otherKey, base: base))
        XCTAssertThrowsError(try PreviewSnapshotCache.store(snapshotPath: base.appendingPathComponent("missing.png").path, info: info, key: new, base: base))
    }

    func testReadSnapshotChecksPathAndContent() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let good = base.appendingPathComponent("a.png")
        try Self.png.write(to: good)
        XCTAssertEqual(try PreviewSnapshotCache.readSnapshot(at: good.path), Self.png)
        // 拡張子の大文字は受ける。
        let upper = base.appendingPathComponent("b.PNG")
        try Self.png.write(to: upper)
        XCTAssertNoThrow(try PreviewSnapshotCache.readSnapshot(at: upper.path))

        func rejects(_ path: String, _ reason: PreviewSnapshotCache.SnapshotRejection, maxBytes: Int = PreviewSnapshotCache.maxSnapshotBytes,
                     line: UInt = #line) {
            XCTAssertThrowsError(try PreviewSnapshotCache.readSnapshot(at: path, maxBytes: maxBytes), line: line) {
                XCTAssertEqual($0 as? PreviewSnapshotCache.SnapshotRejection, reason, line: line)
            }
        }
        rejects("a.png", .notAbsolute)
        rejects("../x/a.png", .notAbsolute)
        let text = base.appendingPathComponent("a.txt")
        try Self.png.write(to: text)
        rejects(text.path, .notPNGExtension)
        // シンボリックリンクは辿らない（中身が PNG でも）。
        let link = base.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: good)
        rejects(link.path, .notRegularFile)
        let folder = base.appendingPathComponent("dir.png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        rejects(folder.path, .notRegularFile)
        let fake = base.appendingPathComponent("fake.png")
        try Data("not a png at all".utf8).write(to: fake)
        rejects(fake.path, .notPNG)
        let short = base.appendingPathComponent("short.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: short)
        rejects(short.path, .notPNG)
        rejects(good.path, .tooLarge(Self.png.count), maxBytes: 8)
        XCTAssertThrowsError(try PreviewSnapshotCache.readSnapshot(at: base.appendingPathComponent("missing.png").path))
        XCTAssertEqual(PreviewSnapshotCache.maxSnapshotBytes, 50 * 1024 * 1024)
    }

    func testInfoKnowsSourceVersionAndLine() throws {
        let modified = Date(timeIntervalSince1970: 1_700_000_000.123)
        let info = PreviewSnapshotInfo(displayName: nil, destination: nil, renderedAt: Date(), sourceLineNumber: 12,
                                       supportedVariants: [:], supportedLocalizations: [], sourceModified: modified)
        XCTAssertTrue(info.isCurrent(sourceModified: modified))
        XCTAssertTrue(info.isCurrent(sourceModified: modified.addingTimeInterval(0.0001)))
        // ソースを書き換えた（更新時刻が変わった）後は古い絵として扱う。
        XCTAssertFalse(info.isCurrent(sourceModified: modified.addingTimeInterval(1)))
        XCTAssertFalse(info.isCurrent(sourceModified: nil))
        // 添え書きの JSON を通しても同じに比べられる。
        let decoded = try JSONDecoder().decode(PreviewSnapshotInfo.self, from: JSONEncoder().encode(info))
        XCTAssertTrue(decoded.isCurrent(sourceModified: modified))
        // 前の版の添え書き（sourceModified 無し）も読める。
        let old = try JSONDecoder().decode(PreviewSnapshotInfo.self, from: Data(#"{"renderedAt":0,"supportedVariants":{},"supportedLocalizations":[]}"#.utf8))
        XCTAssertNil(old.sourceModified)

        XCTAssertFalse(info.lineMismatch(expected: 12))
        XCTAssertTrue(info.lineMismatch(expected: 30))
        var unknown = info
        unknown.sourceLineNumber = nil
        XCTAssertFalse(unknown.lineMismatch(expected: 30))
    }

    func testPruneRemovesProjectsNotInSettings() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let keep = UUID(), drop = UUID()
        for id in [keep, drop] {
            try FileManager.default.createDirectory(at: PreviewSnapshotCache.directory(projectId: id, base: base), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("not-a-project"), withIntermediateDirectories: true)
        XCTAssertEqual(PreviewSnapshotCache.prune(keeping: [keep], base: base), [drop])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: base.path)), [keep.uuidString.lowercased(), "not-a-project"])
        XCTAssertEqual(PreviewSnapshotCache.prune(keeping: [keep], base: base.appendingPathComponent("missing")), [])
    }

    func testStaleNames() {
        XCTAssertEqual(PreviewSnapshotCache.stale(in: ["s1-a.png", "s1-a.json", "s1-b.png", "s1-b.json", "s2-a.png", ".tmp"], slot: "s1", keep: "s1-b"),
                       ["s1-a.png", "s1-a.json"])
    }

    func testRemoveProjectOnlyTouchesThatProject() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let keep = UUID(), drop = UUID()
        for id in [keep, drop] {
            try FileManager.default.createDirectory(at: PreviewSnapshotCache.directory(projectId: id, base: base), withIntermediateDirectories: true)
        }
        PreviewSnapshotCache.removeProject(drop, base: base)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), [keep.uuidString.lowercased()])
    }
}
