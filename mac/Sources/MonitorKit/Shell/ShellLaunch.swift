import Foundation

/// ルームのターミナルで起動する利用者のログインシェル（実行ファイル・引数・環境）。
public struct ShellLaunch: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    /// コマンドを実行するたびに API キーを外す守り（zsh の起動ファイルを挟めた時だけ）が効くか。
    public var scrubsEachCommand: Bool

    public static let fallbackShell = "/bin/zsh"

    /// 親の端末アプリ・多重化の印（このアプリの端末とは違うものを名乗らせない）。
    static let terminalKeys: Set<String> = [
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "TMUX", "TMUX_PANE", "STY", "WINDOWID", "WT_SESSION",
        "LC_TERMINAL", "LC_TERMINAL_VERSION", "COLORFGBG", "INSIDE_EMACS", "PWD", "OLDPWD", "SHLVL", "_",
    ]
    static let terminalPrefixes = ["ITERM_", "VSCODE_", "KITTY_", "WEZTERM_", "GHOSTTY_", "ALACRITTY_"]

    /// `SHELL` が実行できる絶対パスならそれ、無ければ /bin/zsh。zsh には `wrapperDirectory` の起動ファイルを挟み、設定の後とコマンドの前に API キーを外す。
    public static func make(base: [String: String], wrapperDirectory: String?,
                            isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> ShellLaunch {
        let shell = base["SHELL"].flatMap { $0.hasPrefix("/") && isExecutable($0) ? $0 : nil } ?? fallbackShell
        var env = ChildEnvironment.sanitized(base).filter { key, _ in
            !terminalKeys.contains(key) && !terminalPrefixes.contains { key.hasPrefix($0) } && !ZshWrapper.markerKeys.contains(key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["SHELL"] = shell
        // アプリ自身がこのシェルから起動された時の ZDOTDIR は挟んだ場所なので、利用者のものとみなさない。
        let userZdotdir = base["ZDOTDIR"].flatMap { value -> String? in
            guard !value.isEmpty else { return nil }
            guard let wrapperDirectory else { return value }
            return samePath(value, wrapperDirectory) ? nil : value
        }
        var scrubs = false
        if isZsh(shell), let wrapperDirectory {
            env[ZshWrapper.userDirectoryKey] = userZdotdir ?? base["HOME"] ?? NSHomeDirectory()
            if userZdotdir != nil { env[ZshWrapper.keepDirectoryKey] = "1" }
            env["ZDOTDIR"] = wrapperDirectory
            scrubs = true
        } else {
            env["ZDOTDIR"] = userZdotdir
        }
        return ShellLaunch(executable: shell, arguments: ["-l", "-i"], environment: env, scrubsEachCommand: scrubs)
    }

    public static func isZsh(_ shell: String) -> Bool {
        (shell as NSString).lastPathComponent == "zsh"
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    /// SwiftTerm の `startProcess` に渡す形。
    public var environmentList: [String] {
        environment.map { "\($0.key)=\($0.value)" }.sorted()
    }
}

/// zsh の起動ファイルを挟む（利用者の .zshenv / .zprofile / .zshrc / .zlogin をそのまま読み、各段の後とコマンドの実行前に API キーを外す）。
public enum ZshWrapper {
    static let userDirectoryKey = "CLAUDE_DECK_USER_ZDOTDIR"
    static let keepDirectoryKey = "CLAUDE_DECK_KEEP_ZDOTDIR"
    static let wrapperDirectoryKey = "CLAUDE_DECK_WRAPPER_ZDOTDIR"
    static let markerKeys: Set<String> = [userDirectoryKey, keepDirectoryKey, wrapperDirectoryKey]

    public static let fileNames = [".zshenv", ".zprofile", ".zshrc", ".zlogin"]
    /// preexec に足す関数の名前。
    public static let scrubFunction = "_claude_deck_scrub_keys"

    /// 既定の置き場（`~/Library/Caches/claude-deck/shell-zsh`）。
    public static var defaultDirectory: URL {
        DeckPaths.caches.appendingPathComponent("shell-zsh", isDirectory: true)
    }

    /// 起動ファイルを書く（中身が同じなら書き直さない）。書けなければ nil（挟まずに起動し、画面で守りが効いていないと知らせる）。
    public static func prepare(at directory: URL = defaultDirectory) -> String? {
        for name in fileNames {
            let url = directory.appendingPathComponent(name)
            let data = Data(contents(for: name).utf8)
            if (try? Data(contentsOf: url)) == data { continue }
            do { try SecureFile.write(data, to: url) } catch { return nil }
        }
        return directory.path
    }

    /// 各ファイルの中身。利用者のファイルは利用者の ZDOTDIR を立てた状態で読み、外してから次の段のためにこちらへ戻す。
    static func contents(for name: String) -> String {
        let user = userDirectoryKey, wrapper = wrapperDirectoryKey
        var lines = [
            "# claude-deck が生成（利用者の \(name) を読み、API キーと子セッションの印を外す）",
            "\(wrapper)=\"$ZDOTDIR\"",
            "ZDOTDIR=\"$\(user)\"",
            "[[ -f \"$ZDOTDIR/\(name)\" ]] && builtin source \"$ZDOTDIR/\(name)\"",
            // 利用者の設定が ZDOTDIR を外した時は HOME に戻す（こちらを読み続けない）。
            "\(user)=\"${ZDOTDIR:-$HOME}\"",
            "ZDOTDIR=\"$\(wrapper)\"",
            ChildEnvironment.zshScrubCommand,
        ]
        if name == ".zshrc" {
            // /etc/zshrc はこちらの ZDOTDIR を見て履歴の場所を決めるので、利用者の場所へ戻す。
            lines.append("[[ $HISTFILE == \"$\(wrapper)\"/* ]] && HISTFILE=\"$\(user)/${HISTFILE:t}\"")
        }
        if name == ".zlogin" {
            lines += [
                "if [[ -n $\(keepDirectoryKey) || \"$\(user)\" != \"$HOME\" ]]; then ZDOTDIR=\"$\(user)\"; else unset ZDOTDIR; fi",
                "unset \(user) \(wrapper) \(keepDirectoryKey)",
                // direnv 等がプロンプトや cd で戻しても、コマンドの実行の直前と cd の直後に外す（利用者の設定の後に足すので最後に回る）。
                "\(scrubFunction)() { \(ChildEnvironment.zshScrubCommand) }",
                "if autoload -Uz add-zsh-hook 2>/dev/null; then add-zsh-hook preexec \(scrubFunction); add-zsh-hook chpwd \(scrubFunction);"
                    + " else preexec_functions+=(\(scrubFunction)); chpwd_functions+=(\(scrubFunction)); fi",
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
