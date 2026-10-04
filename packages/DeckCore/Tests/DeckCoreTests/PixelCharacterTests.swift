import XCTest
@testable import DeckCore

final class PixelCharacterTests: XCTestCase {
    private let allStatuses: [SessionStatus] = [.working, .permission, .waiting, .error, .idle, .stopped, .unknown]

    // MARK: - スプライトの寸法

    func testAgentSpritesAre12By15WithEvenRows() {
        for sprite in [PixelSprites.agentStand, PixelSprites.agentSit, PixelSprites.agentDown] {
            XCTAssertEqual(sprite.width, 12)
            XCTAssertEqual(sprite.height, 15)
            XCTAssertTrue(sprite.rows.allSatisfy { $0.count == 12 })
        }
    }

    func testMarkSpritesAreFiveRowsTall() {
        XCTAssertEqual(PixelSprites.markBang.width, 1)
        XCTAssertEqual(PixelSprites.markQuestion.width, 3)
        XCTAssertEqual(PixelSprites.markSleep.width, 3)
        for mark in [PixelSprites.markBang, PixelSprites.markQuestion, PixelSprites.markSleep] {
            XCTAssertEqual(mark.height, 5)
            XCTAssertEqual(mark.keys, ["A"])
        }
    }

    // MARK: - パレット解決

    func testEveryKeyResolvesForEveryStatus() {
        for status in allStatuses {
            let look = PixelCharacter.look(for: status)
            XCTAssertTrue(look.sprite.keys.isSubset(of: Set(look.palette.keys)), "\(status)")
            if let mark = look.mark {
                XCTAssertTrue(mark.keys.isSubset(of: Set(look.markPalette.keys)), "\(status)")
            }
        }
    }

    func testPalettesMatchMonitorLook() {
        XCTAssertEqual(PixelCharacter.look(for: .working).palette["G"], 0x34d399)
        XCTAssertEqual(PixelCharacter.look(for: .permission).palette["B"], 0xd97706)
        XCTAssertEqual(PixelCharacter.look(for: .waiting).markPalette["A"], 0x60a5fa)
        XCTAssertEqual(PixelCharacter.look(for: .error).palette["D"], 0x991b1b)
        XCTAssertEqual(PixelCharacter.look(for: .idle).palette["S"], 0xcbb99c)
        XCTAssertEqual(PixelCharacter.look(for: .stopped).palette["G"], 0x3f4c5e)
        XCTAssertEqual(PixelCharacter.look(for: .working).palette["S"], PixelCharacter.skin["S"])
    }

    func testRunsMergeSameColorAndSkipTransparentAndUnknownKeys() {
        let sprite = PixelSprite(["AAB.", "..XA"])
        let runs = PixelSprites.runs(sprite, palette: ["A": 1, "B": 2])
        XCTAssertEqual(runs, [
            PixelRun(x: 0, y: 0, width: 2, color: 1),
            PixelRun(x: 2, y: 0, width: 1, color: 2),
            PixelRun(x: 3, y: 1, width: 1, color: 1),
        ])
    }

    // MARK: - 状態 → 見た目

    func testStatusToLook() {
        func check(_ status: SessionStatus, _ sprite: PixelSprite, _ mark: PixelSprite?, _ motion: PixelMotion,
                   line: UInt = #line) {
            let look = PixelCharacter.look(for: status)
            XCTAssertEqual(look.sprite, sprite, line: line)
            XCTAssertEqual(look.mark, mark, line: line)
            XCTAssertEqual(look.motion, motion, line: line)
        }
        check(.working, PixelSprites.agentStand, nil, .bob)
        check(.permission, PixelSprites.agentStand, PixelSprites.markBang, .blink)
        check(.waiting, PixelSprites.agentStand, PixelSprites.markQuestion, .blink)
        check(.error, PixelSprites.agentDown, nil, .still)
        check(.idle, PixelSprites.agentSit, PixelSprites.markSleep, .drift)
        check(.stopped, PixelSprites.agentSit, nil, .still)
        check(.unknown, PixelSprites.agentSit, nil, .still)
    }

    func testOnlyMovingStatusesAreAnimated() {
        XCTAssertEqual(allStatuses.filter(PixelCharacter.isAnimated), [.working, .permission, .waiting, .idle])
    }

    func testMarkDropsWithSeatedPose() {
        XCTAssertEqual(PixelCharacter.look(for: .permission).markDrop, 0)
        XCTAssertEqual(PixelCharacter.look(for: .idle).markDrop, 2)
    }

    // MARK: - コマ

    func testFramesCycle() {
        let bob = (0..<8).map { PixelCharacter.frame(.bob, tick: $0).bodyOffsetY }
        XCTAssertEqual(bob, [0, 0, -1, -1, 0, 0, -1, -1])
        let blink = (0..<4).map { PixelCharacter.frame(.blink, tick: $0).markVisible }
        XCTAssertEqual(blink, [true, true, true, false])
        let drift = (0..<8).map { PixelCharacter.frame(.drift, tick: $0).markOffsetY }
        XCTAssertEqual(drift, [0, 0, 0, 0, -1, -1, -1, -1])
        XCTAssertEqual(PixelCharacter.frame(.still, tick: 3), PixelCharacter.frame(.still, tick: 0))
        XCTAssertEqual(PixelCharacter.frame(.bob, tick: -6), PixelCharacter.frame(.bob, tick: 2))
    }

    func testEveryFrameStaysInsideGrid() {
        for status in allStatuses {
            for tick in 0..<8 {
                let runs = PixelCharacter.runs(for: status, tick: tick)
                XCTAssertFalse(runs.isEmpty)
                for run in runs {
                    XCTAssertGreaterThanOrEqual(run.x, 0)
                    XCTAssertGreaterThanOrEqual(run.y, 0)
                    XCTAssertLessThanOrEqual(run.x + run.width, PixelCharacter.gridWidth, "\(status) \(tick)")
                    XCTAssertLessThan(run.y, PixelCharacter.gridHeight, "\(status) \(tick)")
                }
            }
        }
    }

    func testBlinkHidesMarkOnOffFrame() {
        let markColor: UInt32 = 0xfbbf24
        // 胴の色とマークの色は別なので、マーク色のマスだけで出入りを見る。
        let shown = PixelCharacter.runs(for: .permission, tick: 0).filter { $0.color == markColor && $0.x >= 11 }
        let hidden = PixelCharacter.runs(for: .permission, tick: 3).filter { $0.color == markColor && $0.x >= 11 }
        XCTAssertEqual(shown.count, 4)
        XCTAssertTrue(hidden.isEmpty)
    }

    func testTickIndexIsSharedAcrossRows() {
        let date = Date(timeIntervalSinceReferenceDate: 10.3)
        XCTAssertEqual(PixelCharacter.tickIndex(at: date), 41)
    }
}
