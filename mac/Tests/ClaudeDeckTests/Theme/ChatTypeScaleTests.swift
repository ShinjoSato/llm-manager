import XCTest
@testable import MonitorKit

final class ChatTypeScaleTests: XCTestCase {
    /// 返答以外の Markdown は今までの大きさのまま。
    func testStandardKeepsOriginalSizes() {
        let s = ChatTypeScale.standard
        XCTAssertEqual(s.body, 14)
        XCTAssertEqual(s.lineSpacing, 3)
        XCTAssertEqual(s.ratio, 1)
        XCTAssertEqual(s.mono, 12)
        XCTAssertEqual([1, 2, 3, 4, 5].map(s.heading), [19, 16.5, 15, 14, 14])
        XCTAssertEqual([s.blockSpacing(nested: false), s.blockSpacing(nested: true)], [10, 6])
        XCTAssertEqual(s.listSpacing, 4)
        XCTAssertEqual(s.digitWidth, 8.5)
    }

    /// 返答は発話より 1pt 大きく、見出し・等幅も同じ比率で 0.5pt 刻みにそろう。
    func testReplyScalesEverythingByTheSameRatio() {
        let r = ChatTypeScale.reply
        XCTAssertEqual(r.body, ChatTypeScale.standard.body + 1)
        XCTAssertGreaterThan(r.lineSpacing, ChatTypeScale.standard.lineSpacing)
        XCTAssertEqual(r.mono, 13)
        XCTAssertEqual([1, 2, 3, 4].map(r.heading), [20.5, 17.5, 16, 15])
        XCTAssertEqual([r.blockSpacing(nested: false), r.blockSpacing(nested: true)], [10.5, 6.5])
        for level in 1...3 {
            XCTAssertGreaterThan(r.heading(level), r.body)
            XCTAssertEqual(r.heading(level) * 2, (r.heading(level) * 2).rounded())
        }
        XCTAssertLessThan(r.mono, r.body)
    }
}
