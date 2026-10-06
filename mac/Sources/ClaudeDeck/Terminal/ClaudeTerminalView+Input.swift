import AppKit
import SwiftTerm
import MonitorKit

extension ClaudeTerminalView {
    // MARK: - 入力（本人のキー入力として PTY に書く）

    enum SendResult: Equatable {
        /// 送り始めた。結末は `completion` で返る。`pastedImages` は画像として貼った添付のパス、`body` は貼る本文。
        case started(pastedImages: [String], body: String)
        case empty
        /// 前の送信がまだ終わっていない。
        case busy
        /// 権限プロンプト・選択メニューの表示中。Enter がその選択になってしまうので送らない。
        case blocked(InputBlock)
        /// 取りやめた送信の本文が端末の入力欄に残っている。続けて貼ると前回の本文とくっつくので送らない。
        case leftover
        /// 入らなかった貼り付けが遅れて入ったか、入力欄を確かめられない。戻した本文と二重にならないよう空になるまで送らない。
        case lateLeftover
    }

    /// 本文を入力欄に貼り付けてから Enter で送る（作業中でも Claude Code がキューに積む）。止める時は何も貼らない。
    /// `.started` の時だけ、結末（送った・途中でやめた・端末が無くなった）を `completion` に 1 回返す。
    func sendMessage(_ text: String, attachments: [Attachment] = [], completion: @escaping (SendCompletion) -> Void) -> SendResult {
        guard !isSending else { return .busy }
        let screen = screenLines()
        if let block = InputBlock.detect(screen: screen, waiting: sessionWaiting(fresh: true), screenChangedAt: lastDataTime) {
            return .blocked(block)
        }
        let (decision, next) = leftoverCheck.decide(box: InputBox.text(screen: screen))
        leftoverCheck = next
        if case .refuse(let strict) = decision { return strict ? .lateLeftover : .leftover }
        let bracketed = getTerminal().bracketedPasteMode
        let message = AttachmentFormat.outgoing(text: text, attachments: attachments, pasteImages: bracketed)
        let body = PTYInput.messageBody(message.body, bracketedPaste: bracketed)
        let imagePaste = message.imagePaste.flatMap { PTYInput.messageBody($0, bracketedPaste: true) }
        guard imagePaste != nil || body != nil else { return .empty }
        isSending = true
        let finish: (SendCompletion) -> Void = { [weak self] outcome in
            self?.isSending = false
            completion(outcome)
        }
        guard let imagePaste else {
            if let body { pasteAndSubmit(body, before: InputBox.text(screen: screen), imagesPasted: false, finish: finish) }
            return .started(pastedImages: [], body: message.body)
        }
        // 画像のパスだけを先に 1 回で貼る（本文と同じ貼り付けだと TUI が本文を空白 + / や改行で割って繋ぎ直すため）。
        let before = InputBox.text(screen: screen).map(AttachmentFormat.imageTokenCount)
        send(txt: imagePaste)
        waitForImages(expected: before.map { $0 + message.imageCount },
                      deadline: Date().addingTimeInterval(AttachmentFormat.imageIngestTimeout)) { [weak self] ingested in
            guard let self else { return finish(.ended) }
            if let block = self.currentInputBlock() {
                // 本文は貼っていないが、入力欄には画像の印が残る。
                self.leftoverCheck = .warnOnce
                return finish(.abortedBeforeBody(block))
            }
            // 取り込みを確かめられなかった時は Enter が捨てられているかもしれないので、次の送信で入力欄の残りを確かめる。
            if !ingested { self.leftoverCheck = .warnOnce }
            if let body {
                self.pasteAndSubmit(body, before: InputBox.text(screen: self.screenLines()), imagesPasted: true, finish: finish)
            } else {
                self.send(txt: PTYInput.submitKey)
                finish(.submitted)
            }
        }
        return .started(pastedImages: message.imagePaths, body: message.body)
    }

    /// 本文を貼り、端末の入力欄に入ったのを確かめてから Enter を送る。`before` は貼る前の入力欄（読めなければ nil）。
    private func pasteAndSubmit(_ body: String, before: String?, imagesPasted: Bool, finish: @escaping (SendCompletion) -> Void) {
        send(txt: body)
        let deadline = Date().addingTimeInterval(PTYInput.submitDelay + PasteCheck.extraWait(bodyLength: body.count))
        DispatchQueue.main.asyncAfter(deadline: .now() + PTYInput.submitDelay) { [weak self] in
            self?.submitIfPasted(body, before: before, imagesPasted: imagesPasted, deadline: deadline, finish: finish) ?? finish(.ended)
        }
    }

    private func submitIfPasted(_ body: String, before: String?, imagesPasted: Bool, deadline: Date,
                                finish: @escaping (SendCompletion) -> Void) {
        if let block = currentInputBlock() {
            leftoverCheck = .warnOnce
            return finish(.abortedAfterBody(block))
        }
        switch PasteCheck.judge(before: before, after: InputBox.text(screen: screenLines()), body: body) {
        case .pasted, .unknown:
            send(txt: PTYInput.submitKey)
            finish(.submitted)
        case .missing:
            guard Date() >= deadline else {
                DispatchQueue.main.asyncAfter(deadline: .now() + PasteCheck.pollInterval) { [weak self] in
                    self?.submitIfPasted(body, before: before, imagesPasted: imagesPasted, deadline: deadline, finish: finish) ?? finish(.ended)
                }
                return
            }
            // 後から届いた貼り付けが入力欄に残るかもしれないので、次の送信で確かめる。
            leftoverCheck = .untilClear(baseline: before ?? "")
            finish(.notPasted(imagesPasted: imagesPasted))
        }
    }

    /// 入力欄の `[Image #N]` が `expected` 個になるか期限まで待つ。入力欄を読めなければ期限まで待って false。
    private func waitForImages(expected: Int?, deadline: Date, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + AttachmentFormat.imageIngestPollInterval) { [weak self] in
            guard let self else { return completion(false) }
            if let expected, let box = InputBox.text(screen: self.screenLines()),
               AttachmentFormat.imageTokenCount(in: box) >= expected {
                // 印が出た直後は貼り付け処理の後始末が残るので、本文の貼り付けを少しだけ遅らせる。
                DispatchQueue.main.asyncAfter(deadline: .now() + AttachmentFormat.imageIngestPollInterval) { completion(true) }
                return
            }
            guard Date() < deadline else { return completion(false) }
            self.waitForImages(expected: expected, deadline: deadline, completion: completion)
        }
    }

    enum AnswerResult: Equatable {
        case sent
        /// 権限プロンプトが出ていない。入力欄へ文字が入るのを避けて何もしない。
        case noPrompt
        /// 押した時に見ていたものと別のプロンプトに替わっている。
        case changed(PermissionPrompt)
    }

    /// 権限プロンプトに答える。`expected`（カードに出していたもの）と今の画面のプロンプトが一致する時だけキーを送る。
    func answerPermission(_ expected: PermissionPrompt, allow: Bool) -> AnswerResult {
        guard let current = PermissionPrompt.parse(screen: screenLines()) else {
            evaluateStatus()
            return .noPrompt
        }
        guard current == expected else {
            evaluateStatus()
            return .changed(current)
        }
        send(txt: allow ? PTYInput.allowKey : PTYInput.denyKey)
        return .sent
    }

    enum MenuAnswerOutcome: Equatable {
        case confirmed
        case cancelled
        case failed(MenuNavigator.Failure)
        /// 移動の途中で claude が終わった・端末ビューが無くなった（Enter は送っていない）。
        case ended
        /// 押せない選択肢（自由入力）か、別の選択肢へ動かしている最中。
        case unavailable
        /// 前回やめた移動の矢印がまだ反映されていないかもしれない。少し待てば押せる。
        case settling
        /// 問いのタブを移った。
        case moved
    }

    func releasePendingArrowHoldIfDone(cursor: Int?) {
        guard let hold = pendingArrowHold,
              hold.isReleased(now: Date(), lastOutput: lastDataTime, currentCursor: cursor) else { return }
        pendingArrowHold = nil
    }

    /// 選択メニューに答える。`choice` は `expected`（カードに出していたもの）の選択肢の位置、nil なら Esc で取り消す。
    /// 今の画面のメニューが `expected` と同じ時だけキーを送り、❯ を矢印で 1 行ずつ動かして着いたのを確かめてから Enter を送る。
    func answerMenu(_ expected: MenuPrompt, choice: Int?, completion: @escaping (MenuAnswerOutcome) -> Void) {
        guard !isNavigatingMenu else { return completion(.unavailable) }
        guard let choice else {
            guard let current = currentMenu() else {
                evaluateStatus()
                return completion(.failed(.gone))
            }
            // sameMenu は案内行を比べないので、Esc が終了になるかも揃っているかを別に見る。
            guard current.sameMenu(as: expected), current.cancelExits == expected.cancelExits else {
                evaluateStatus()
                return completion(.failed(.changed))
            }
            send(txt: PTYInput.cancelMenuKey)
            return completion(.cancelled)
        }
        guard let navigator = MenuNavigator(expected: expected, target: choice) else { return completion(.unavailable) }
        releasePendingArrowHoldIfDone(cursor: currentMenu()?.cursor)
        guard pendingArrowHold == nil else { return completion(.settling) }
        isNavigatingMenu = true
        stepMenu(navigator, completion: completion)
    }

    private func stepMenu(_ navigator: MenuNavigator, completion: @escaping (MenuAnswerOutcome) -> Void) {
        var navigator = navigator
        guard process?.running == true else {
            isNavigatingMenu = false
            return completion(.ended)
        }
        switch navigator.next(currentMenu()) {
        case .confirm:
            send(txt: PTYInput.confirmMenuKey)
            isNavigatingMenu = false
            completion(.confirmed)
            return
        case .abort(let failure):
            isNavigatingMenu = false
            pendingArrowHold = PendingArrowHold.after(navigator, now: Date())
            evaluateStatus()
            completion(.failed(failure))
            return
        case .press(let direction):
            send(txt: PTYInput.arrowKey(direction, applicationCursor: getTerminal().applicationCursor))
        case .wait:
            break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + PTYInput.menuStepInterval) { [weak self] in
            // 移動中に端末ビューが解放されても、呼び出し側の送信中の印が残らないよう必ず結果を返す。
            guard let self else { return completion(.ended) }
            self.stepMenu(navigator, completion: completion)
        }
    }

    /// 問いのタブを →/← で 1 つ移る。`expected` と今の画面のメニューが同じ時だけ送り、問いが替わったのを確かめて終える。
    func moveMenuTab(_ expected: MenuPrompt, direction: MenuTabMover.Direction, completion: @escaping (MenuAnswerOutcome) -> Void) {
        guard !isNavigatingMenu else { return completion(.unavailable) }
        guard let mover = MenuTabMover(expected: expected, direction: direction) else { return completion(.unavailable) }
        releasePendingArrowHoldIfDone(cursor: currentMenu()?.cursor)
        guard pendingArrowHold == nil else { return completion(.settling) }
        isNavigatingMenu = true
        stepTab(mover, completion: completion)
    }

    private func stepTab(_ mover: MenuTabMover, completion: @escaping (MenuAnswerOutcome) -> Void) {
        var mover = mover
        guard process?.running == true else {
            isNavigatingMenu = false
            return completion(.ended)
        }
        switch mover.next(currentMenu()) {
        case .moved:
            isNavigatingMenu = false
            evaluateStatus()
            completion(.moved)
            return
        case .abort(let failure):
            isNavigatingMenu = false
            pendingArrowHold = PendingArrowHold.after(mover, now: Date())
            evaluateStatus()
            completion(.failed(failure))
            return
        case .press(let direction):
            send(txt: PTYInput.tabKey(direction, applicationCursor: getTerminal().applicationCursor))
        case .wait:
            break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + PTYInput.menuStepInterval) { [weak self] in
            guard let self else { return completion(.ended) }
            self.stepTab(mover, completion: completion)
        }
    }

    enum UnreadableCancelResult: Equatable {
        case sent
        /// 読めないメニューが出ていない（消えた・読めるようになった）。
        case gone
        /// 押した時と別の画面になっている。
        case changed
    }

    /// 中身を読み取れない選択メニューを Esc で閉じる。押した時の写し `expected` と今の画面が同じ時だけ送る。
    func cancelUnreadableMenu(_ expected: UnreadableMenu) -> UnreadableCancelResult {
        guard !isNavigatingMenu else { return .changed }
        let screen = screenLines()
        guard let current = ChoiceMenu.unreadable(screen: screen, waiting: sessionWaiting(fresh: true), screenChangedAt: lastDataTime) else {
            evaluateStatus()
            return .gone
        }
        guard current == expected else {
            evaluateStatus()
            return .changed
        }
        send(txt: PTYInput.cancelMenuKey)
        return .sent
    }
}
