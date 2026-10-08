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

    func testStoreLookupAndReplaceOlderVersion() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("snapshot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)
        let request = PreviewRenderRequest(relativePath: "A/V.swift", index: 0)
        let info = PreviewSnapshotInfo(displayName: "V", destination: RenderedDestination(deviceModelName: "iPhone 18 Pro", systemVersion: "27.0"),
                                       renderedAt: Date(timeIntervalSince1970: 10), sourceLineNumber: 3,
                                       supportedVariants: ["Color Scheme": ["Light Appearance"]], supportedLocalizations: [])
        let old = PreviewCacheKey(projectId: project, request: request, sourceModified: Date(timeIntervalSince1970: 1))
        let stored = try PreviewSnapshotCache.store(snapshotAt: source, info: info, key: old, base: base)
        XCTAssertEqual(try Data(contentsOf: stored), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(PreviewSnapshotCache.lookup(old, base: base)?.info, info)
        let mode = try FileManager.default.attributesOfItem(atPath: stored.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(stored.deletingLastPathComponent().lastPathComponent, project.uuidString.lowercased())

        // ソースを書き換えて描き直したら、同じ指定の古い版は消える（別の指定は残る）。
        let otherKey = PreviewCacheKey(projectId: project, request: PreviewRenderRequest(relativePath: "A/V.swift", index: 1), sourceModified: nil)
        try PreviewSnapshotCache.store(snapshotAt: source, info: info, key: otherKey, base: base)
        let new = PreviewCacheKey(projectId: project, request: request, sourceModified: Date(timeIntervalSince1970: 2))
        try PreviewSnapshotCache.store(snapshotAt: source, info: info, key: new, base: base)
        XCTAssertNil(PreviewSnapshotCache.lookup(old, base: base))
        XCTAssertNotNil(PreviewSnapshotCache.lookup(new, base: base))
        XCTAssertNotNil(PreviewSnapshotCache.lookup(otherKey, base: base))
        XCTAssertThrowsError(try PreviewSnapshotCache.store(snapshotAt: base.appendingPathComponent("missing.png"), info: info, key: new, base: base))
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
