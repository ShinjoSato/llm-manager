import XCTest
@testable import MonitorKit

final class ShellLaunchTests: XCTestCase {
    private let secrets = [
        "ANTHROPIC_API_KEY": "sk-test", "ANTHROPIC_AUTH_TOKEN": "tok", "CLAUDECODE": "1",
        "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_SSE_PORT": "1234", "CLAUDE_AGENT_SDK_VERSION": "1", "AI_AGENT": "x",
    ]

    func testEnvironmentDropsAPIKeysAndChildSessionMarks() {
        let launch = ShellLaunch.make(base: minimalEnvironment(secrets.merging(["SHELL": "/bin/zsh"]) { a, _ in a }),
                                      wrapperDirectory: nil)
        for key in secrets.keys { XCTAssertNil(launch.environment[key], key) }
        XCTAssertEqual(launch.environment["TERM"], "xterm-256color")
        XCTAssertEqual(launch.environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertFalse(launch.environmentList.contains { $0.hasPrefix("ANTHROPIC_") || $0.hasPrefix("CLAUDE_CODE_") })
    }

    func testUsesLoginShellOrFallsBackToZsh() {
        XCTAssertEqual(ShellLaunch.make(base: ["SHELL": "/bin/bash"], wrapperDirectory: nil) { _ in true }.executable, "/bin/bash")
        XCTAssertEqual(ShellLaunch.make(base: ["SHELL": "/bin/bash"], wrapperDirectory: nil).arguments, ["-l", "-i"])
        XCTAssertEqual(ShellLaunch.make(base: [:], wrapperDirectory: nil).executable, "/bin/zsh")
        XCTAssertEqual(ShellLaunch.make(base: ["SHELL": "bash"], wrapperDirectory: nil) { _ in true }.executable, "/bin/zsh")
        XCTAssertEqual(ShellLaunch.make(base: ["SHELL": "/no/such/shell"], wrapperDirectory: nil).executable, "/bin/zsh")
    }

    func testZshGetsWrapperDirectoryAndRemembersUserDirectory() {
        let launch = ShellLaunch.make(base: ["SHELL": "/bin/zsh", "HOME": "/Users/me"], wrapperDirectory: "/tmp/w")
        XCTAssertEqual(launch.environment["ZDOTDIR"], "/tmp/w")
        XCTAssertEqual(launch.environment["CLAUDE_DECK_USER_ZDOTDIR"], "/Users/me")
        XCTAssertNil(launch.environment["CLAUDE_DECK_KEEP_ZDOTDIR"])

        let custom = ShellLaunch.make(base: ["SHELL": "/bin/zsh", "HOME": "/Users/me", "ZDOTDIR": "/Users/me/.config/zsh"],
                                      wrapperDirectory: "/tmp/w")
        XCTAssertEqual(custom.environment["CLAUDE_DECK_USER_ZDOTDIR"], "/Users/me/.config/zsh")
        XCTAssertEqual(custom.environment["CLAUDE_DECK_KEEP_ZDOTDIR"], "1")

        let bash = ShellLaunch.make(base: ["SHELL": "/bin/bash", "HOME": "/Users/me"], wrapperDirectory: "/tmp/w")
        XCTAssertNil(bash.environment["ZDOTDIR"])
    }

    func testWrapperUnsetsKeysAfterEachStageAndBeforeEachCommand() {
        let login = ZshWrapper.contents(for: ".zlogin")
        XCTAssertTrue(login.contains("add-zsh-hook preexec \(ZshWrapper.scrubFunction)"))
        XCTAssertTrue(login.contains("add-zsh-hook chpwd \(ZshWrapper.scrubFunction)"))
        for name in ZshWrapper.fileNames {
            let lines = ZshWrapper.contents(for: name).split(separator: "\n").map(String.init)
            let source = lines.firstIndex { $0.contains("builtin source \"$ZDOTDIR/\(name)\"") }
            let scrub = lines.firstIndex(of: ChildEnvironment.zshScrubCommand)
            // 利用者のファイルを読んだ直後に外す。
            XCTAssertNotNil(source, name)
            XCTAssertNotNil(scrub, name)
            if let source, let scrub { XCTAssertGreaterThan(scrub, source, name) }
        }
        XCTAssertEqual(ChildEnvironment.zshScrubCommand,
                       "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDECODE CLAUDE_PID CLAUDE_EFFORT AI_AGENT; unset -m 'CLAUDE_CODE_*' 'CLAUDE_AGENT_SDK*'")
    }

    /// ダミーのシェル（env）を同じ環境で PTY に起動し、API キーと子セッション印が子に渡らないことを確かめる。
    func testPTYChildSeesNoSecrets() async throws {
        let launch = ShellLaunch.make(base: minimalEnvironment(secrets), wrapperDirectory: nil)
        let pty = DummyPTY(executable: "/usr/bin/env", args: [], environment: launch.environmentList)
        defer { pty.kill() }
        try await waitUntil { pty.recorder.hasExited || pty.recorder.text.contains("TERM=xterm-256color") }
        try await Task.sleep(for: .milliseconds(200))
        let output = pty.recorder.text
        XCTAssertTrue(output.contains("TERM=xterm-256color"), output)
        for key in secrets.keys { XCTAssertFalse(output.contains("\(key)="), "\(key) が渡っている") }
    }

    /// 本物の zsh（ログイン・対話）で、利用者の設定が API キーを export しても、挟んだ起動ファイルが最後に外す。
    func testZshWrapperRemovesKeysExportedByUserConfig() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shell-wrapper-\(UUID().uuidString)")
        let userDir = root.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "export ENVMARK=1\n".write(to: userDir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try "export ANTHROPIC_API_KEY=leak\nexport ANTHROPIC_AUTH_TOKEN=leak\nexport RCMARK=1\n"
            .write(to: userDir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let wrapper = try XCTUnwrap(ZshWrapper.prepare(at: root.appendingPathComponent("wrapper")))

        let launch = ShellLaunch.make(base: minimalEnvironment(["SHELL": "/bin/zsh", "HOME": root.path, "ZDOTDIR": userDir.path]),
                                      wrapperDirectory: wrapper)
        let pty = DummyPTY(executable: launch.executable, args: launch.arguments, environment: launch.environmentList,
                           directory: root.path)
        defer { pty.kill() }
        try await Task.sleep(for: .milliseconds(500))
        pty.type("print -r -- \"R=${RCMARK}${ENVMARK} K=${ANTHROPIC_API_KEY-unset} T=${ANTHROPIC_AUTH_TOKEN-unset} Z=$ZDOTDIR\"\r")
        try await waitUntil(timeout: 10) { pty.recorder.text.contains("R=11 ") }
        let output = pty.recorder.text
        XCTAssertTrue(output.contains("R=11 K=unset T=unset Z=\(userDir.path)"), output)
        XCTAssertFalse(output.contains("K=leak"))
        pty.type("exit\r")
        try await waitUntil { pty.recorder.hasExited }
    }

    func testDropsTerminalIdentityAndOwnMarkers() {
        let base = minimalEnvironment([
            "SHELL": "/bin/zsh", "TERM": "screen", "TERM_PROGRAM": "iTerm.app", "TERM_SESSION_ID": "x", "TMUX": "/tmp/t,1,0",
            "ITERM_PROFILE": "Default", "VSCODE_PID": "1", "PWD": "/elsewhere", "OLDPWD": "/old", "SHLVL": "3",
            "CLAUDE_DECK_USER_ZDOTDIR": "/stale", "CLAUDE_DECK_KEEP_ZDOTDIR": "1", "CLAUDE_DECK_WRAPPER_ZDOTDIR": "/stale",
        ])
        let launch = ShellLaunch.make(base: base, wrapperDirectory: nil)
        for key in ["TERM_PROGRAM", "TERM_SESSION_ID", "TMUX", "ITERM_PROFILE", "VSCODE_PID", "PWD", "OLDPWD", "SHLVL",
                    "CLAUDE_DECK_USER_ZDOTDIR", "CLAUDE_DECK_KEEP_ZDOTDIR", "CLAUDE_DECK_WRAPPER_ZDOTDIR"] {
            XCTAssertNil(launch.environment[key], key)
        }
        XCTAssertEqual(launch.environment["TERM"], "xterm-256color")
        XCTAssertFalse(launch.scrubsEachCommand)
    }

    /// アプリがこのシェルから起動された時の ZDOTDIR（挟んだ場所）は利用者のものとみなさない。
    func testWrapperDirectoryInheritedAsZdotdirIsIgnored() {
        let launch = ShellLaunch.make(base: ["SHELL": "/bin/zsh", "HOME": "/Users/me", "ZDOTDIR": "/tmp/w/"], wrapperDirectory: "/tmp/w")
        XCTAssertEqual(launch.environment["CLAUDE_DECK_USER_ZDOTDIR"], "/Users/me")
        XCTAssertNil(launch.environment["CLAUDE_DECK_KEEP_ZDOTDIR"])
        XCTAssertTrue(launch.scrubsEachCommand)
        let bash = ShellLaunch.make(base: ["SHELL": "/bin/bash", "ZDOTDIR": "/z"], wrapperDirectory: "/tmp/w") { _ in true }
        XCTAssertEqual(bash.environment["ZDOTDIR"], "/z")
        XCTAssertFalse(bash.scrubsEachCommand)
    }

    /// direnv のようにプロンプトと cd のたびに API キーを export し直す設定でも、コマンドの実行の直前と cd の直後に外れる（本物の zsh・挟んだ起動ファイル経由）。
    func testPreexecRemovesKeysRestoredAtEachPrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shell-preexec-\(UUID().uuidString)")
        let userDir = root.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rc = """
        export ANTHROPIC_API_KEY=leak
        _fake_direnv() { export ANTHROPIC_API_KEY=again; export ANTHROPIC_AUTH_TOKEN=again; export CLAUDE_CODE_FAKE=again; }
        autoload -Uz add-zsh-hook
        add-zsh-hook precmd _fake_direnv
        add-zsh-hook chpwd _fake_direnv
        """
        try rc.write(to: userDir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let wrapper = try XCTUnwrap(ZshWrapper.prepare(at: root.appendingPathComponent("wrapper")))
        let launch = ShellLaunch.make(base: minimalEnvironment(["SHELL": "/bin/zsh", "HOME": root.path, "ZDOTDIR": userDir.path]),
                                      wrapperDirectory: wrapper)
        let pty = DummyPTY(executable: launch.executable, args: launch.arguments, environment: launch.environmentList,
                           directory: root.path)
        defer { pty.kill() }
        try await Task.sleep(for: .milliseconds(500))
        pty.type("cd /tmp; print -r -- \"P=${ANTHROPIC_API_KEY-unset},${ANTHROPIC_AUTH_TOKEN-unset},${CLAUDE_CODE_FAKE-unset}\"\r")
        try await waitUntil(timeout: 10) { pty.recorder.text.contains("P=unset") || pty.recorder.text.contains("P=again") }
        pty.type("/usr/bin/printenv ANTHROPIC_API_KEY || print NOKEY$((1+1))\r")
        try await waitUntil(timeout: 10) { pty.recorder.text.contains("NOKEY2") || pty.recorder.text.contains("\nagain") }
        let output = pty.recorder.text
        XCTAssertTrue(output.contains("P=unset,unset,unset"), output)
        XCTAssertTrue(output.contains("NOKEY2"), output)
        pty.type("exit\r")
        try await waitUntil { pty.recorder.hasExited }
    }

    /// 利用者の .zshenv が ZDOTDIR を外したら、以降の段は HOME から読む（挟んだ場所を読み続けない）。
    func testUserZshenvUnsettingZdotdirFallsBackToHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shell-zdotdir-\(UUID().uuidString)")
        let userDir = root.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "unset ZDOTDIR\n".write(to: userDir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try "export HOMERC=1\n".write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let wrapper = try XCTUnwrap(ZshWrapper.prepare(at: root.appendingPathComponent("wrapper")))
        let launch = ShellLaunch.make(base: minimalEnvironment(["SHELL": "/bin/zsh", "HOME": root.path, "ZDOTDIR": userDir.path]),
                                      wrapperDirectory: wrapper)
        let pty = DummyPTY(executable: launch.executable, args: launch.arguments, environment: launch.environmentList,
                           directory: root.path)
        defer { pty.kill() }
        try await Task.sleep(for: .milliseconds(500))
        pty.type("print -r -- \"H=${HOMERC-no} M=${CLAUDE_DECK_WRAPPER_ZDOTDIR-gone}\"\r")
        try await waitUntil(timeout: 10) { pty.recorder.text.contains("H=1 ") || pty.recorder.text.contains("H=no ") }
        XCTAssertTrue(pty.recorder.text.contains("H=1 M=gone"), pty.recorder.text)
        pty.type("exit\r")
        try await waitUntil { pty.recorder.hasExited }
    }
}
