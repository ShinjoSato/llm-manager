import XCTest
@testable import MonitorKit

final class TerminalKeyTests: XCTestCase {
    func testSequencesInNormalCursorMode() {
        let expected: [(TerminalKey, String)] = [
            (.up, "\u{1b}[A"), (.down, "\u{1b}[B"), (.right, "\u{1b}[C"), (.left, "\u{1b}[D"),
            (.enter, "\r"), (.escape, "\u{1b}"), (.tab, "\t"), (.space, " "),
            (.digit(1), "1"), (.digit(9), "9"),
        ]
        for (key, sequence) in expected {
            XCTAssertEqual(key.sequence(applicationCursor: false), sequence, key.label)
        }
    }

    func testArrowsFollowApplicationCursorMode() {
        XCTAssertEqual(TerminalKey.up.sequence(applicationCursor: true), "\u{1b}OA")
        XCTAssertEqual(TerminalKey.down.sequence(applicationCursor: true), "\u{1b}OB")
        XCTAssertEqual(TerminalKey.right.sequence(applicationCursor: true), "\u{1b}OC")
        XCTAssertEqual(TerminalKey.left.sequence(applicationCursor: true), "\u{1b}OD")
        // 矢印以外はモードに依らない。
        XCTAssertEqual(TerminalKey.enter.sequence(applicationCursor: true), "\r")
        XCTAssertEqual(TerminalKey.digit(3).sequence(applicationCursor: true), "3")
    }

    func testSameSequencesAsCardAnswers() {
        XCTAssertEqual(TerminalKey.up.sequence(applicationCursor: false), PTYInput.arrowKey(.up, applicationCursor: false))
        XCTAssertEqual(TerminalKey.right.sequence(applicationCursor: true), PTYInput.tabKey(.next, applicationCursor: true))
        XCTAssertEqual(TerminalKey.left.sequence(applicationCursor: false), PTYInput.tabKey(.previous, applicationCursor: false))
        XCTAssertEqual(TerminalKey.enter.sequence(applicationCursor: false), PTYInput.confirmMenuKey)
        XCTAssertEqual(TerminalKey.escape.sequence(applicationCursor: false), PTYInput.cancelMenuKey)
    }

    func testDigitsOutsideOneToNineAreNotSent() {
        XCTAssertNil(TerminalKey.digit(0).sequence(applicationCursor: false))
        XCTAssertNil(TerminalKey.digit(10).sequence(applicationCursor: false))
        XCTAssertNil(TerminalKey.digit(-1).sequence(applicationCursor: false))
    }

    func testEverySheetKeyHasASingleKeySequence() {
        XCTAssertEqual(TerminalKey.all.count, 17)
        XCTAssertEqual(Set(TerminalKey.all).count, TerminalKey.all.count)
        for key in TerminalKey.all {
            let sequence = key.sequence(applicationCursor: false)
            XCTAssertNotNil(sequence, key.label)
            // 本文の貼り付けや複数キーの列にはならない。
            XCTAssertFalse(sequence?.contains("\u{1b}[200~") ?? true, key.label)
            XCTAssertLessThanOrEqual(sequence?.count ?? 0, 3, key.label)
        }
    }

    func testLabels() {
        XCTAssertEqual(TerminalKey.all.map(\.label),
                       ["←", "↑", "↓", "→", "Enter", "Esc", "Tab", "Space", "1", "2", "3", "4", "5", "6", "7", "8", "9"])
    }

    func testOnlyArrowsMoveCursor() {
        XCTAssertEqual(TerminalKey.all.filter(\.movesCursor), [.left, .up, .down, .right])
    }

    func testKeyboardCharacters() {
        XCTAssertEqual(TerminalKey(keyCharacter: "\u{F700}"), .up)
        XCTAssertEqual(TerminalKey(keyCharacter: "\u{F701}"), .down)
        XCTAssertEqual(TerminalKey(keyCharacter: "\u{F702}"), .left)
        XCTAssertEqual(TerminalKey(keyCharacter: "\u{F703}"), .right)
        XCTAssertEqual(TerminalKey(keyCharacter: "\r"), .enter)
        XCTAssertEqual(TerminalKey(keyCharacter: "\u{3}"), .enter)
        XCTAssertEqual(TerminalKey(keyCharacter: "\u{1b}"), .escape)
        XCTAssertEqual(TerminalKey(keyCharacter: "\t"), .tab)
        XCTAssertEqual(TerminalKey(keyCharacter: " "), .space)
        XCTAssertEqual(TerminalKey(keyCharacter: "1"), .digit(1))
        XCTAssertEqual(TerminalKey(keyCharacter: "9"), .digit(9))
    }

    /// 文字の自由入力にならないよう、表に無い文字は拾わない。
    func testOtherCharactersAreIgnored() {
        for character: Character in ["0", "a", "Y", "n", "/", "\u{7f}", "\u{8}", "\u{F704}", "\u{19}", "１", "٣", "あ"] {
            XCTAssertNil(TerminalKey(keyCharacter: character), "\(character.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }
}
