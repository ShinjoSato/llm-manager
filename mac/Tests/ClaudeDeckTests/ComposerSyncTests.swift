import AppKit
import XCTest
@testable import MonitorKit

/// 入力欄（ComposerTextView）と同じ同期の流れを、本物の NSTextView で組み立てる。
@MainActor
private final class Field: NSObject, NSTextViewDelegate {
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
    var draft = ""
    var sync = ComposerSync()

    override init() {
        super.init()
        textView.delegate = self
        render()
    }

    func textDidChange(_ notification: Notification) {
        sync.published(textView.string)
        draft = textView.string
    }

    /// 再描画（updateNSView）。
    func render() {
        if sync.shouldApply(external: draft, shown: textView.string) {
            if textView.hasMarkedText() { textView.inputContext?.discardMarkedText() }
            textView.string = draft
        }
    }

    func type(_ text: String) {
        textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func compose(_ text: String) {
        textView.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}

@MainActor
final class ComposerSyncTests: XCTestCase {
    /// 前提の確認: 変換中は textDidChange が来ず、その間に string を書き戻すと変換中の文字ごと消える。
    func testNaiveOverwriteDuringCompositionErasesMarkedText() {
        let field = Field()
        field.type("abc")
        field.compose("にほ")
        XCTAssertTrue(field.textView.hasMarkedText())
        XCTAssertEqual(field.draft, "abc")
        XCTAssertEqual(field.textView.string, "abcにほ")

        if field.textView.string != field.draft { field.textView.string = field.draft }
        XCTAssertEqual(field.textView.string, "abc")
        XCTAssertFalse(field.textView.hasMarkedText())
    }

    func testRerenderDuringCompositionKeepsMarkedText() {
        let field = Field()
        field.type("abc")
        field.compose("にほ")
        for _ in 0..<3 { field.render() }
        XCTAssertEqual(field.textView.string, "abcにほ")
        XCTAssertTrue(field.textView.hasMarkedText())

        field.compose("にほん")
        field.type("日本")
        XCTAssertEqual(field.draft, "abc日本")
        field.render()
        XCTAssertEqual(field.textView.string, "abc日本")
    }

    func testCompositionFromEmptyFieldSurvivesRerender() {
        let field = Field()
        field.compose("かきかけ")
        field.render()
        XCTAssertEqual(field.textView.string, "かきかけ")
        XCTAssertTrue(field.textView.hasMarkedText())
    }

    func testClearingAfterSendIsApplied() {
        let field = Field()
        field.type("hello")
        field.render()
        field.draft = ""
        field.render()
        XCTAssertEqual(field.textView.string, "")

        field.type("next")
        XCTAssertEqual(field.draft, "next")
        field.render()
        XCTAssertEqual(field.textView.string, "next")
    }

    func testRealExternalChangeDuringCompositionIsApplied() {
        let field = Field()
        field.type("abc")
        field.compose("にほ")
        field.draft = "別の下書き"
        field.render()
        XCTAssertEqual(field.textView.string, "別の下書き")
        XCTAssertFalse(field.textView.hasMarkedText())
    }

    func testInitialDraftIsShown() {
        var sync = ComposerSync()
        XCTAssertTrue(sync.shouldApply(external: "残っていた下書き", shown: ""))
        XCTAssertFalse(sync.shouldApply(external: "残っていた下書き", shown: "残っていた下書き"))
    }

    func testUnchangedDraftIsNotWrittenBack() {
        var sync = ComposerSync()
        sync.published("abc")
        XCTAssertFalse(sync.shouldApply(external: "abc", shown: "abcにほ"))
        XCTAssertFalse(sync.shouldApply(external: "abc", shown: "abc"))
        XCTAssertTrue(sync.shouldApply(external: "", shown: "abc"))
    }
}
