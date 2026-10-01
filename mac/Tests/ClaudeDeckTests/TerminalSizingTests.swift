import XCTest
import AppKit
import SwiftTerm

/// 画面に載せない端末ビューでも、起動前に枠を広げれば桁数が追従する（ホスト中のセッションの桁を広げる前提）。
final class TerminalSizingTests: XCTestCase {
    @MainActor
    func testWideningFrameBeforeLaunchIncreasesColumns() {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        let columns = view.getTerminal().cols
        XCTAssertGreaterThan(columns, 80)
        let width = (view.frame.width * 160 / CGFloat(columns)).rounded(.up)
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
        XCTAssertGreaterThanOrEqual(view.getTerminal().cols, 155)
        XCTAssertLessThanOrEqual(view.getTerminal().cols, 165)
    }

    /// 背景色の付いた文字を、全角の後半セルを飛ばした文字の並びで拾える（タブ行の今のタブの読み取りと同じ手順）。
    @MainActor
    func testBackgroundColorPerCharacter() {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        view.feed(text: "← \u{1b}[44m ☒ 対応 \u{1b}[0m  ✔ Submit  →")
        let term = view.getTerminal()
        guard let line = term.getScrollInvariantLine(row: term.buffer.totalLinesTrimmed) else { return XCTFail("no line") }
        var flags: [Bool] = []
        let text = line.translateToString(trimRight: true, skipNullCellsFollowingWide: true) { cell in
            switch cell.attribute.bg {
            case .ansi256, .trueColor: flags.append(true)
            default: flags.append(false)
            }
            return cell.getCharacter()
        }
        XCTAssertEqual(text, "←  ☒ 対応   ✔ Submit  →")
        XCTAssertEqual(flags.count, text.count)
        let highlighted = String(zip(text, flags).filter(\.1).map(\.0))
        XCTAssertEqual(highlighted, " ☒ 対応 ")
    }
}
