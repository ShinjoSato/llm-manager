import AppKit
import XCTest
@testable import MonitorKit

private extension ComposerRecall {
    /// 履歴が同じなら同じ印になる、試験用の呼び出し。
    mutating func move(_ direction: Direction, history: [String], current: String) -> Outcome {
        move(direction, current: current, stamp: { history.joined(separator: "\u{1}") }, history: { history })
    }
}

final class ComposerHistoryTests: XCTestCase {
    private func user(_ id: String, _ text: String, at: Double? = nil) -> TranscriptItem {
        TranscriptItem(id: id, kind: .user, at: at, text: text, tool: nil, parentId: nil)
    }

    private func assistant(_ id: String, _ text: String) -> TranscriptItem {
        TranscriptItem(id: id, kind: .assistant, at: nil, text: text, tool: nil, parentId: nil)
    }

    private func tool(_ id: String) -> TranscriptItem {
        TranscriptItem(id: id, kind: .tool, at: nil, text: nil, tool: TranscriptTool(name: "Bash", description: nil, target: "ls"), parentId: nil)
    }

    // MARK: - 組み立て

    func testOnlyUserUtterancesNewestFirst() {
        let items = [user("1", "一つ目"), assistant("2", "返答"), tool("3"), user("4", "二つ目"), assistant("5", "返答2")]
        XCTAssertEqual(ComposerHistory.entries(items: items), ["二つ目", "一つ目"])
    }

    func testConsecutiveDuplicatesCollapse() {
        let items = [user("1", "A"), user("2", "B"), assistant("x", "…"), user("3", "B"), user("4", " B \n"), user("5", "A")]
        XCTAssertEqual(ComposerHistory.entries(items: items), ["A", "B", "A"])
    }

    func testRelayInjectionsAreExcluded() {
        let items = [user("1", "自分の発話"), user("2", "\(RelayNotes.peerPrefix)\n伝言の本文"), user("3", "送った伝言", at: 10_000)]
        let note = RelayNote(text: "送った伝言", sentAt: 9_000, state: .sent)
        XCTAssertEqual(ComposerHistory.entries(items: items, notes: [note]), ["自分の発話"])
    }

    func testEmptyAfterStrippingIsSkipped() {
        let items = [user("1", "本文"), user("2", ChatImageText.placeholder)]
        XCTAssertEqual(ComposerHistory.entries(items: items), ["本文"])
    }

    func testRecallableDropsImageMarksAndFileList() {
        XCTAssertEqual(ComposerHistory.recallable("[Image #1] [Image #2] これを見て"), "これを見て")
        XCTAssertEqual(ComposerHistory.recallable("説明\n\(ChatImageText.placeholder)"), "説明")
        XCTAssertEqual(ComposerHistory.recallable("読んで\n\n添付:\n/tmp/a.txt\n\"/tmp/b c.pdf\""), "読んで")
        XCTAssertEqual(ComposerHistory.recallable("添付:\n/tmp/a.txt"), "")
        // 本文の途中の「添付:」はファイルの一覧ではないので残す。
        XCTAssertEqual(ComposerHistory.recallable("添付:\nについて説明して"), "添付:\nについて説明して")
    }

    func testRestoreContinueMessageIsExcluded() {
        let items = [user("1", "自分の発話"), user("2", SessionRestore.continueMessage)]
        XCTAssertEqual(ComposerHistory.entries(items: items), ["自分の発話"])
    }

    func testUnrecordedSentBeforeLastRecordedIsDropped() {
        // 取り下げた・bash モードなどで記録されなかった送信は、後の発話が記録されたら出さない。
        let sent = [ComposerHistory.Sent(text: "取り下げた", sentAt: 10_000), ComposerHistory.Sent(text: "送信中", sentAt: 30_000)]
        let items = [user("1", "端末で打った", at: 20_000)]
        XCTAssertEqual(ComposerHistory.pending(sent, in: items, now: 31_000).map(\.text), ["送信中"])
        XCTAssertEqual(ComposerHistory.entries(items: items, sent: sent, now: 31_000), ["送信中", "端末で打った"])
    }

    func testExpiredSentIsDroppedWhenRead() {
        let sent = [ComposerHistory.Sent(text: "古い", sentAt: 0), ComposerHistory.Sent(text: "新しい", sentAt: 1_000)]
        let now = ComposerHistory.sentLifetime + 500
        XCTAssertEqual(ComposerHistory.entries(items: [], sent: sent, now: now), ["新しい"])
        XCTAssertEqual(ComposerHistory.entries(items: [], sent: sent), ["新しい", "古い"])
    }

    func testPendingDropsRecorded() {
        let sent = [ComposerHistory.Sent(text: "A", sentAt: 10_000), ComposerHistory.Sent(text: "B", sentAt: 11_000)]
        let items = [user("1", "A", at: 10_500)]
        XCTAssertEqual(ComposerHistory.pending(sent, in: items, now: 12_000).map(\.text), ["B"])
        XCTAssertEqual(ComposerHistory.pending(sent, in: items + [user("2", "B", at: 11_500)], now: 12_000), [])
    }

    func testSendingUtteranceIsIncludedUntilRecorded() {
        let items = [user("1", "前の発話", at: 1_000)]
        let sent = [ComposerHistory.Sent(text: "送信中の発話", sentAt: 50_000)]
        XCTAssertEqual(ComposerHistory.entries(items: items, sent: sent), ["送信中の発話", "前の発話"])
        // 記録されたら transcript の方を使い、二重にしない。
        let recorded = items + [user("2", "送信中の発話", at: 51_000)]
        XCTAssertEqual(ComposerHistory.unrecorded(sent, in: recorded), [])
        XCTAssertEqual(ComposerHistory.entries(items: recorded, sent: sent), ["送信中の発話", "前の発話"])
    }

    func testOlderRecordWithSameTextDoesNotCountAsRecorded() {
        let items = [user("1", "もう一度", at: 1_000), user("2", "別の話", at: 2_000)]
        let sent = [ComposerHistory.Sent(text: "もう一度", sentAt: 100_000)]
        XCTAssertEqual(ComposerHistory.entries(items: items, sent: sent), ["もう一度", "別の話", "もう一度"])
    }

    func testSendingWithAttachmentsMatchesRecord() {
        let sent = [ComposerHistory.Sent(text: "画像の説明", sentAt: 10_000)]
        let items = [user("1", "[Image #1] 画像の説明\n\n添付:\n/tmp/a.txt", at: 10_500)]
        XCTAssertEqual(ComposerHistory.unrecorded(sent, in: items), [])
    }

    func testAppendingDropsStaleAndCaps() {
        var sent = [ComposerHistory.Sent(text: "古い", sentAt: 0)]
        sent = ComposerHistory.appending(ComposerHistory.Sent(text: "新しい", sentAt: ComposerHistory.sentLifetime + 1), to: sent)
        XCTAssertEqual(sent.map(\.text), ["新しい"])
        for i in 0..<(ComposerHistory.sentLimit + 5) {
            sent = ComposerHistory.appending(ComposerHistory.Sent(text: "\(i)", sentAt: ComposerHistory.sentLifetime + 2), to: sent)
        }
        XCTAssertEqual(sent.count, ComposerHistory.sentLimit)
        XCTAssertEqual(sent.last?.text, "\(ComposerHistory.sentLimit + 4)")
    }

    // MARK: - ↑ / ↓ の状態遷移

    func testAtStartOnlyWithoutSelectionOrMarkedText() {
        XCTAssertTrue(ComposerRecall.isAtStart(selection: NSRange(location: 0, length: 0), hasMarkedText: false))
        XCTAssertFalse(ComposerRecall.isAtStart(selection: NSRange(location: 1, length: 0), hasMarkedText: false))
        XCTAssertFalse(ComposerRecall.isAtStart(selection: NSRange(location: 0, length: 3), hasMarkedText: false))
        XCTAssertFalse(ComposerRecall.isAtStart(selection: NSRange(location: 0, length: 0), hasMarkedText: true))
    }

    func testUpWalksOlderAndDownRestoresDraft() {
        let history = ["C", "B", "A"]
        var recall = ComposerRecall()
        XCTAssertEqual(recall.move(.older, history: history, current: "打ちかけ"), .show("C"))
        XCTAssertEqual(recall.move(.older, history: history, current: "C"), .show("B"))
        XCTAssertEqual(recall.move(.older, history: history, current: "B"), .show("A"))
        // 一番古い所では止まる（文は変えずキーは受ける）。
        XCTAssertEqual(recall.move(.older, history: history, current: "A"), .stay)
        XCTAssertEqual(recall.position, 2)
        XCTAssertEqual(recall.move(.newer, history: history, current: "A"), .show("B"))
        XCTAssertEqual(recall.move(.newer, history: history, current: "B"), .show("C"))
        // 一番新しいものより先へ進むと、呼び出す前の下書きに戻る。
        XCTAssertEqual(recall.move(.newer, history: history, current: "C"), .show("打ちかけ"))
        XCTAssertNil(recall.position)
        // 下書きに戻った後の ↓ は既定の動き。
        XCTAssertEqual(recall.move(.newer, history: history, current: "打ちかけ"), .pass)
    }

    func testDownWithoutRecallingAndUpWithEmptyHistoryPass() {
        var recall = ComposerRecall()
        XCTAssertEqual(recall.move(.newer, history: ["A"], current: "x"), .pass)
        XCTAssertEqual(recall.move(.older, history: [], current: "x"), .pass)
        XCTAssertNil(recall.position)
    }

    func testEditingRecalledTextMakesItTheNewDraft() {
        let history = ["B", "A"]
        var recall = ComposerRecall()
        XCTAssertEqual(recall.move(.older, history: history, current: ""), .show("B"))
        // 呼び出した文を直した後の ↓ は既定の動き（呼び出しをやめている）。
        XCTAssertEqual(recall.move(.newer, history: history, current: "B を直した"), .pass)
        XCTAssertNil(recall.position)
        // 直した文が新しい下書きになり、↑ は一番新しい履歴から。
        XCTAssertEqual(recall.move(.older, history: history, current: "B を直した"), .show("B"))
        XCTAssertEqual(recall.move(.newer, history: history, current: "B"), .show("B を直した"))
        XCTAssertEqual(history, ["B", "A"])
    }

    func testResetStartsOver() {
        var recall = ComposerRecall()
        _ = recall.move(.older, history: ["B", "A"], current: "下書き")
        _ = recall.move(.older, history: ["B", "A"], current: "B")
        recall.reset()
        XCTAssertNil(recall.position)
        XCTAssertEqual(recall.move(.older, history: ["Y", "X"], current: "別のルーム"), .show("Y"))
        XCTAssertEqual(recall.move(.newer, history: ["Y", "X"], current: "Y"), .show("別のルーム"))
    }

    func testShrunkHistoryKeepsShownItemOrClamps() {
        var recall = ComposerRecall()
        _ = recall.move(.older, history: ["C", "B", "A"], current: "")
        _ = recall.move(.older, history: ["C", "B", "A"], current: "C")
        _ = recall.move(.older, history: ["C", "B", "A"], current: "B")
        // 出している A が無くなったら一番古い所に合わせ、それより古い物は無いので止まる。
        XCTAssertEqual(recall.move(.older, history: ["C", "B"], current: "A"), .stay)
        XCTAssertEqual(recall.move(.newer, history: ["C", "B"], current: "A"), .show("C"))
        XCTAssertEqual(recall.move(.newer, history: [], current: "C"), .show(""))
    }

    // MARK: - 組み立ての回数

    func testBuildsOnceWhileWalkingAndRebuildsWhenSourceChanges() {
        var recall = ComposerRecall()
        var builds = 0
        var stamps = 0
        var source = ["C", "B", "A"]
        var version = "1"
        func move(_ direction: ComposerRecall.Direction, _ current: String) -> ComposerRecall.Outcome {
            recall.move(direction, current: current, stamp: { stamps += 1; return version }, history: { builds += 1; return source })
        }
        // 呼び出していない時の ↓（空欄を含む）は組み立てない。
        XCTAssertEqual(move(.newer, ""), .pass)
        XCTAssertEqual(move(.newer, "打ちかけ"), .pass)
        XCTAssertEqual(builds, 0)
        XCTAssertEqual(stamps, 0)
        XCTAssertEqual(move(.older, "打ちかけ"), .show("C"))
        XCTAssertEqual(move(.older, "C"), .show("B"))
        XCTAssertEqual(move(.newer, "B"), .show("C"))
        XCTAssertEqual(builds, 1)
        // transcript が増えたら作り直す。
        source = ["N", "C", "B", "A"]
        version = "2"
        XCTAssertEqual(move(.older, "C"), .show("B"))
        XCTAssertEqual(builds, 2)
        // 下書きに戻った後に辿り始めたら、もう一度組み立てる。
        _ = move(.newer, "B")
        _ = move(.newer, "C")
        XCTAssertEqual(move(.newer, "N"), .show("打ちかけ"))
        XCTAssertEqual(move(.older, "打ちかけ"), .show("N"))
        XCTAssertEqual(builds, 3)
    }

    func testNewUtteranceDuringRecallKeepsShownItem() {
        var recall = ComposerRecall()
        XCTAssertEqual(recall.move(.older, history: ["B", "A"], current: "下書き"), .show("B"))
        // 呼び出し中に新しい発話 N が届いても、出している B の次（A）へ進む。
        XCTAssertEqual(recall.move(.older, history: ["N", "B", "A"], current: "B"), .show("A"))
        XCTAssertEqual(recall.position, 2)
        XCTAssertEqual(recall.move(.newer, history: ["N", "B", "A"], current: "A"), .show("B"))
    }

    func testReanchorFindsShownNearestWhenListIsRebuilt() {
        XCTAssertEqual(ComposerRecall.reanchor(1, shown: "B", old: ["C", "B", "A"], new: ["X", "C", "B", "A"]), 2)
        XCTAssertEqual(ComposerRecall.reanchor(3, shown: "B", old: ["D", "B", "C", "B"], new: ["B", "Z", "Q", "D", "B"]), 4)
        XCTAssertEqual(ComposerRecall.reanchor(2, shown: "Q", old: ["C", "B", "Q"], new: ["C", "B"]), 1)
        XCTAssertNil(ComposerRecall.reanchor(0, shown: "B", old: ["B"], new: []))
    }

    // MARK: - ルーム・タブの切り替え

    func testRewindKeepsSavedDraftForDown() {
        var recall = ComposerRecall()
        _ = recall.move(.older, history: ["C", "B", "A"], current: "打ちかけ")
        _ = recall.move(.older, history: ["C", "B", "A"], current: "C")
        recall.rewind()
        XCTAssertNil(recall.position)
        XCTAssertFalse(recall.isIdle)
        // 戻ってきた後の ↓ は組み立てずに退避した下書きへ戻す。
        var builds = 0
        let outcome = recall.move(.newer, current: "B", stamp: { "" }, history: { builds += 1; return [] })
        XCTAssertEqual(outcome, .show("打ちかけ"))
        XCTAssertEqual(builds, 0)
        XCTAssertTrue(recall.isIdle)
    }

    func testUpAfterRewindStartsFromNewestAndKeepsDraft() {
        var recall = ComposerRecall()
        _ = recall.move(.older, history: ["C", "B", "A"], current: "打ちかけ")
        recall.rewind()
        // 欄に出ている C は飛ばして、その前から辿る。
        XCTAssertEqual(recall.move(.older, history: ["C", "B", "A"], current: "C"), .show("B"))
        XCTAssertEqual(recall.move(.newer, history: ["C", "B", "A"], current: "B"), .show("C"))
        XCTAssertEqual(recall.move(.newer, history: ["C", "B", "A"], current: "C"), .show("打ちかけ"))
    }

    func testRewoundStateDropsWhenFieldChanged() {
        var recall = ComposerRecall()
        _ = recall.move(.older, history: ["C"], current: "打ちかけ")
        recall.rewind()
        XCTAssertEqual(recall.move(.newer, history: ["C"], current: "別の文"), .pass)
        XCTAssertTrue(recall.isIdle)
    }

    // MARK: - 入力欄への反映

    @MainActor
    func testUndoOnceReturnsToTextBeforeRecall() {
        final class Delegate: NSObject, NSTextViewDelegate {
            let undo = UndoManager()
            func undoManager(for view: NSTextView) -> UndoManager? { undo }
        }
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        let delegate = Delegate()
        textView.delegate = delegate
        textView.allowsUndo = true
        // 試験ではイベントの区切りが来ないので、打鍵と入れ替えをそれぞれ 1 回の操作として区切る。
        delegate.undo.groupsByEvent = false
        delegate.undo.beginUndoGrouping()
        textView.insertText("打ちかけ", replacementRange: NSRange(location: NSNotFound, length: 0))
        delegate.undo.endUndoGrouping()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        delegate.undo.beginUndoGrouping()
        textView.replaceAllForRecall(with: "前に送った")
        delegate.undo.endUndoGrouping()
        XCTAssertEqual(textView.string, "前に送った")
        delegate.undo.undo()
        XCTAssertEqual(textView.string, "打ちかけ")
    }

    @MainActor
    func testReplaceKeepsCursorAtStartAndNotifiesDelegate() {
        final class Delegate: NSObject, NSTextViewDelegate {
            var published: [String] = []
            func textDidChange(_ notification: Notification) {
                published.append((notification.object as? NSTextView)?.string ?? "")
            }
        }
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        let delegate = Delegate()
        textView.delegate = delegate
        textView.string = "打ちかけ"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.replaceAllForRecall(with: "前に送った\n2 行目")
        XCTAssertEqual(textView.string, "前に送った\n2 行目")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(delegate.published, ["前に送った\n2 行目"])
    }
}
