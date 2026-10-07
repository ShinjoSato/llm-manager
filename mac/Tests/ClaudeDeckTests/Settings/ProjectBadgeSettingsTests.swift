import XCTest
@testable import MonitorKit

/// settings.json の `icon` / `color` の往復と、キーを知らないファイルとの互換。
final class ProjectBadgeSettingsTests: XCTestCase {
    private let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func decode(_ json: String) throws -> DeckSettings {
        try JSONDecoder().decode(DeckSettings.self, from: Data(json.utf8))
    }

    private func text(_ settings: DeckSettings) throws -> String {
        String(decoding: try settings.encoded(), as: UTF8.self)
    }

    private var legacy: String {
        """
        { "version": 1,
          "projects": [ { "id": "\(id.uuidString)", "name": "mirio", "path": "/tmp/mirio", "status": "active", "note": "" } ],
          "boards": [] }
        """
    }

    /// `icon` / `color` の無いファイルはそのまま読め、書き戻しても欄が増えない。
    func testLegacyFileRoundTripsWithoutAddingKeys() throws {
        let settings = try decode(legacy)
        let project = try XCTUnwrap(settings.projects.first)
        XCTAssertNil(project.icon)
        XCTAssertNil(project.color)
        XCTAssertEqual(ProjectBadge.resolve(project: project), ProjectBadge(colorKey: ProjectBadge.defaultColor(for: "mirio"), symbol: "folder"))
        let written = try text(settings)
        XCTAssertFalse(written.contains("\"icon\""))
        XCTAssertFalse(written.contains("\"color\""))
        XCTAssertEqual(try decode(written), settings)
        XCTAssertTrue(SettingsValidation.problems(settings).isEmpty)
    }

    func testChosenIconAndColorRoundTrip() throws {
        var settings = try decode(legacy)
        settings.projects[0].icon = "iphone"
        settings.projects[0].color = "teal"
        let written = try text(settings)
        XCTAssertTrue(written.contains("\"color\" : \"teal\""))
        XCTAssertTrue(written.contains("\"icon\" : \"iphone\""))
        let back = try decode(written)
        XCTAssertEqual(back, settings)
        XCTAssertEqual(ProjectBadge.resolve(project: back.projects[0]), ProjectBadge(colorKey: .teal, symbol: "iphone"))
        XCTAssertTrue(SettingsValidation.problems(back).isEmpty)
        // 「自動」「既定」に戻せばキーが消える。
        settings.projects[0].icon = nil
        settings.projects[0].color = nil
        let cleared = try text(settings)
        XCTAssertFalse(cleared.contains("\"icon\""))
        XCTAssertFalse(cleared.contains("\"color\""))
    }

    /// 手で書いたキーを読む（nil のキーは無いのと同じ）。
    func testHandWrittenKeysAreRead() throws {
        let settings = try decode("""
        { "version": 1,
          "projects": [ { "id": "\(id.uuidString)", "name": "mirio", "path": "/tmp/mirio", "status": "active",
                          "icon": "globe", "color": "purple" },
                        { "id": "22222222-2222-3333-4444-555555555555", "name": "infra", "path": "/tmp/infra", "status": "paused",
                          "icon": null, "color": null } ] }
        """)
        XCTAssertEqual(settings.projects[0].icon, "globe")
        XCTAssertEqual(settings.projects[0].color, "purple")
        XCTAssertNil(settings.projects[1].icon)
        XCTAssertNil(settings.projects[1].color)
        XCTAssertFalse(try text(settings).contains("null"))
    }

    /// 知らない色・空のアイコンは警告だけで、設定全体は読めて値も残る（表示は既定に落ちる）。
    func testUnknownColorAndBlankIconAreWarningsOnly() throws {
        let settings = try decode("""
        { "version": 1,
          "projects": [ { "id": "\(id.uuidString)", "name": "mirio", "path": "/tmp/mirio", "status": "active",
                          "icon": "", "color": "magenta" } ] }
        """)
        let project = settings.projects[0]
        XCTAssertEqual(project.color, "magenta")
        XCTAssertEqual(project.icon, "")
        XCTAssertTrue(SettingsValidation.blockingProblems(settings).isEmpty)
        let warnings = SettingsValidation.warnings(settings)
        XCTAssertEqual(warnings.count, 2)
        XCTAssertTrue(warnings.contains { $0.contains("「mirio」の印") && $0.contains("magenta") })
        XCTAssertTrue(warnings.contains { $0.contains("「mirio」の印") && $0.contains("アイコンが空") })
        XCTAssertEqual(SettingsValidation.projectProblems(project).count, 2)
        XCTAssertEqual(ProjectBadge.resolve(project: project), ProjectBadge(colorKey: ProjectBadge.defaultColor(for: "mirio"), symbol: "folder"))
        // 書き戻しても手で書いた値を壊さない。
        XCTAssertTrue(try text(settings).contains("\"color\" : \"magenta\""))
    }

    /// 無い Symbol は読めて警告にはならず、表示だけ既定に落ちる。
    func testMissingSymbolIsKeptAndDisplayedAsDefault() throws {
        let settings = try decode("""
        { "version": 1,
          "projects": [ { "id": "\(id.uuidString)", "name": "mirio", "path": "/tmp/mirio", "status": "active",
                          "icon": "claude.deck.no.such.symbol", "color": "blue" } ] }
        """)
        XCTAssertTrue(SettingsValidation.problems(settings).isEmpty)
        XCTAssertEqual(ProjectBadge.resolve(project: settings.projects[0]), ProjectBadge(colorKey: .blue, symbol: "folder"))
        XCTAssertEqual(try decode(try text(settings)).projects[0].icon, "claude.deck.no.such.symbol")
    }

    /// 比較・取り込みで印も見る（違えば別の内容）。
    func testBadgeTakesPartInEquality() {
        let a = ManagedProject(id: id, name: "mirio", path: "/tmp/mirio")
        var b = a
        XCTAssertEqual(a, b)
        b.color = "red"
        XCTAssertNotEqual(a, b)
        b.color = nil
        b.icon = "star"
        XCTAssertNotEqual(a, b)
    }

    func testImportFillsIconAndColorOfExistingProject() throws {
        var current = try decode(legacy)
        current.projects[0].color = "green"
        let incoming = """
        { "version": 1,
          "projects": [ { "id": "\(UUID().uuidString)", "name": "mirio", "path": "/tmp/mirio", "status": "active", "note": "",
                          "icon": "iphone", "color": "red" } ],
          "boards": [] }
        """
        let (settings, _) = try SettingsImport.merge(Data(incoming.utf8), into: current)
        let project = try XCTUnwrap(settings.projects.first)
        // 無い欄は足し、既にある欄は上書きしない。
        XCTAssertEqual(project.icon, "iphone")
        XCTAssertEqual(project.color, "green")
    }
}
