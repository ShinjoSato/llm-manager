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

    /// 本文を入力欄に貼ってから Enter で送る（作業中は Claude Code がキューに積む）。`.started` の時だけ結末を `completion` に 1 回返す。
    /// `sendId` は送信の印（入らなかった本文が後から端末から送られた時に、どの送信のものかを突き合わせる）。
    func sendMessage(_ text: String, attachments: [Attachment] = [], sendId: String = UUID().uuidString,
                     completion: @escaping (SendCompletion) -> Void) -> SendResult {
        guard !isSending else {
            sendLog?("refuse", [("reason", isClearingInput ? "clearing" : "busy")])
            return .busy
        }
        let screen = screenLines()
        if let block = InputBlock.detect(screen: screen, waiting: sessionWaiting(fresh: true), screenChangedAt: lastDataTime) {
            sendLog?("refuse", [("reason", Self.blockName(block))])
            return .blocked(block)
        }
        let box = inputBoxText(screen)
        let check = leftoverCheck
        let (decision, next) = check.decide(box: box)
        if case .refuse(let strict) = decision {
            sendLog?("refuse", [("reason", strict ? "lateLeftover" : "leftover")] + leftoverFields(check, box: box, screen: screen))
        }
        leftoverCheck = next
        if case .refuse(let strict) = decision { return strict ? .lateLeftover : .leftover }
        let bracketed = getTerminal().bracketedPasteMode
        let message = AttachmentFormat.outgoing(text: text, attachments: attachments, pasteImages: bracketed)
        let body = PTYInput.messageBody(message.body, bracketedPaste: bracketed)
        let imagePaste = message.imagePaste.flatMap { PTYInput.messageBody($0, bracketedPaste: true) }
        guard imagePaste != nil || body != nil else { return .empty }
        isSending = true
        sendLog?("start", SendOpsFields.text(message.body, prefix: "body")
            + [("images", "\(message.imageCount)"), ("bracketed", bracketed ? "yes" : "no"),
               ("working", screenState.status == .working ? "yes" : "no"), ("check", check.logName)]
            + SendOpsFields.box(box, body: nil, baseline: nil, prefix: "before") + (box == nil ? SendOpsFields.shape(screen) : []))
        let finish: (SendCompletion) -> Void = { [weak self] outcome in
            self?.isSending = false
            completion(outcome)
        }
        guard let imagePaste else {
            if let body { pasteAndSubmit(body, before: box, imagesPasted: false, sendId: sendId, finish: finish) }
            return .started(pastedImages: [], body: message.body)
        }
        // 画像のパスだけを先に 1 回で貼る（本文と同じ貼り付けだと TUI が本文を空白 + / や改行で割って繋ぎ直すため）。
        let before = box.map(AttachmentFormat.imageTokenCount)
        send(txt: imagePaste)
        waitForImages(expected: before.map { $0 + message.imageCount },
                      deadline: Date().addingTimeInterval(AttachmentFormat.imageIngestTimeout)) { [weak self] ingested in
            guard let self else { return finish(.ended) }
            self.sendLog?("images", [("ingested", ingested ? "yes" : "no")])
            if let block = self.currentInputBlock() {
                // 本文は貼っていないが、入力欄には画像の印が残る。
                self.leftoverCheck = .warnOnce
                self.sendLog?("aborted", [("stage", "beforeBody"), ("block", Self.blockName(block))])
                return finish(.abortedBeforeBody(block))
            }
            // 取り込みを確かめられなかった時は Enter が捨てられているかもしれないので、次の送信で入力欄の残りを確かめる。
            if !ingested { self.leftoverCheck = .warnOnce }
            if let body {
                self.pasteAndSubmit(body, before: self.inputBoxText(self.screenLines()), imagesPasted: true, sendId: sendId, finish: finish)
            } else {
                self.send(txt: PTYInput.submitKey)
                self.sendLog?("enter", [("verdict", "imagesOnly")])
                finish(.submitted)
            }
        }
        return .started(pastedImages: message.imagePaths, body: message.body)
    }

    /// 送らなかった時の記録の項目（入力欄の読み取り・入らなかった本文が見えるか・読めない時は画面の形）。
    func leftoverFields(_ check: LeftoverCheck, box: String?, screen: [String]) -> [(String, String)] {
        var fields: [(String, String)] = [("check", check.logName)]
        if case .untilClear(let baseline, let body, _, let touched) = check {
            if touched { fields.append(("touched", "yes")) }
            fields += SendOpsFields.box(box, body: body, baseline: baseline)
            if box == nil, let since = leftoverUnreadable.since {
                fields.append(("unreadableFor", "\(Int(Date().timeIntervalSince(since)))s"))
            }
        } else {
            fields += SendOpsFields.box(box, body: nil, baseline: nil)
        }
        return fields + (box == nil ? SendOpsFields.shape(screen) : inputBoxStyle(screen: screen))
    }

    static func blockName(_ block: InputBlock) -> String { block == .permission ? "permission" : "menu" }

    /// 本文を貼り、端末の入力欄に入ったのを確かめてから Enter を送る。`before` は貼る前の入力欄（読めなければ nil）。
    private func pasteAndSubmit(_ body: String, before: String?, imagesPasted: Bool, sendId: String,
                                finish: @escaping (SendCompletion) -> Void) {
        send(txt: body)
        let started = Date()
        let working = screenState.status == .working
        let deadline = started.addingTimeInterval(PTYInput.submitDelay + PasteCheck.extraWait(bodyLength: body.count, working: working))
        let attempt = PasteAttempt(body: body, before: before, imagesPasted: imagesPasted, sendId: sendId, started: started, deadline: deadline)
        DispatchQueue.main.asyncAfter(deadline: .now() + PTYInput.submitDelay) { [weak self] in
            self?.submitIfPasted(attempt, polls: 0, finish: finish) ?? finish(.ended)
        }
    }

    /// 貼った 1 回分（入ったかを確かめる間に持ち回る）。
    private struct PasteAttempt {
        let body: String
        let before: String?
        let imagesPasted: Bool
        let sendId: String
        let started: Date
        let deadline: Date

        var plainBody: String { PasteCheck.plainText(body) }
        var elapsed: String { "\(Int(Date().timeIntervalSince(started) * 1000))ms" }
    }

    private func submitIfPasted(_ attempt: PasteAttempt, polls: Int, finish: @escaping (SendCompletion) -> Void) {
        if let block = currentInputBlock() {
            leftoverCheck = .warnOnce
            sendLog?("aborted", [("stage", "afterBody"), ("block", Self.blockName(block)), ("polls", "\(polls)"), ("elapsed", attempt.elapsed)])
            return finish(.abortedAfterBody(block))
        }
        let screen = screenLines()
        let after = inputBoxText(screen)
        let verdict = PasteCheck.judge(before: attempt.before, after: after, body: attempt.body)
        let fields = { [unowned self] () -> [(String, String)] in
            [("polls", "\(polls)"), ("elapsed", attempt.elapsed)]
                + SendOpsFields.box(after, body: attempt.plainBody, baseline: attempt.before, prefix: "after")
                + (after == nil ? SendOpsFields.shape(screen) : self.inputBoxStyle(screen: screen))
        }
        switch verdict {
        case .pasted, .unknown:
            send(txt: PTYInput.submitKey)
            sendLog?("enter", [("verdict", verdict == .pasted ? "pasted" : "unknown")] + fields())
            finish(.submitted)
        case .missing:
            guard Date() >= attempt.deadline else {
                if polls == 0 { sendLog?("check", [("verdict", "missing")] + fields()) }
                DispatchQueue.main.asyncAfter(deadline: .now() + PasteCheck.pollInterval) { [weak self] in
                    self?.submitIfPasted(attempt, polls: polls + 1, finish: finish) ?? finish(.ended)
                }
                return
            }
            sendLog?("notPasted", [("imagesPasted", attempt.imagesPasted ? "yes" : "no")] + fields())
            // 後から届いた貼り付けが入力欄に残るかもしれないので、次の送信で確かめる。
            leftoverCheck = .untilClear(baseline: attempt.before ?? "", body: attempt.plainBody, id: attempt.sendId)
            finish(.notPasted(imagesPasted: attempt.imagesPasted))
        }
    }

    // MARK: - 残りの抜け道

    enum LeftoverActionResult: Equatable {
        case done
        /// 送信・入力欄の消去・選択肢の移動の途中。
        case busy
        /// 権限の確認・選択肢が出ている（Enter や消すキーがそちらに効くため送らない）。
        case blocked
        /// 入らなかった本文が端末の入力欄に見えない。
        case notShown
        /// もう止めていない。
        case notNeeded
        /// 入力欄を読めない状態がまだ長く続いていない。
        case tooEarly
        /// 入力欄が見つからない（消すキーがどこに効くか分からないので送らない）。
        case unreadable
        case ended
    }

    /// 入らなかった本文が端末の入力欄に見えている時に、そのまま Enter で送る。
    func submitLeftover() -> LeftoverActionResult {
        guard process?.running == true else { return .ended }
        guard !isSending, !isNavigatingMenu else { return .busy }
        guard case .untilClear = leftoverCheck else { return .notNeeded }
        guard currentInputBlock() == nil else { return .blocked }
        let screen = screenLines()
        let box = inputBoxText(screen)
        let match = leftoverCheck.match(box: box)
        guard match != .none else {
            sendLog?("submitLeftover", [("result", "notShown")] + leftoverFields(leftoverCheck, box: box, screen: screen))
            return .notShown
        }
        send(txt: PTYInput.submitKey)
        sendLog?("submitLeftover", [("result", "sent")] + leftoverFields(leftoverCheck, box: box, screen: screen))
        submittedLeftover(confirmed: match == .text)
        evaluateStatus()
        return .done
    }

    /// 入らなかった本文を端末から送った。止めるのをやめ、どの送信のものかと中身を確かめられたかを知らせる。
    private func submittedLeftover(confirmed: Bool) {
        let id = leftoverCheck.lateId ?? ""
        leftoverCheck = .none
        onLeftoverSubmitted?(id, confirmed)
    }

    /// 入力欄を読めない状態が続いた時に、確かめられないまま次の送信を通す。
    func overrideLeftover() -> LeftoverActionResult {
        guard process?.running == true else { return .ended }
        guard !isSending, !isClearingInput, !isNavigatingMenu else { return .busy }
        guard case .untilClear = leftoverCheck else { return .notNeeded }
        let screen = screenLines()
        guard let escape = leftoverEscape(screen: screen, blocked: currentInputBlock() != nil) else {
            return currentInputBlock() != nil ? .blocked : .notNeeded
        }
        guard escape.canForce else { return .tooEarly }
        sendLog?("force", leftoverFields(leftoverCheck, box: nil, screen: screen))
        leftoverCheck = .none
        evaluateStatus()
        return .done
    }

    enum ClearOutcome: Equatable {
        /// 入力欄が空と読めた。
        case cleared
        /// 入力欄を読めず、空になったか確かめられない。
        case unverified
        /// 繰り返しても入力欄の表示が変わらない（薄字の候補などで、実際は空のこともある）。
        case stuck
        /// 途中で権限の確認・選択肢が出たのでやめた。
        case blocked
        case ended
    }

    /// 端末の入力欄を空にする。`PTYInput.clearInputRound` を 1 組ずつ送り、空と読めるまで繰り返す。
    /// 結末は始めた時だけ `onClearFinished` に 1 回知らせる。入力欄が見つからない時は始めない。
    func clearInput() -> LeftoverActionResult {
        guard process?.running == true else { return .ended }
        guard !isSending, !isNavigatingMenu, !isClearingInput else { return .busy }
        guard currentInputBlock() == nil else { return .blocked }
        let screen = screenLines()
        guard let box = inputBoxText(screen) else {
            sendLog?("clear", [("phase", "refused"), ("check", leftoverCheck.logName), ("box", "unreadable")] + SendOpsFields.shape(screen))
            return .unreadable
        }
        isClearingInput = true
        // 消している間の送信・キーを止める（入力欄からの送信と同じ印を使う）。
        isSending = true
        sendLog?("clear", [("phase", "start"), ("check", leftoverCheck.logName)] + SendOpsFields.box(box, body: nil, baseline: nil))
        clearRound(0, unreadable: 0, stalled: 0, last: box)
        return .done
    }

    /// `unreadable` は続けて読めなかった組の数。
    private func clearRound(_ round: Int, unreadable: Int, stalled: Int, last: String?) {
        guard process?.running == true else { return finishClear(.ended, rounds: round, box: nil) }
        if currentInputBlock() != nil { return finishClear(.blocked, rounds: round, box: nil) }
        for (index, key) in PTYInput.clearInputRound.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + PTYInput.clearKeyInterval * Double(index)) { [weak self] in
                // 途中で選択肢が出たら、消すキーがそちらに効かないよう残りを送らない。
                guard let self, self.isClearingInput, self.process?.running == true, self.currentInputBlock() == nil else { return }
                self.send(txt: key)
            }
        }
        let wait = PTYInput.clearKeyInterval * Double(PTYInput.clearInputRound.count) + PTYInput.clearCheckDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            let next = round + 1
            guard self.process?.running == true else { return self.finishClear(.ended, rounds: next, box: nil) }
            if self.currentInputBlock() != nil { return self.finishClear(.blocked, rounds: next, box: nil) }
            guard let box = self.inputBoxText(self.screenLines()) else {
                guard unreadable + 1 < PTYInput.clearUnreadableRounds, next < PTYInput.clearMaxRounds else {
                    return self.finishClear(.unverified, rounds: next, box: nil)
                }
                return self.clearRound(next, unreadable: unreadable + 1, stalled: 0, last: nil)
            }
            if box.isEmpty { return self.finishClear(.cleared, rounds: next, box: box) }
            let stalledNow = box == last ? stalled + 1 : 0
            guard stalledNow < PTYInput.clearStallRounds, next < PTYInput.clearMaxRounds else {
                return self.finishClear(.stuck, rounds: next, box: box)
            }
            self.clearRound(next, unreadable: 0, stalled: stalledNow, last: box)
        }
    }

    private func finishClear(_ outcome: ClearOutcome, rounds: Int, box: String?) {
        isClearingInput = false
        isSending = false
        switch outcome {
        case .cleared:
            leftoverCheck = .none
        case .unverified, .stuck:
            // 消すのを選んだので止め続けはしないが、残っていれば次の送信の前に一度だけ知らせる。
            leftoverCheck = .warnOnce
        case .blocked, .ended:
            break
        }
        sendLog?("clear", [("phase", "end"), ("outcome", "\(outcome)"), ("rounds", "\(rounds)")] + SendOpsFields.box(box, body: nil, baseline: nil))
        evaluateStatus()
        onClearFinished?(outcome)
    }

    /// 入力欄の `[Image #N]` が `expected` 個になるか期限まで待つ。入力欄を読めなければ期限まで待って false。
    private func waitForImages(expected: Int?, deadline: Date, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + AttachmentFormat.imageIngestPollInterval) { [weak self] in
            guard let self else { return completion(false) }
            if let expected, let box = self.inputBoxText(self.screenLines()),
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
        /// 押せない選択肢（自由入力）か、タブを移れない位置。
        case unavailable
        /// 別の選択肢・タブへ動かしている最中。
        case navigating
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

    /// 選択メニューに答える（`choice` が nil なら Esc）。今のメニューが `expected` と同じ時だけ、❯ を 1 行ずつ動かして着いたのを確かめてから Enter。
    func answerMenu(_ expected: MenuPrompt, choice: Int?, completion: @escaping (MenuAnswerOutcome) -> Void) {
        let card = PromptCardIdentity.menu(expected)
        guard !isNavigatingMenu else { return completion(.navigating) }
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
            opsLog?("key", [("card", card), ("send", "esc")])
            return completion(.cancelled)
        }
        guard let navigator = MenuNavigator(expected: expected, target: choice) else { return completion(.unavailable) }
        if let refusal = beginNavigation() { return completion(refusal) }
        opsLog?("navigate", [("card", card), ("target", "\(choice)"), ("cursor", "\(expected.cursor)")])
        stepMenu(navigator, waits: 0, completion: completion)
    }

    /// ❯ の移動を始める。前回やめた矢印の反映を待つ間は `.settling` を返して始めない。
    private func beginNavigation() -> MenuAnswerOutcome? {
        releasePendingArrowHoldIfDone(cursor: currentMenu()?.cursor)
        guard pendingArrowHold == nil else { return .settling }
        isNavigatingMenu = true
        return nil
    }

    /// 移動をやめる。未反映の矢印が残りうるので `hold` が外れるまで次の移動を始めない。
    private func abortNavigation(_ failure: MenuNavigator.Failure, hold: PendingArrowHold?,
                                 completion: (MenuAnswerOutcome) -> Void) {
        isNavigatingMenu = false
        pendingArrowHold = hold
        evaluateStatus()
        completion(.failed(failure))
    }

    /// `waits` は続けて待った回数（記録を 1 行にまとめるため）。
    private func stepMenu(_ navigator: MenuNavigator, waits: Int, completion: @escaping (MenuAnswerOutcome) -> Void) {
        var navigator = navigator
        let card = PromptCardIdentity.menu(navigator.expected)
        guard process?.running == true else {
            isNavigatingMenu = false
            opsLog?("step", [("card", card), ("action", "ended")])
            return completion(.ended)
        }
        let current = currentMenu()
        let action = navigator.next(current)
        if action != .wait {
            opsLog?("step", [("card", card), ("cursor", current.map { "\($0.cursor)" } ?? "-"), ("waited", "\(waits)"),
                             ("action", Self.actionName(action))])
        }
        switch action {
        case .confirm:
            send(txt: PTYInput.confirmMenuKey)
            isNavigatingMenu = false
            completion(.confirmed)
            return
        case .abort(let failure):
            abortNavigation(failure, hold: PendingArrowHold.after(navigator, now: Date()), completion: completion)
            return
        case .press(let direction):
            send(txt: PTYInput.arrowKey(direction, applicationCursor: getTerminal().applicationCursor))
        case .wait:
            break
        }
        let nextWaits = action == .wait ? waits + 1 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + PTYInput.menuStepInterval) { [weak self] in
            // 移動中に端末ビューが解放されても、呼び出し側の送信中の印が残らないよう必ず結果を返す。
            guard let self else { return completion(.ended) }
            self.stepMenu(navigator, waits: nextWaits, completion: completion)
        }
    }

    static func actionName(_ action: MenuNavigator.Action) -> String {
        switch action {
        case .wait: return "wait"
        case .press(let direction): return direction == .down ? "press(down)" : "press(up)"
        case .confirm: return "confirm(enter)"
        case .abort(let failure): return "abort(\(failure))"
        }
    }

    static func actionName(_ action: MenuTabMover.Action) -> String {
        switch action {
        case .wait: return "wait"
        case .press(let direction): return direction == .next ? "press(right)" : "press(left)"
        case .moved: return "moved"
        case .abort(let failure): return "abort(\(failure))"
        }
    }

    /// 問いのタブを →/← で 1 つ移る。`expected` と今の画面のメニューが同じ時だけ送り、問いが替わったのを確かめて終える。
    func moveMenuTab(_ expected: MenuPrompt, direction: MenuTabMover.Direction, completion: @escaping (MenuAnswerOutcome) -> Void) {
        guard !isNavigatingMenu else { return completion(.navigating) }
        guard let mover = MenuTabMover(expected: expected, direction: direction) else { return completion(.unavailable) }
        if let refusal = beginNavigation() { return completion(refusal) }
        opsLog?("navigate", [("card", PromptCardIdentity.menu(expected)), ("tab", direction == .next ? "next" : "previous")])
        stepTab(mover, waits: 0, completion: completion)
    }

    private func stepTab(_ mover: MenuTabMover, waits: Int, completion: @escaping (MenuAnswerOutcome) -> Void) {
        var mover = mover
        let card = PromptCardIdentity.menu(mover.expected)
        guard process?.running == true else {
            isNavigatingMenu = false
            opsLog?("step", [("card", card), ("action", "ended")])
            return completion(.ended)
        }
        let action = mover.next(currentMenu())
        if action != .wait {
            opsLog?("step", [("card", card), ("waited", "\(waits)"), ("action", Self.actionName(action))])
        }
        switch action {
        case .moved:
            isNavigatingMenu = false
            evaluateStatus()
            completion(.moved)
            return
        case .abort(let failure):
            abortNavigation(failure, hold: PendingArrowHold.after(mover, now: Date()), completion: completion)
            return
        case .press(let direction):
            send(txt: PTYInput.tabKey(direction, applicationCursor: getTerminal().applicationCursor))
        case .wait:
            break
        }
        let nextWaits = action == .wait ? waits + 1 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + PTYInput.menuStepInterval) { [weak self] in
            guard let self else { return completion(.ended) }
            self.stepTab(mover, waits: nextWaits, completion: completion)
        }
    }

    enum KeySendResult: Equatable {
        case sent
        /// 選択肢へ ❯ を動かしている最中。重ねて送ると行き先がずれる。
        case navigating
        /// 入力欄からの送信の途中。貼り付けと Enter の間に割り込まない。
        case sending
        /// 端末の入力欄を消している最中。
        case clearing
        /// 権限の確認・選択肢が出ている（入力欄を消すキーがそちらに効くため送らない）。
        case blocked
        /// 入力欄が見つからない（消すキーがどこに効くか分からないので送らない）。
        case unreadable
        /// claude が動いていない・送れないキー。
        case ended
    }

    /// 「端末の画面」のキーを 1 回だけ送る。カードの移動中・入力欄の送信中・消している最中は送らない。
    func sendKey(_ key: TerminalKey) -> KeySendResult {
        guard !isNavigatingMenu else { return .navigating }
        guard !isClearingInput else { return .clearing }
        guard !isSending else { return .sending }
        guard process?.running == true else { return .ended }
        if key == .clearInput {
            switch clearInput() {
            case .done: return .sent
            case .blocked: return .blocked
            case .busy: return .sending
            case .unreadable: return .unreadable
            case .ended, .notShown, .notNeeded, .tooEarly: return .ended
            }
        }
        guard let text = key.sequence(applicationCursor: getTerminal().applicationCursor) else { return .ended }
        let cursor = key.movesCursor ? currentMenu()?.cursor : nil
        if key.movesCursor { releasePendingArrowHoldIfDone(cursor: cursor) }
        // 入らなかった本文が見えている入力欄で Enter を押したら、そのまま送ったのと同じに扱う。
        let match = key == .enter && currentInputBlock() == nil ? leftoverCheck.match(box: inputBoxText(screenLines())) : .none
        send(txt: text)
        // 反映前の矢印を数えずにカードの移動が始まると 1 行先で確定しうるので、反映まで待たせる。
        // 続けて押した時は最初の位置を残す（後の位置で上書きすると、1 回目の反映だけで外れてしまう）。
        if key.movesCursor { pendingArrowHold = PendingArrowHold(since: Date(), cursor: pendingArrowHold?.cursor ?? cursor) }
        if match != .none {
            sendLog?("submitLeftover", [("result", "sent"), ("from", "terminalScreen"), ("match", match == .text ? "text" : "folded")])
            submittedLeftover(confirmed: match == .text)
        } else if case .untilClear = leftoverCheck, key != .enter {
            // 履歴の呼び出しや文字で入力欄が変わりうるので、以後は本文が見えているとはみなさない。
            leftoverCheck = leftoverCheck.touched
        } else if leftoverCheck == .none {
            // 入力欄に文字や呼び出した履歴が残りうるので、次の送信の前に一度確かめさせる。
            leftoverCheck = .warnOnce
        }
        return .sent
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
        opsLog?("key", [("card", PromptCardIdentity.unreadable(expected)), ("send", "esc")])
        return .sent
    }
}
