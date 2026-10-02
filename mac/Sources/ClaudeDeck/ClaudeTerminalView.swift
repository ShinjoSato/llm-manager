import AppKit
import SwiftTerm
import MonitorKit

/// Claude Code の作業状態（ペイン見出しのバッジ表示に使う）。
enum ClaudeStatus: Equatable {
    case working        // 出力が流れている（生成中）
    case waitingInput   // 権限確認・選択メニュー・質問プロンプトを検出（要応答）
    case idle           // 出力停止 かつ プロンプト無し（待機/完了）
}

/// Claude Code を PTY でホストする端末ビュー。
///
/// 設計上の安全装置（料金事故をゼロにする）:
///  - 子プロセスの環境から `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` を必ず除去する。
///    API 課金経路が存在しないため、Max 枠の上限に達しても「待つ」だけで課金は発生しない。
///  - headless（`claude -p` / Agent SDK）の起動口は一切設けない。
///
/// さらに、上限到達（公式の残量 100% か、画面末尾の上限表示）を検知したらセッションを強制終了する。
final class ClaudeTerminalView: LocalProcessTerminalView {

    /// 上限到達を検知したときに呼ばれる（メインスレッド）。
    var onLimitReached: (() -> Void)?

    /// 作業ステータスが変化したときに呼ばれる（メインスレッド）。
    var onStatusChanged: ((ClaudeStatus) -> Void)?

    /// 画面に出ている権限プロンプトが変わったときに呼ばれる（メインスレッド）。
    var onPermissionPromptChanged: ((PermissionPrompt?) -> Void)?

    /// 入力欄への送信を止める状態が変わったときに呼ばれる（メインスレッド）。
    var onInputBlockChanged: ((InputBlock?) -> Void)?

    /// 画面に出ている選択メニューの中身が変わったときに呼ばれる（メインスレッド）。
    var onMenuPromptChanged: ((MenuPrompt?) -> Void)?

    /// 中身を読み取れない選択メニューの写しが変わったときに呼ばれる（メインスレッド）。
    var onUnreadableMenuChanged: ((UnreadableMenu?) -> Void)?

    private(set) var permissionPrompt: PermissionPrompt?
    private(set) var inputBlock: InputBlock?
    private(set) var menuPrompt: MenuPrompt?
    private(set) var unreadableMenu: UnreadableMenu?
    /// 選択肢へ ❯ を動かしている最中。重ねて動かすと互いのキーで行き先がずれる。
    private(set) var isNavigatingMenu = false
    /// 未反映の矢印を残して移動をやめた印。外れるまで次の移動を始めない。
    private var pendingArrowHold: PendingArrowHold?
    /// 最後に画面の写しを残したメニュー（同じものを何度も書かない）。
    private var lastLoggedMenu: Int?

    private var limitHandled = false
    private var limitCheckPending = false

    // MARK: - ステータス検知（ハイブリッド: 活動量 + プロンプト文言）
    private var statusTimer: Timer?
    private var lastDataTime = Date()
    private(set) var currentStatus: ClaudeStatus = .idle

    /// 「最後の出力からこの秒数以内」なら出力が流れている＝作業中とみなす（活動量ベース）。
    private static let busyThreshold: TimeInterval = 1.0

    /// 実行中インジケータ。これが現在画面に出ている間は、出力が一時的に止まっても作業中とみなす。
    /// 長い bash 実行やネット待ちで出力が途切れても「完了」へ誤遷移しないための補助シグナル。
    /// ⚠️ Claude Code の TUI 文言に合わせて要・実機検証。
    private static let busyMarkers: [String] = [
        "esc to interrupt"
    ]

    /// 指定プロジェクトのディレクトリで `claude` を起動する。
    /// ログインシェル経由で PATH（~/.local/bin など）を継承しつつ、API キーは二重に遮断する。
    /// `resumeSessionId` があれば対話起動のまま `claude --resume=<id>` で会話を再開する。不正な id なら起動せず false。
    @discardableResult
    func launchClaude(in directory: String, resumeSessionId: String? = nil) -> Bool {
        var command = "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; exec claude"
        if let resumeSessionId {
            // シェルのコマンド行に埋め込むので UUID の形のものだけを `--resume=<id>` で渡す。
            guard let argument = SessionHandover.resumeArgument(resumeSessionId) else { return false }
            command += " \(argument)"
        }
        let env = Self.buildSafeEnvironment()
        startProcess(
            executable: "/bin/zsh",
            // -l ログインシェルで PATH を取得、-i 対話、-c コマンド。
            // 渡す環境からは既に API キーを抜いてあるが、念のためシェル側でも unset してから exec。
            args: ["-lic", command],
            environment: env,
            execName: nil,
            currentDirectory: directory
        )
        startStatusMonitoring()
        LimitWatch.shared.register(self)
        return true
    }

    /// 起動した claude の pid。`exec claude` で zsh を置き換えるので PTY の子 pid がそのまま claude になる。
    var claudePid: pid_t? {
        guard let pid = process?.shellPid, pid > 0 else { return nil }
        return pid
    }

    deinit { statusTimer?.invalidate() }

    // MARK: - ステータス監視

    private func startStatusMonitoring() {
        guard statusTimer == nil else { return }
        lastDataTime = Date()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.evaluateStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    /// ステータス監視を停止する（セッション終了・上限到達・ペインクローズ時）。
    func stopStatusMonitoring() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    /// 現在のステータスを判定し、変化時のみ通知する。
    /// 判定は端末の「現在画面の下数行」を直接読む（履歴が累積する scanBuffer は使わない）ため、
    /// プロンプト応答後に古い文言が残って誤判定する問題が起きない。
    /// dataReceived も Timer も SwiftTerm 既定キュー（main）上で動くので端末バッファ参照は安全。
    func evaluateStatus() {
        let screen = screenLines()
        let tail = Self.tailText(screen, lines: 8)
        let quiet = Date().timeIntervalSince(lastDataTime)
        // 権限プロンプト・選択メニュー表示中も点滅表示で出力が流れ続けるので、活動量より先に見る。
        let prompt = PermissionPrompt.parse(screen: screen)
        // InputBlock.detect と同じ判定を、読み取り済みの権限プロンプトを使い回して行う。
        let block: InputBlock? = prompt != nil ? .permission : (ChoiceMenu.isShowing(screen: screen) ? .menu : nil)
        let newStatus: ClaudeStatus
        if block != nil {
            newStatus = .waitingInput
        } else if quiet < Self.busyThreshold || Self.busyMarkers.contains(where: { tail.contains($0) }) {
            newStatus = .working
        } else if InputBlock.looksWaiting(tail: tail) {
            // 文言だけの判定は返答本文と取り違えうるので、バッジにだけ使い送信は止めない。
            newStatus = .waitingInput
        } else {
            newStatus = .idle
        }
        if prompt != permissionPrompt {
            permissionPrompt = prompt
            onPermissionPromptChanged?(prompt)
        }
        if block != inputBlock {
            inputBlock = block
            onInputBlockChanged?(block)
        }
        let menu = block == .menu ? ChoiceMenu.parseShowing(screen: screen, highlight: highlightReader()) : nil
        releasePendingArrowHoldIfDone(cursor: menu?.cursor)
        if menu != menuPrompt {
            menuPrompt = menu
            onMenuPromptChanged?(menu)
        }
        let unreadable = block == .menu && menu == nil ? ChoiceMenu.unreadable(screen: screen) : nil
        if unreadable != unreadableMenu {
            unreadableMenu = unreadable
            onUnreadableMenuChanged?(unreadable)
        }
        logMenuScreen(menu: menu, unreadable: unreadable, screen: screen)
        guard newStatus != currentStatus else { return }
        currentStatus = newStatus
        onStatusChanged?(newStatus)   // Timer は main runloop なのでメインスレッド
    }

    /// アプリが今いじっている実画面の全行（上から順・右端の空白は除く）。右に縦線で区切った別の欄（差分パネル等）は除く。
    /// ターミナル表示で上にスクロールしていても、表示位置（yDisp）ではなく末尾の `rows` 行を読む。
    /// SwiftTerm は `lines.count == yBase + rows` を保つが yBase を公開していないので、行数を探って求める。
    func screenLines() -> [String] {
        let term = getTerminal()
        let rows = term.rows
        guard rows > 0 else { return [] }
        let top = term.buffer.totalLinesTrimmed
        let count = TerminalScreen.lineCount(rows: rows) { term.getScrollInvariantLine(row: top + $0) != nil }
        let base = max(0, count - rows)
        return TerminalScreen.mainPane((base..<count).compactMap { term.getScrollInvariantLine(row: top + $0).map(Self.text(of:)) })
    }

    /// 実画面の行（`screenLines` の添字）の各文字に背景色（か反転）が付いているか。タブ行の今のタブを読むのに使う。
    /// 文字の並びは `screenLines` と同じく全角の後半セルを飛ばして数える。
    private func highlightReader() -> (Int) -> [Bool]? {
        let term = getTerminal()
        let rows = term.rows
        let top = term.buffer.totalLinesTrimmed
        let count = TerminalScreen.lineCount(rows: rows) { term.getScrollInvariantLine(row: top + $0) != nil }
        let base = max(0, count - rows)
        return { row in
            guard rows > 0, let line = term.getScrollInvariantLine(row: top + base + row) else { return nil }
            var flags: [Bool] = []
            var text = ""
            _ = line.translateToString(trimRight: true, skipNullCellsFollowingWide: true) { cell in
                let character = cell.getCharacter()
                let before = text.count
                text.append(character)
                // 結合文字は前の文字にまとまるので、文字数が増えた時だけ数える。
                if text.count > before {
                    let attribute = cell.attribute
                    flags.append(Self.isColored(attribute.bg) || attribute.style.contains(.inverse))
                }
                return character
            }
            return flags
        }
    }

    private static func isColored(_ color: Attribute.Color) -> Bool {
        switch color {
        case .ansi256, .trueColor: return true
        case .defaultColor, .defaultInvertedColor: return false
        }
    }

    /// 選択肢カードを出した・読めなかった画面の写しを、中身が替わった時だけ残す。
    private func logMenuScreen(menu: MenuPrompt?, unreadable: UnreadableMenu?, screen: [String]) {
        let key: Int?
        if let menu {
            key = menu.identity
        } else if let unreadable {
            key = unreadable.hashValue
        } else {
            key = nil
        }
        guard key != lastLoggedMenu else { return }
        lastLoggedMenu = key
        guard key != nil else { return }
        MenuScreenLog.record(kind: menu != nil ? .menu : .unreadable, columns: getTerminal().cols, screen: screen)
    }

    /// 送信を止めるべき状態か。タイマーを待たず今の画面で判定する。
    func currentInputBlock() -> InputBlock? {
        InputBlock.detect(screen: screenLines())
    }

    /// 送信を途中で取りやめ、端末の入力欄に本文や画像を残したかもしれない。
    private(set) var mayHaveLeftover = false

    /// 送信の途中（画像の取り込み待ち〜Enter）。終わるまで次の送信を受けない。
    private(set) var isSending = false {
        didSet { if isSending != oldValue { onSendingChanged?(isSending) } }
    }
    var onSendingChanged: ((Bool) -> Void)?

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
    }

    /// チャット欄の本文を入力欄に貼り付けてから Enter で送る。作業中でも Claude Code 側でキューに積まれる。
    /// 貼り付けの前に必ず判定するので、止める時は入力欄に何も入れない。
    /// `.started` を返した時だけ、Enter を送った・途中でやめた・端末が無くなったのいずれかを `completion` に 1 回返す。
    func sendMessage(_ text: String, attachments: [Attachment] = [], completion: @escaping (SendCompletion) -> Void) -> SendResult {
        guard !isSending else { return .busy }
        let screen = screenLines()
        if let block = InputBlock.detect(screen: screen) { return .blocked(block) }
        if mayHaveLeftover {
            // 入力欄が読めない時は残りを確かめられないが、くっつく害は小さいので送る（印は残す）。
            if let boxText = InputBox.text(screen: screen) {
                mayHaveLeftover = false
                // 警告は 1 回だけ。未知の薄字表示を本文と誤認しても、もう一度送れば送れるようにする。
                guard boxText.isEmpty else { return .leftover }
            }
        }
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
            if let body { pasteAndSubmit(body, finish: finish) }
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
                self.mayHaveLeftover = true
                return finish(.abortedBeforeBody(block))
            }
            // 取り込みを確かめられなかった時は Enter が捨てられているかもしれないので、次の送信で入力欄の残りを確かめる。
            if !ingested { self.mayHaveLeftover = true }
            if let body {
                self.pasteAndSubmit(body, finish: finish)
            } else {
                self.send(txt: PTYInput.submitKey)
                finish(.submitted)
            }
        }
        return .started(pastedImages: message.imagePaths, body: message.body)
    }

    private func pasteAndSubmit(_ body: String, finish: @escaping (SendCompletion) -> Void) {
        send(txt: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + PTYInput.submitDelay) { [weak self] in
            guard let self else { return finish(.ended) }
            if let block = self.currentInputBlock() {
                self.mayHaveLeftover = true
                return finish(.abortedAfterBody(block))
            }
            self.send(txt: PTYInput.submitKey)
            finish(.submitted)
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

    private func releasePendingArrowHoldIfDone(cursor: Int?) {
        guard let hold = pendingArrowHold,
              hold.isReleased(now: Date(), lastOutput: lastDataTime, currentCursor: cursor) else { return }
        pendingArrowHold = nil
    }

    /// 今の画面の選択メニュー（権限プロンプトが出ていれば nil）。
    private func currentMenu() -> MenuPrompt? {
        let screen = screenLines()
        guard InputBlock.detect(screen: screen) == .menu else { return nil }
        return ChoiceMenu.parseShowing(screen: screen, highlight: highlightReader())
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
        guard PermissionPrompt.parse(screen: screen) == nil, let current = ChoiceMenu.unreadable(screen: screen) else {
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

    /// 画面の下から `lines` 行を、小文字化して連結した文字列で返す。
    private static func tailText(_ screen: [String], lines: Int) -> String {
        screen.suffix(lines).joined(separator: "\n").lowercased()
    }

    /// 1 行の文字列。TUI は空白を書かずにカーソル移動で桁を飛ばすので、未記入のセル（NUL）を空白に戻す（全角の後半セルは除く）。
    private static func text(of line: BufferLine) -> String {
        line.translateToString(trimRight: true, skipNullCellsFollowingWide: true).replacingOccurrences(of: "\u{0}", with: " ")
    }

    /// 親プロセスの環境を引き継ぎつつ、課金経路となる API キーを除去した環境を作る。
    private static func buildSafeEnvironment() -> [String] {
        var dict = ProcessInfo.processInfo.environment
        dict.removeValue(forKey: "ANTHROPIC_API_KEY")
        dict.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        // Claude Code の中から起動された時の子セッション印（transcript 保存オフ・SDK 扱い等）を持ち込まないため。
        for key in dict.keys where key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_SDK")
            || ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "AI_AGENT"].contains(key) {
            dict.removeValue(forKey: key)
        }
        dict["TERM"] = "xterm-256color"
        dict["COLORTERM"] = "truecolor"
        return dict.map { "\($0.key)=\($0.value)" }
    }

    // MARK: - 出力傍受

    /// PTY からの受信バイトを傍受。描画は super に委ね、こちらは上限文言の検査だけ行う。
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        lastDataTime = Date()   // 活動量ベースの作業中判定に使う
        guard !limitHandled else { return }
        // UTF-8 として lossy デコード（途中で切れても落ちない）
        let chunk = String(decoding: slice, as: UTF8.self)
        scan(chunk)
    }

    /// 生の出力は TUI がカーソル移動で語を並べるので照合できない。描画後の実画面の末尾を間引いて見る。
    private func scan(_ chunk: String) {
        guard !limitCheckPending else { return }
        limitCheckPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.limitCheckPending = false
            if LimitGuard.screenLimitLine(self.limitScreenLines()) != nil { self.reachLimit() }
        }
    }

    /// 上限到達として 1 回だけ終了を流す（画面の表示からも、公式の残量からも呼ばれる）。
    func reachLimit() {
        guard !limitHandled, process?.running == true else { return }
        limitHandled = true
        let pid = process.shellPid
        // 起動直後に呼ばれても受け手が pid を取り終えてから止めるよう、次の周回に回す。
        DispatchQueue.main.async { [weak self] in self?.onLimitReached?() }
        // 対話 zsh は SIGTERM を無視するので、claude に exec する前に止めると生き残る。残っていれば強制終了する。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if Self.isLiveChild(pid) { kill(pid, SIGKILL) }
        }
    }

    /// 自分の子で、まだ終わっていない（ゾンビでない）プロセスか。pid の再利用で他人を殺さないため親を確かめる。
    private static func isLiveChild(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_ppid == UInt32(getpid()) && info.pbi_status != UInt32(SZOMB)
    }

    /// 実画面の全行。表示位置（yDisp）ではなくバッファ末尾の `rows` 行を読む。空白を書かずに飛ばしたセル（NUL）は空白に戻す。
    private func limitScreenLines() -> [String] {
        let term = getTerminal()
        let rows = term.rows
        guard rows > 0 else { return [] }
        let top = term.buffer.totalLinesTrimmed
        let count = LimitGuard.bufferLineCount(rows: rows) { term.getScrollInvariantLine(row: top + $0) != nil }
        return (max(0, count - rows)..<count).compactMap { row in
            term.getScrollInvariantLine(row: top + row).map {
                $0.translateToString(trimRight: true, skipNullCellsFollowingWide: true).replacingOccurrences(of: "\u{0}", with: " ")
            }
        }
    }
}
