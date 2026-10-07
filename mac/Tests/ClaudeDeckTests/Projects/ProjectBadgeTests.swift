import XCTest
@testable import MonitorKit

final class ProjectBadgeTests: XCTestCase {
    private func project(_ name: String = "mirio", icon: String? = nil, color: String? = nil) -> ManagedProject {
        ManagedProject(name: name, path: "/tmp/\(name)", icon: icon, color: color)
    }

    func testColorKeysAreTheSettingsVocabulary() {
        XCTAssertEqual(ProjectColor.allCases.map(\.rawValue),
                       ["red", "orange", "yellow", "green", "teal", "blue", "indigo", "purple", "pink", "brown", "gray"])
        XCTAssertEqual(ProjectColor.allCases.map(\.paletteIndex), Array(0..<11))
        XCTAssertEqual(Set(ProjectColor.allCases.map(\.label)).count, ProjectColor.allCases.count)
        XCTAssertTrue(ProjectColor.allCases.allSatisfy { !$0.label.isEmpty })
        XCTAssertEqual(ProjectColor.hashCandidates.count, 8)
        XCTAssertEqual(Set(ProjectColor.hashCandidates).count, 8)
    }

    /// 未設定の色は、キーを足す前と同じ 8 色のハッシュで決まる。
    func testDefaultColorComesFromTheOriginalEightByHash() {
        for name in ["mirio", "infra", "blog", "ai-manager", "", "日本語の名前"] {
            let expected = ProjectColor.hashCandidates[RoomGrouping.colorIndex(for: name, paletteSize: 8)]
            XCTAssertEqual(ProjectBadge.defaultColor(for: name), expected, name)
        }
        XCTAssertEqual(ProjectBadge.defaultColor(for: "mirio"), ProjectBadge.defaultColor(for: "mirio"))
    }

    func testResolveFallsBackToNameColorAndFolder() {
        let badge = ProjectBadge.resolve(project: project(), symbolExists: { _ in true })
        XCTAssertEqual(badge, ProjectBadge(colorKey: ProjectBadge.defaultColor(for: "mirio"), symbol: "folder"))
        XCTAssertEqual(ProjectBadge.defaultSymbol, "folder")
    }

    func testResolveUsesChosenColorAndIcon() {
        let badge = ProjectBadge.resolve(project: project(icon: "iphone", color: "teal"), symbolExists: { $0 == "iphone" })
        XCTAssertEqual(badge, ProjectBadge(colorKey: .teal, symbol: "iphone"))
    }

    func testUnknownColorFallsBackToNameColor() {
        for raw in ["magenta", "", "Blue", " blue"] {
            let badge = ProjectBadge.resolve(project: project(color: raw), symbolExists: { _ in true })
            XCTAssertEqual(badge.colorKey, ProjectBadge.defaultColor(for: "mirio"), raw)
            XCTAssertNotNil(ProjectBadge.colorProblem(raw), raw)
        }
        XCTAssertNil(ProjectBadge.colorProblem(nil))
        XCTAssertNil(ProjectBadge.colorProblem("blue"))
    }

    func testMissingSymbolFallsBackToDefault() {
        var asked: [String] = []
        let badge = ProjectBadge.resolve(project: project(icon: "no.such.symbol"), symbolExists: { asked.append($0); return false })
        XCTAssertEqual(badge.symbol, "folder")
        XCTAssertEqual(asked, ["no.such.symbol"])
        // 空・空白だけは Symbol を引かずに既定。
        for raw in ["", "   ", "\n"] {
            let blank = ProjectBadge.resolve(project: project(icon: raw), symbolExists: { _ in XCTFail("空は引かない"); return true })
            XCTAssertEqual(blank.symbol, "folder", raw)
            XCTAssertNotNil(ProjectBadge.iconProblem(raw), raw)
        }
        XCTAssertNil(ProjectBadge.iconProblem(nil))
        XCTAssertNil(ProjectBadge.iconProblem("iphone"))
        // 前後の空白は落として引く。
        let trimmed = ProjectBadge.resolve(project: project(icon: " iphone "), symbolExists: { $0 == "iphone" })
        XCTAssertEqual(trimmed.symbol, "iphone")
    }

    /// 実際の SF Symbol で解決できる（無いものは既定）。
    func testSymbolExistsUsesSystemCatalog() {
        XCTAssertTrue(ProjectBadge.symbolExists("folder"))
        XCTAssertTrue(ProjectBadge.symbolExists("iphone"))
        XCTAssertFalse(ProjectBadge.symbolExists("claude.deck.no.such.symbol"))
        XCTAssertFalse(ProjectBadge.symbolExists(""))
        XCTAssertEqual(ProjectBadge.resolve(project: project(icon: "claude.deck.no.such.symbol")).symbol, "folder")
        XCTAssertEqual(ProjectBadge.resolve(project: project(icon: "iphone")).symbol, "iphone")
    }

    /// 候補は重複なく 40 個程度で、どれもこの OS の SF Symbol にある。
    func testSymbolChoicesAllExist() {
        let choices = ProjectBadge.symbolChoices
        XCTAssertGreaterThanOrEqual(choices.count, 40)
        XCTAssertEqual(Set(choices).count, choices.count)
        XCTAssertEqual(choices.first, ProjectBadge.defaultSymbol)
        for symbol in choices {
            XCTAssertTrue(ProjectBadge.symbolExists(symbol), symbol)
        }
    }

    func testPaletteHasOneColorPerKey() {
        for palette in [ThemePalette.night, ThemePalette.light] {
            XCTAssertEqual(palette.avatarPalette.count, ProjectColor.allCases.count)
            for key in ProjectColor.allCases {
                XCTAssertEqual(palette.avatar(key), palette.avatarPalette[key.paletteIndex])
            }
        }
    }
}
