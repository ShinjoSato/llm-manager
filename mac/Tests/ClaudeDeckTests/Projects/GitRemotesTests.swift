import XCTest
@testable import MonitorKit

final class GitRemotesTests: XCTestCase {
    var dir: URL!
    var project: String { dir.appendingPathComponent("proj").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("git-remotes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func pair(_ url: String) -> String? {
        GitRemotes.githubRepository(fromURL: url).map { "\($0.owner)/\($0.repo)" }
    }

    func testParsesGitHubURLForms() {
        XCTAssertEqual(pair("https://github.com/ShinjoSato/llm-manager.git"), "ShinjoSato/llm-manager")
        XCTAssertEqual(pair("https://github.com/ShinjoSato/llm-manager"), "ShinjoSato/llm-manager")
        XCTAssertEqual(pair("https://github.com/ShinjoSato/llm-manager/"), "ShinjoSato/llm-manager")
        XCTAssertEqual(pair("https://user:token@github.com/a/b.git"), "a/b")
        XCTAssertEqual(pair("http://www.github.com/a/b"), "a/b")
        XCTAssertEqual(pair("git@github.com:ShinjoSato/blog.git"), "ShinjoSato/blog")
        XCTAssertEqual(pair("git@github.com:ShinjoSato/blog"), "ShinjoSato/blog")
        XCTAssertEqual(pair("github.com:a/b.git"), "a/b")
        XCTAssertEqual(pair("ssh://git@github.com/a/b.git"), "a/b")
        XCTAssertEqual(pair("ssh://git@github.com:22/a/b"), "a/b")
        XCTAssertEqual(pair("git://GitHub.com/a/my.repo.git"), "a/my.repo")
    }

    func testIgnoresNonGitHubAndMalformedURLs() {
        for url in ["https://gitlab.com/a/b.git", "git@bitbucket.org:a/b.git", "https://github.com.evil.example/a/b",
                    "https://github.com/a", "https://github.com/a/b/c", "/Users/x/repo", "./a:b/c", "file:///github.com/a/b",
                    "ftp://github.com/a/b", "https://github.com/-bad/b", "", "github.com"] {
            XCTAssertNil(pair(url), url)
        }
    }

    func testReadsRemotesFromConfig() {
        let config = """
        [core]
        \trepositoryformatversion = 0
        # comment
        [remote "upstream"]
        \turl = git@github.com:other/tool.git
        \tfetch = +refs/heads/*:refs/remotes/upstream/*
        [remote "origin"]
        \tURL = "https://github.com/ShinjoSato/llm-manager.git" ; trailing
        \turl = https://github.com/ignored/second.git
        [remote "gitlab"]
        \turl = https://gitlab.com/a/b.git
        [branch "develop"]
        \tremote = origin
        \turl = https://github.com/not/remote.git
        """
        let remotes = GitRemotes.remotes(inConfig: config)
        XCTAssertEqual(remotes.map(\.name), ["upstream", "origin", "gitlab"])
        XCTAssertEqual(remotes[1].url, "https://github.com/ShinjoSato/llm-manager.git")
        let candidates = GitRemotes.githubCandidates(remotes: remotes)
        XCTAssertEqual(candidates, [GitHubRemoteCandidate(remote: "origin", owner: "ShinjoSato", repo: "llm-manager"),
                                    GitHubRemoteCandidate(remote: "upstream", owner: "other", repo: "tool")], "origin を先に・GitHub 以外は出さない")
        XCTAssertEqual(GitRemotes.remotes(inConfig: "[remote.origin]\nurl = git@github.com:a/b.git").map(\.name), ["origin"])
    }

    func testDeduplicatesSameRepository() {
        let remotes = [GitRemotes.Remote(name: "origin", url: "git@github.com:a/b.git"),
                       GitRemotes.Remote(name: "mirror", url: "https://github.com/A/B")]
        XCTAssertEqual(GitRemotes.githubCandidates(remotes: remotes).map(\.remote), ["origin"])
    }

    func testReadsPlainRepository() throws {
        try write("[remote \"origin\"]\n\turl = git@github.com:a/plain.git\n", to: project + "/.git/config")
        XCTAssertEqual(GitRemotes.githubCandidates(projectPath: project).map(\.repo), ["plain"])
    }

    func testFollowsWorktreeGitFileAndCommonDir() throws {
        let main = dir.appendingPathComponent("main").path
        try write("[remote \"origin\"]\n\turl = https://github.com/a/main-repo.git\n", to: main + "/.git/config")
        // 作業ツリーの gitdir には remote が無く、commondir の先の config に remote がある。
        try write("[core]\n", to: main + "/.git/worktrees/wt/config")
        try write("../..\n", to: main + "/.git/worktrees/wt/commondir")
        try write("gitdir: \(main)/.git/worktrees/wt\n", to: project + "/.git")
        XCTAssertEqual(GitRemotes.configPath(projectPath: project).map { ($0 as NSString).standardizingPath },
                       (main + "/.git/config" as NSString).standardizingPath)
        XCTAssertEqual(GitRemotes.githubCandidates(projectPath: project).map(\.repo), ["main-repo"])
    }

    func testFollowsRelativeGitDirWithoutCommonDir() throws {
        // サブモジュールの形（相対の gitdir・commondir 無し）。
        try write("[remote \"origin\"]\n\turl = git@github.com:a/sub.git\n", to: dir.appendingPathComponent("modules/sub/config").path)
        try write("gitdir: ../modules/sub\n", to: project + "/.git")
        XCTAssertEqual(GitRemotes.githubCandidates(projectPath: project).map(\.repo), ["sub"])
    }

    func testDoesNotFollowLinksOutsideOrReadLargeFiles() throws {
        let elsewhere = dir.appendingPathComponent("elsewhere/.git").path
        try write("[remote \"origin\"]\n\turl = git@github.com:a/outside.git\n", to: elsewhere + "/config")
        try FileManager.default.createSymbolicLink(atPath: project + "/.git", withDestinationPath: elsewhere)
        XCTAssertEqual(GitRemotes.githubCandidates(projectPath: project), [], "フォルダの外へ出るリンクは辿らない")
        try FileManager.default.removeItem(atPath: project + "/.git")

        // config 自体がリンクなら読まない。
        try FileManager.default.createDirectory(atPath: project + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: project + "/.git/config", withDestinationPath: elsewhere + "/config")
        XCTAssertEqual(GitRemotes.githubCandidates(projectPath: project), [])
        try FileManager.default.removeItem(atPath: project + "/.git/config")

        let big = "[remote \"origin\"]\n\turl = git@github.com:a/big.git\n" + String(repeating: "# pad\n", count: GitRemotes.maxConfigBytes / 6 + 10)
        try write(big, to: project + "/.git/config")
        XCTAssertEqual(GitRemotes.githubCandidates(projectPath: project), [], "大きいファイルは読まない")
    }

    func testNoGitFolderGivesNoCandidates() {
        XCTAssertNil(GitRemotes.configPath(projectPath: project))
        XCTAssertEqual(GitRemotes.githubCandidates(projectPath: project), [])
    }
}
