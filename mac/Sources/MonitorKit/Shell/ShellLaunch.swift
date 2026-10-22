import Foundation

/// ルームのターミナルで起動する利用者のログインシェル（実行ファイル・引数・環境）。
public struct ShellLaunch: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]

    public static let fallbackShell = "/bin/zsh"

    /// `SHELL` が実行できる絶対パスならそれ、無ければ /bin/zsh。zsh には `wrapperDirectory` の起動ファイルを挟んで設定の後で API キーを外す。
    public static func make(base: [String: String], wrapperDirectory: String?,
                            isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> ShellLaunch {
        let shell = base["SHELL"].flatMap { $0.hasPrefix("/") && isExecutable($0) ? $0 : nil } ?? fallbackShell
        var env = ChildEnvironment.sanitized(base)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["SHELL"] = shell
        if isZsh(shell), let wrapperDirectory {
            // 利用者の ZDOTDIR（無ければ HOME）を覚えておき、挟んだ起動ファイルから順に読ませる。
            env[ZshWrapper.userDirectoryKey] = base["ZDOTDIR"] ?? base["HOME"] ?? NSHomeDirectory()
            if base["ZDOTDIR"] != nil { env[ZshWrapper.keepDirectoryKey] = "1" }
            env["ZDOTDIR"] = wrapperDirectory
        }
        return ShellLaunch(executable: shell, arguments: ["-l", "-i"], environment: env)
    }

    public static func isZsh(_ shell: String) -> Bool {
        (shell as NSString).lastPathComponent == "zsh"
    }

    /// SwiftTerm の `startProcess` に渡す形。
    public var environmentList: [String] {
        environment.map { "\($0.key)=\($0.value)" }.sorted()
    }
}

/// zsh の起動ファイルを挟む（利用者の .zshenv / .zprofile / .zshrc / .zlogin をそのまま読み、最後に API キーを外す）。
public enum ZshWrapper {
    static let userDirectoryKey = "CLAUDE_DECK_USER_ZDOTDIR"
    static let keepDirectoryKey = "CLAUDE_DECK_KEEP_ZDOTDIR"
    static let wrapperDirectoryKey = "CLAUDE_DECK_WRAPPER_ZDOTDIR"

    public static let fileNames = [".zshenv", ".zprofile", ".zshrc", ".zlogin"]

    /// 既定の置き場（`~/Library/Caches/claude-deck/shell-zsh`）。
    public static var defaultDirectory: URL {
        DeckPaths.caches.appendingPathComponent("shell-zsh", isDirectory: true)
    }

    /// 起動ファイルを書く（中身が同じなら書き直さない）。書けなければ nil（挟まずに起動する）。
    public static func prepare(at directory: URL = defaultDirectory) -> String? {
        for name in fileNames {
            let url = directory.appendingPathComponent(name)
            let data = Data(contents(for: name).utf8)
            if (try? Data(contentsOf: url)) == data { continue }
            do { try SecureFile.write(data, to: url) } catch { return nil }
        }
        return directory.path
    }

    /// 各ファイルの中身。利用者のファイルは利用者の ZDOTDIR を立てた状態で読み、次の段のためにこちらへ戻す。
    static func contents(for name: String) -> String {
        let user = userDirectoryKey, wrapper = wrapperDirectoryKey
        var lines = [
            "# claude-deck が生成（利用者の \(name) を読み、最後に API キーを外す）",
            "\(wrapper)=\"$ZDOTDIR\"",
            "ZDOTDIR=\"$\(user)\"",
            "[[ -f \"$ZDOTDIR/\(name)\" ]] && builtin source \"$ZDOTDIR/\(name)\"",
            "\(user)=\"$ZDOTDIR\"",
            "ZDOTDIR=\"$\(wrapper)\"",
        ]
        if name == ".zshrc" {
            // /etc/zshrc はこちらの ZDOTDIR を見て履歴の場所を決めるので、利用者の場所へ戻す。
            lines.append("[[ $HISTFILE == \"$\(wrapper)\"/* ]] && HISTFILE=\"$\(user)/${HISTFILE:t}\"")
        }
        if name == ".zlogin" {
            lines += [
                "if [[ -n $\(keepDirectoryKey) || \"$\(user)\" != \"$HOME\" ]]; then ZDOTDIR=\"$\(user)\"; else unset ZDOTDIR; fi",
                "unset \(user) \(wrapper) \(keepDirectoryKey)",
                // 設定が API キーを戻しても、このシェルから起動する claude に渡さない。
                ChildEnvironment.unsetCommand,
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
