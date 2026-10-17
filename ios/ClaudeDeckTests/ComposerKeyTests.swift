import UIKit
import XCTest
@testable import ClaudeDeck

/// ハードウェアキーボードの ⏎ で送る時に、変換中の文字を見分けられること。
@MainActor
final class ComposerKeyTests: XCTestCase {
    func testMarkedTextIsSeenThroughFirstResponder() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let field = UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        window.addSubview(field)
        window.makeKeyAndVisible()
        defer {
            field.resignFirstResponder()
            window.isHidden = true
        }
        XCTAssertTrue(field.becomeFirstResponder())
        XCTAssertFalse(FocusedTextInput.hasMarkedText)
        field.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(FocusedTextInput.hasMarkedText, "変換中の ⏎ は確定に使う")
        field.unmarkText()
        XCTAssertFalse(FocusedTextInput.hasMarkedText)
    }
}
