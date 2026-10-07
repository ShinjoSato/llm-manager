import AppKit
import XCTest
@testable import MonitorKit

/// プレースホルダーの出し分けを、本物の NSTextView の変換中（marked text）の状態で確かめる。
@MainActor
final class ComposerPlaceholderTests: XCTestCase {
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))

    private var shown: Bool {
        ComposerPlaceholder.isShown(shown: textView.string, hasMarkedText: textView.hasMarkedText())
    }

    private func type(_ text: String) {
        textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func compose(_ text: String) {
        textView.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func testShownOnlyWhenEmptyAndNotComposing() {
        XCTAssertTrue(ComposerPlaceholder.isShown(shown: "", hasMarkedText: false))
        XCTAssertFalse(ComposerPlaceholder.isShown(shown: "", hasMarkedText: true))
        XCTAssertFalse(ComposerPlaceholder.isShown(shown: "abc", hasMarkedText: false))
        XCTAssertFalse(ComposerPlaceholder.isShown(shown: "abc", hasMarkedText: true))
    }

    func testHiddenWhileComposingFromEmptyField() {
        XCTAssertTrue(shown)
        compose("にほ")
        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertFalse(shown)

        compose("にほん")
        type("日本")
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(textView.string, "日本")
        XCTAssertFalse(shown)
    }

    func testReturnsWhenCompositionIsCancelled() {
        compose("か")
        XCTAssertFalse(shown)
        compose("")
        XCTAssertEqual(textView.string, "")
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertTrue(shown)
    }

    func testReturnsWhenClearedAfterSend() {
        type("hello")
        XCTAssertFalse(shown)
        textView.string = ""
        XCTAssertTrue(shown)
    }

    func testAlphanumericTypingHidesImmediately() {
        type("a")
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertFalse(shown)
    }
}
