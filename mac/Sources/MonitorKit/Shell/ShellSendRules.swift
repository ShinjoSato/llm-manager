import Foundation

/// プロンプトに打ちかけの入力が残っているか（端末へ送ったキーから追う）。Enter・Ctrl-C で行が終わり、それ以外のキーは何かを残したとみなす。
public enum ShellLineInput {
    /// フォーカスの出入りの知らせ（行には何も足さない）。
    static let neutralSequences: Set<[UInt8]> = [[0x1B, 0x5B, 0x49], [0x1B, 0x5B, 0x4F]]

    public static func pending(after bytes: [UInt8], previous: Bool) -> Bool {
        guard let last = bytes.last, !neutralSequences.contains(bytes) else { return previous }
        switch last {
        case 0x0D, 0x0A, 0x03: return false
        // Ctrl-D は空の行では終了、文字があれば 1 文字消すだけ。
        case 0x04: return previous
        default: return true
        }
    }
}

/// 終わったシェルの waitpid の status を文言にする。
public enum ShellExitStatus {
    public static func message(rawStatus: Int32?) -> String {
        guard let status = rawStatus else { return "シェルは終了しました" }
        let low = status & 0x7F
        if low == 0 { return "シェルは終了しました（終了コード \((status >> 8) & 0xFF)）" }
        if low != 0x7F { return "シェルは終了しました（シグナル \(low) で終了）" }
        return "シェルは終了しました"
    }
}

/// 実行コマンドを送る前に確かめる理由。
public enum ShellSendReason: Equatable, Sendable {
    /// 初めて送る・外で本文が変わった（全文を見せて確かめる）。
    case notApproved
    /// 前面で別のプロセスが動いている・判定できない。
    case busy
    /// プロンプトに打ちかけの入力がある（つながって実行される）。
    case pendingInput
    /// 前の送信が終わっていない・直前に送った（続けて押した）。
    case queued

    public var message: String {
        switch self {
        case .notApproved: return "このコマンドを送るのは初めてか、前に確かめた後で本文が変わっています。"
        case .busy: return "シェルのプロンプトに戻っていないため、本文は動いているプログラムへの入力として渡ります。"
        case .pendingInput: return "プロンプトに打ちかけの入力があるため、本文がその後ろにつながって実行されます。"
        case .queued: return "直前に送ったコマンドがまだ処理中かもしれません。"
        }
    }
}

public enum ShellSendCheck {
    /// 続けて押したとみなす間隔。
    public static let repeatWindow: TimeInterval = 2

    /// 確かめる理由（無ければそのまま送る）。シェルが動いていなければ新しく起動するので、本文の承認だけを見る。
    public static func reasons(approved: Bool, running: Bool, foreground: ShellForeground, pendingInput: Bool,
                               queued: Bool, lastSentAt: Date?, now: Date) -> [ShellSendReason] {
        var result: [ShellSendReason] = approved ? [] : [.notApproved]
        guard running else { return result }
        if foreground.needsConfirmation { result.append(.busy) }
        if pendingInput { result.append(.pendingInput) }
        if queued || lastSentAt.map({ now.timeIntervalSince($0) < repeatWindow }) == true { result.append(.queued) }
        return result
    }

    /// 送る直前の見直し（確かめずに積んだものだけ）。プロンプトで、打ちかけが無い時だけ送る。
    public static func stillSafe(foreground: ShellForeground, pendingInput: Bool) -> Bool {
        foreground == .prompt && !pendingInput
    }
}
