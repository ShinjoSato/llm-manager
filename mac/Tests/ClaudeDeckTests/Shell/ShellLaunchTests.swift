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

    func testWrapperLoginFileUnsetsAPIKeysLast() {
        let login = ZshWrapper.contents(for: ".zlogin")
        XCTAssertTrue(login.hasSuffix(ChildEnvironment.unsetCommand + "\n"))
        for name in ZshWrapper.fileNames {
            XCTAssertTrue(ZshWrapper.contents(for: name).contains("builtin source \"$ZDOTDIR/\(name)\""), name)
        }
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
}
