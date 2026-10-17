import UIKit
import XCTest
@testable import ClaudeDeck

/// ハードウェアキーボードの ⏎ を送信に使うかの判定。
final class ComposerKeyTests: XCTestCase {
    func testPlainReturnSends() {
        XCTAssertTrue(ComposerKey.submits(keyCode: .keyboardReturnOrEnter, modifiers: [], composing: false))
        XCTAssertTrue(ComposerKey.submits(keyCode: .keypadEnter, modifiers: [], composing: false))
        XCTAssertTrue(ComposerKey.submits(keyCode: .keyboardReturnOrEnter, modifiers: .alphaShift, composing: false), "Caps Lock では改行にしない")
    }

    func testReturnWhileConvertingCommits() {
        XCTAssertFalse(ComposerKey.submits(keyCode: .keyboardReturnOrEnter, modifiers: [], composing: true))
    }

    func testModifiedReturnInsertsNewline() {
        for modifier: UIKeyModifierFlags in [.shift, .alternate, .command, .control] {
            XCTAssertFalse(ComposerKey.submits(keyCode: .keyboardReturnOrEnter, modifiers: modifier, composing: false))
        }
    }

    func testOtherKeysAreLeftToTheTextView() {
        XCTAssertFalse(ComposerKey.submits(keyCode: .keyboardA, modifiers: [], composing: false))
        XCTAssertFalse(ComposerKey.submits(keyCode: .keyboardTab, modifiers: [], composing: false))
    }
}
