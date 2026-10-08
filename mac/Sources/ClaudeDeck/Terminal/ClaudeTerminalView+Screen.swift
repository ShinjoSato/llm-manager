import AppKit
import SwiftTerm
import MonitorKit

extension ClaudeTerminalView {
    /// 「最後の出力からこの秒数以内」なら出力が流れている＝作業中とみなす（活動量ベース）。
    private static let busyThreshold: TimeInterval = 1.0

    /// 画面に出ている間は出力が止まっても作業中とみなす（長いコマンドやネット待ちで「完了」に見せないため）。
    private static let busyMarkers: [String] = [
        "esc to interrupt"
    ]

    // MARK: - ステータス監視

    func startStatusMonitoring() {
        guard statusTimer == nil else { return }
        lastDataTime = Date()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.evaluateStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    /// 画面の監視を止める（終了・上限到達・ルームを閉じた時）。
    func stopStatusMonitoring() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    /// 実画面から状態を読み、変わった時だけ通知する（履歴ではなく今の画面を読むので、答え終えた確認を引きずらない）。
    /// dataReceived も Timer も main で動くので、端末バッファをそのまま読める。
    func evaluateStatus() {
        let screen = screenLines()
        let tail = Self.tailText(screen, lines: 8)
        let quiet = Date().timeIntervalSince(lastDataTime)
        // 権限プロンプト・選択メニュー表示中も点滅表示で出力が流れ続けるので、活動量より先に見る。
        let prompt = PermissionPrompt.parse(screen: screen)
        let waiting = sessionWaiting()
        // InputBlock.detect と同じ判定を、読み取り済みの権限プロンプトを使い回して行う。
        let showing = prompt == nil && ChoiceMenu.isShowing(screen: screen)
        let block: InputBlock? = prompt != nil ? .permission : (showing || waiting?.blocksSend(screen: screen, screenChangedAt: lastDataTime) == true ? .menu : nil)
        let status: ClaudeStatus
        if block != nil {
            status = .waitingInput
        } else if quiet < Self.busyThreshold || Self.busyMarkers.contains(where: { tail.contains($0) }) {
            status = .working
        } else if InputBlock.looksWaiting(tail: tail) {
            // 文言だけの判定は返答本文と取り違えうるので、バッジにだけ使い送信は止めない。
            status = .waitingInput
        } else {
            status = .idle
        }
        let menu = showing ? ChoiceMenu.parseShowing(screen: screen, highlight: highlightReader()) : nil
        releasePendingArrowHoldIfDone(cursor: menu?.cursor)
        let unreadable = block == .menu && menu == nil ? ChoiceMenu.unreadable(screen: screen, waiting: waiting, screenChangedAt: lastDataTime) : nil
        logMenuScreen(menu: menu, unreadable: unreadable, screen: screen)
        let next = ScreenState(status: status, permissionPrompt: prompt, inputBlock: block, menuPrompt: menu, unreadableMenu: unreadable)
        guard next != screenState else { return }
        screenState = next
        onScreenStateChanged?(next)   // Timer は main runloop なのでメインスレッド
    }

    /// 実画面（バッファ末尾の `rows` 行）。ターミナル表示のスクロール位置（yDisp）に依らない。
    /// SwiftTerm は `lines.count == yBase + rows` を保つが yBase を公開していないので、行数を探って求める。
    private func rawScreenLines() -> [BufferLine] {
        let term = getTerminal()
        let rows = term.rows
        guard rows > 0 else { return [] }
        let top = term.buffer.totalLinesTrimmed
        let count = TerminalScreen.lineCount(rows: rows) { term.getScrollInvariantLine(row: top + $0) != nil }
        return (max(0, count - rows)..<count).compactMap { term.getScrollInvariantLine(row: top + $0) }
    }

    /// 実画面の全行（右端の空白は除く）。右に縦線で区切った別の欄（差分パネル等）は除く。
    func screenLines() -> [String] {
        TerminalScreen.mainPane(rawScreenLines().map(Self.text(of:)))
    }

    /// 実画面の行の各文字に背景色（か反転）が付いているか（タブ行の今のタブを読む。全角の後半セルは `screenLines` と同じく飛ばす）。
    private func highlightReader() -> (Int) -> [Bool]? {
        let lines = rawScreenLines()
        return { row in
            guard lines.indices.contains(row) else { return nil }
            let line = lines[row]
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

    /// 送信を止めるべき状態か。タイマーを待たず今の画面とセッションファイルで判定する。
    func currentInputBlock() -> InputBlock? {
        InputBlock.detect(screen: screenLines(), waiting: sessionWaiting(fresh: true), screenChangedAt: lastDataTime)
    }

    /// セッションファイルの返事待ちの状態。`fresh` でなければ 1 秒以内に読んだ値を使い回す。
    func sessionWaiting(fresh: Bool = false) -> SessionWaiting? {
        guard let pid = claudePid else { return nil }
        let now = Date()
        if !fresh, let cache = sessionWaitingCache, now.timeIntervalSince(cache.at) < 1 { return cache.value }
        let value = ClaudeSessionRegistry().record(forPid: pid)?.waiting
        sessionWaitingCache = (now, value)
        return value
    }

    /// 今の画面の選択メニュー（権限プロンプトが出ていれば nil）。
    func currentMenu() -> MenuPrompt? {
        let screen = screenLines()
        guard InputBlock.detect(screen: screen) == .menu else { return nil }
        return ChoiceMenu.parseShowing(screen: screen, highlight: highlightReader())
    }

    /// 画面の下から `lines` 行を、小文字化して連結した文字列で返す。
    private static func tailText(_ screen: [String], lines: Int) -> String {
        screen.suffix(lines).joined(separator: "\n").lowercased()
    }

    /// 1 行の文字列。TUI は空白を書かずにカーソル移動で桁を飛ばすので、未記入のセル（NUL）を空白に戻す（全角の後半セルは除く）。
    private static func text(of line: BufferLine) -> String {
        line.translateToString(trimRight: true, skipNullCellsFollowingWide: true).replacingOccurrences(of: "\u{0}", with: " ")
    }

    /// 上限の検査は右の別の欄も含めて全幅で読む（`screenLines` と違い欄で切らない）。
    func limitScreenLines() -> [String] {
        rawScreenLines().map(Self.text(of:))
    }
}
