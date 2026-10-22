import Foundation

/// ルームのターミナルへ実行コマンドを送る時の本文。
public enum ShellInput {
    /// 貼り付けと Enter を同時に送ると、遅いシェルで Enter が貼り付けに飲まれることがあるので少し空ける。
    public static let submitDelay: TimeInterval = 0.1
    /// 起動直後のシェルが入力を受けられるようになるのを待つ上限。
    public static let readyTimeout: TimeInterval = 5
    /// 出力が止まってからプロンプトが出たとみなすまで（bracketed paste を宣言しないシェル向け）。
    public static let quietInterval: TimeInterval = 0.5

    /// 入力欄に入れる本文（送るものが無ければ nil）。bracketed paste なら複数行を 1 回の貼り付けとして入れ、Enter は別に送る。
    /// 貼り付けモードでなければ行ごとに改行（CR）で区切って打ち込む（タブは補完にならないよう空白にする）。
    public static func body(_ text: String, bracketedPaste: Bool) -> String? {
        var body = PTYInput.sanitize(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        if bracketedPaste { return PTYInput.pasteStart + body + PTYInput.pasteEnd }
        return body.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: "\r")
    }

    /// 起動直後のシェルに送ってよいか。貼り付けモードを宣言したか、最初の出力の後しばらく静かになったか、待ちの上限を過ぎたら送る。
    public static func isReady(bracketedPaste: Bool, startedAt: Date, lastOutputAt: Date?, now: Date) -> Bool {
        if bracketedPaste { return true }
        if now.timeIntervalSince(startedAt) >= readyTimeout { return true }
        guard let lastOutputAt else { return false }
        return now.timeIntervalSince(lastOutputAt) >= quietInterval
    }
}

/// PTY の前面のプロセスグループからシェルの様子を見る。
public enum ShellForeground: Equatable, Sendable {
    /// シェル自身が前面（プロンプトに戻っている）。
    case prompt
    /// 別のプロセスが前面で動いている。
    case busy
    /// 判定できない（PTY が閉じている等）。
    case unknown

    /// `foregroundGroup` は `tcgetpgrp(master)`、`shellGroup` はシェルのプロセスグループ（forkpty の子は自分が先頭）。
    public static func state(foregroundGroup: pid_t, shellGroup: pid_t) -> ShellForeground {
        guard foregroundGroup > 0, shellGroup > 0 else { return .unknown }
        return foregroundGroup == shellGroup ? .prompt : .busy
    }

    /// 今の PTY の前面を読む。
    public static func current(master: Int32, shellPid: pid_t) -> ShellForeground {
        guard master >= 0, shellPid > 0 else { return .unknown }
        let group = getpgid(shellPid)
        return state(foregroundGroup: tcgetpgrp(master), shellGroup: group > 0 ? group : shellPid)
    }

    /// 送る前に確認を出すか（プロンプトと分かる時だけ確かめずに送る）。
    public var needsConfirmation: Bool { self != .prompt }
}
