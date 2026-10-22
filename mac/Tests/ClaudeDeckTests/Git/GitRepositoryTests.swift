import XCTest
@testable import MonitorKit

/// 一時ディレクトリに作った git のリポジトリ（書き換えは試験の準備だけで、読むのは `GitRepositoryReader`）。
private struct ScratchRepo {
    let root: URL
    let git: String
    private var clock = 1_700_000_000

    init(git: String) throws {
        self.git = git
        root = URL(fileURLWithPath: GitRepositoryReader.canonical(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("git-graph-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("main"), withIntermediateDirectories: true)
    }

    var path: String { root.appendingPathComponent("main").path }

    @discardableResult
    func run(_ args: [String], in directory: String? = nil, date: Int = 1_700_000_000) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory ?? path)
        // 利用者の設定（署名・フック・既定のブランチ名）に左右されないようにする。
        process.environment = [
            "HOME": root.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_AUTHOR_NAME": "作者 🧑‍💻", "GIT_AUTHOR_EMAIL": "author@example.com",
            "GIT_COMMITTER_NAME": "Committer", "GIT_COMMITTER_EMAIL": "committer@example.com",
            "GIT_AUTHOR_DATE": "@\(date) +0900", "GIT_COMMITTER_DATE": "@\(date) +0900",
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "git \(args.joined(separator: " "))", code: Int(process.terminationStatus)) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func commit(_ message: String, file: String, contents: String = UUID().uuidString, in directory: String? = nil) throws -> String {
        clock += 60
        let dir = directory ?? path
        let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try run(["add", "-A"], in: dir)
        try run(["commit", "-q", "-m", message], in: dir, date: clock)
        return try run(["rev-parse", "HEAD"], in: dir)
    }

    mutating func tick() -> Int {
        clock += 60
        return clock
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

final class GitRepositoryTests: XCTestCase {
    private var gitPath: String!

    override func setUpWithError() throws {
        guard let git = GitRunner.locate() else { throw XCTSkip("git が無い環境") }
        gitPath = git
    }

    private var reader: GitRepositoryReader { GitRepositoryReader(runner: GitRunner(executable: gitPath)) }

    private func loaded(_ result: GitGraphLoad, file: StaticString = #filePath, line: UInt = #line) throws -> GitGraphSnapshot {
        guard case .loaded(let snapshot) = result else {
            XCTFail("読めませんでした: \(result)", file: file, line: line)
            throw XCTSkip()
        }
        return snapshot
    }

    func testReadsBranchesMergesTagsRemotesAndWorktree() async throws {
        var repo = try ScratchRepo(git: gitPath)
        defer { repo.remove() }
        try repo.run(["init", "-q", "-b", "main"])
        let a = try repo.commit("A: 最初", file: "a.txt")
        let b = try repo.commit("B: 区切り\u{1f}\u{1e} と %x00 と\tタブ 🚀", file: "b.txt")
        try repo.run(["tag", "-a", "v1.0", "-m", "注釈つき", b], date: repo.tick())
        try repo.run(["switch", "-q", "-c", "feature"])
        let f1 = try repo.commit("F1", file: "f1.txt")
        try repo.run(["mv", "a.txt", "renamed.txt"])
        try repo.run(["commit", "-q", "-m", "F2: 名前の変更"], date: repo.tick())
        let f2 = try repo.run(["rev-parse", "HEAD"])
        try repo.run(["switch", "-q", "main"])
        let c = try repo.commit("C", file: "c.txt")
        try repo.run(["tag", "light", c])
        try repo.run(["merge", "-q", "--no-ff", "-m", "Merge feature", "feature"], date: repo.tick())
        let m = try repo.run(["rev-parse", "HEAD"])
        try repo.run(["update-ref", "refs/remotes/origin/main", m])
        try repo.run(["update-ref", "refs/remotes/origin/feature", f1])
        try repo.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        try repo.run(["switch", "-q", "--orphan", "docs"])
        let d = try repo.commit("docs root", file: "docs/index.md")
        try repo.run(["switch", "-q", "-f", "main"])
        // スタッシュは図に混ぜない。
        try "dirty".write(toFile: repo.path + "/c.txt", atomically: true, encoding: .utf8)
        try repo.run(["stash", "-q"], date: repo.tick())
        let worktree = repo.root.appendingPathComponent("wt").path
        try repo.run(["worktree", "add", "-q", "-b", "wt-branch", worktree, b])
        let w = try repo.commit("W: 作業ツリー", file: "w.txt", in: worktree)

        let snapshot = try loaded(await reader.load(directory: repo.path))
        let hashes = snapshot.entries.map(\.commit.hash)
        XCTAssertEqual(Set(hashes), [a, b, f1, f2, c, m, d, w])
        XCTAssertEqual(snapshot.headRef, "refs/heads/main")
        XCTAssertEqual(snapshot.currentBranch, "main")
        XCTAssertEqual(snapshot.headOid, m)
        XCTAssertFalse(snapshot.location.isWorktree)
        XCTAssertFalse(snapshot.hasMore)
        // 子が親より先に来る。
        for entry in snapshot.entries {
            let index = hashes.firstIndex(of: entry.commit.hash)!
            for parent in entry.commit.parents { XCTAssertGreaterThan(hashes.firstIndex(of: parent)!, index) }
        }
        func labels(_ hash: String) -> [GitRefLabel] { snapshot.entries.first { $0.commit.hash == hash }!.labels }
        XCTAssertEqual(labels(m), [GitRefLabel(kind: .branch, name: "main", remotes: ["origin"], isCurrent: true)])
        XCTAssertEqual(labels(f1), [GitRefLabel(kind: .remote, name: "origin/feature")])
        XCTAssertEqual(labels(f2), [GitRefLabel(kind: .branch, name: "feature")])
        XCTAssertEqual(labels(b), [GitRefLabel(kind: .tag, name: "v1.0")])
        XCTAssertEqual(labels(c), [GitRefLabel(kind: .tag, name: "light")])
        XCTAssertEqual(labels(d), [GitRefLabel(kind: .branch, name: "docs")])
        XCTAssertEqual(labels(w), [GitRefLabel(kind: .branch, name: "wt-branch")])
        let commitB = snapshot.entries.first { $0.commit.hash == b }!.commit
        XCTAssertEqual(commitB.subject, "B: 区切り\u{1f}\u{1e} と %x00 と\tタブ 🚀")
        XCTAssertEqual(commitB.authorName, "作者 🧑‍💻")
        XCTAssertEqual(snapshot.entries.first { $0.commit.hash == m }!.commit.parents, [c, f2])
        // 根が 2 つ（a と docs）。
        XCTAssertEqual(snapshot.entries.filter { $0.commit.parents.isEmpty }.map(\.commit.hash).sorted(), [a, d].sorted())
        XCTAssertGreaterThanOrEqual(snapshot.maxWidth, 2)

        // 作業ツリーからは共通のリポジトリの全ブランチと、その作業ツリーの HEAD。
        let fromWorktree = try loaded(await reader.load(directory: worktree))
        XCTAssertTrue(fromWorktree.location.isWorktree)
        XCTAssertEqual(fromWorktree.location.commonDir, snapshot.location.gitDir)
        XCTAssertEqual(fromWorktree.location.name, "main")
        XCTAssertEqual(fromWorktree.headRef, "refs/heads/wt-branch")
        XCTAssertEqual(Set(fromWorktree.entries.map(\.commit.hash)), Set(hashes))
        XCTAssertEqual(fromWorktree.entries.first { $0.commit.hash == w }!.labels.first?.isCurrent, true)
        XCTAssertEqual(fromWorktree.entries.first { $0.commit.hash == m }!.labels.first?.isCurrent, false)

        // 件数の上限。
        let limited = try loaded(await reader.load(directory: repo.path, limit: 3))
        XCTAssertEqual(limited.entries.count, 3)
        XCTAssertTrue(limited.hasMore)

        // 詳細: マージは最初の親との差分、名前の変更、根は全部が追加。
        let merge = try await reader.detail(directory: repo.path, hash: m).get()
        XCTAssertEqual(merge.parents, [c, f2])
        XCTAssertEqual(merge.message, "Merge feature")
        XCTAssertEqual(Set(merge.files.map(\.path)), ["f1.txt", "renamed.txt"])
        let rename = try await reader.detail(directory: repo.path, hash: f2).get()
        XCTAssertEqual(rename.files, [GitFileChange(status: .renamed, path: "renamed.txt", oldPath: "a.txt")])
        XCTAssertEqual(rename.committerName, "Committer")
        let root = try await reader.detail(directory: repo.path, hash: a).get()
        XCTAssertEqual(root.files, [GitFileChange(status: .added, path: "a.txt")])
        XCTAssertEqual(root.authorEmail, "author@example.com")
        let special = try await reader.detail(directory: repo.path, hash: b).get()
        XCTAssertEqual(special.message, "B: 区切り\u{1f}\u{1e} と %x00 と\tタブ 🚀")
        if case .success = await reader.detail(directory: repo.path, hash: "--output=/tmp/x") { XCTFail("ID でない値を通した") }
    }

    func testEmptyRepositoryNotRepositoryAndMissingFolder() async throws {
        let repo = try ScratchRepo(git: gitPath)
        defer { repo.remove() }
        let plain = try await reader.load(directory: repo.path)
        XCTAssertEqual(plain, .notRepository)
        let missing = await reader.load(directory: repo.path + "/nothing")
        XCTAssertEqual(missing, .missingFolder)
        try repo.run(["init", "-q", "-b", "main"])
        let empty = try loaded(await reader.load(directory: repo.path))
        XCTAssertEqual(empty.entries, [])
        XCTAssertNil(empty.headOid)
        XCTAssertEqual(empty.headRef, "refs/heads/main")
    }

    func testReadingDoesNotTouchTheRepository() async throws {
        var repo = try ScratchRepo(git: gitPath)
        defer { repo.remove() }
        try repo.run(["init", "-q", "-b", "main"])
        let head = try repo.commit("A", file: "a.txt")
        let gitDir = repo.path + "/.git"
        let before = try FileManager.default.subpathsOfDirectory(atPath: gitDir).sorted()
        let index = try FileManager.default.attributesOfItem(atPath: gitDir + "/index")[.modificationDate] as? Date
        _ = try loaded(await reader.load(directory: repo.path))
        _ = try await reader.detail(directory: repo.path, hash: head).get()
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: gitDir).sorted(), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: gitDir + "/index")[.modificationDate] as? Date, index)
    }

    @MainActor
    func testWatcherReportsRefChangesButNotIndexWrites() async throws {
        var repo = try ScratchRepo(git: gitPath)
        defer { repo.remove() }
        try repo.run(["init", "-q", "-b", "main"])
        _ = try repo.commit("A", file: "a.txt")
        let snapshot = try loaded(await reader.load(directory: repo.path))
        let count = Box(0)
        let watcher = GitRefWatcher(location: snapshot.location) { count.mutate { $0 += 1 } }
        watcher.start()
        defer { watcher.stop() }
        XCTAssertTrue(watcher.isRunning)
        try await Task.sleep(for: .milliseconds(400))
        try "x".write(toFile: repo.path + "/b.txt", atomically: true, encoding: .utf8)
        try repo.run(["add", "b.txt"])
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(count.value, 0, "index の書き換えで知らせた")
        try repo.run(["branch", "topic"])
        try await waitUntil(timeout: 5) { count.value > 0 }
        watcher.stop()
        XCTAssertFalse(watcher.isRunning)
    }

    func testWatchFilter() {
        let location = GitRepositoryLocation(gitDir: "/r/.git/worktrees/wt", commonDir: "/r/.git")
        for path in ["/r/.git/worktrees/wt/HEAD", "/r/.git/refs/heads/feature/x", "/r/.git/packed-refs", "/r/.git/logs/HEAD",
                     "/r/.git/HEAD", "/r/.git/refs", "/r/.git/worktrees/wt/logs/HEAD", "/r/.git"] {
            XCTAssertTrue(GitWatchFilter.isRelevant(path, location: location), path)
        }
        for path in ["/r/.git/index", "/r/.git/objects/ab/cdef", "/r/.git/refs/heads/main.lock", "/r/.git/HEAD.lock",
                     "/r/.git/FETCH_HEAD", "/r/.git/logs/refs/heads/main", "/r/.git/worktrees/other/HEAD", "/r/.gitx/HEAD", "/r/src/HEAD"] {
            XCTAssertFalse(GitWatchFilter.isRelevant(path, location: location), path)
        }
    }
}

final class GitRunnerTests: XCTestCase {
    func testEnvironmentDropsKeysSessionMarksAndGitOverrides() {
        let env = GitRunner.environment(base: [
            "ANTHROPIC_API_KEY": "sk", "ANTHROPIC_AUTH_TOKEN": "t", "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDECODE": "1",
            "GIT_DIR": "/elsewhere", "GIT_WORK_TREE": "/w", "GIT_OPTIONAL_LOCKS": "1", "HOME": "/Users/u", "PATH": "/usr/bin",
        ])
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_ENTRYPOINT", "CLAUDECODE", "GIT_DIR", "GIT_WORK_TREE"] {
            XCTAssertNil(env[key], key)
        }
        XCTAssertEqual(env["GIT_OPTIONAL_LOCKS"], "0")
        XCTAssertEqual(env["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(env["GIT_NO_LAZY_FETCH"], "1")
        XCTAssertEqual(env["LC_ALL"], "C")
        XCTAssertEqual(env["HOME"], "/Users/u")
    }

    /// 起動の経路そのもので、子に API キーが届かないことを確かめる。
    func testSpawnedChildDoesNotSeeApiKey() throws {
        let env = GitRunner.environment(base: ["ANTHROPIC_API_KEY": "sk-should-not-leak", "CLAUDE_CODE_SSE_PORT": "1", "PATH": "/usr/bin"])
        let result = try GitRunner.execute(executable: "/usr/bin/env", arguments: [], environment: env, directory: "/",
                                           timeout: 5, limit: 1 << 20, cancelled: GitRunner.CancelFlag()).get()
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.text.contains("ANTHROPIC"))
        XCTAssertFalse(result.text.contains("CLAUDE_CODE"))
        XCTAssertTrue(result.text.contains("GIT_OPTIONAL_LOCKS=0"))
    }

    func testTimeoutOutputLimitAndCancel() throws {
        let started = Date()
        let slow = GitRunner.execute(executable: "/bin/sleep", arguments: ["10"], environment: [:], directory: "/",
                                     timeout: 0.3, limit: 1024, cancelled: GitRunner.CancelFlag())
        XCTAssertEqual(slow.failure, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)

        let flood = try GitRunner.execute(executable: "/usr/bin/yes", arguments: [], environment: [:], directory: "/",
                                          timeout: 5, limit: 4096, cancelled: GitRunner.CancelFlag()).get()
        XCTAssertTrue(flood.truncated)
        XCTAssertEqual(flood.stdout.count, 4096)
        XCTAssertFalse(flood.succeeded)

        let flag = GitRunner.CancelFlag()
        flag.set()
        let cancelled = GitRunner.execute(executable: "/bin/sleep", arguments: ["10"], environment: [:], directory: "/",
                                          timeout: 5, limit: 1024, cancelled: flag)
        XCTAssertEqual(cancelled.failure, .cancelled)

        let missing = GitRunner.execute(executable: "/nonexistent/git", arguments: [], environment: [:], directory: "/",
                                        timeout: 5, limit: 1024, cancelled: GitRunner.CancelFlag())
        XCTAssertEqual(missing.failure, .launchFailed(ENOENT))
    }

    func testRejectsCommandsOutsideTheReadOnlyList() async {
        let runner = GitRunner(executable: "/usr/bin/true")
        for sub in ["fetch", "commit", "status", "gc", "push", "-c"] {
            do {
                _ = try await runner.run([sub], in: "/")
                XCTFail(sub)
            } catch {}
        }
    }

    func testLocatePrefersDeveloperDirAndSkipsTheShim() {
        let present: Set<String> = ["/Custom.app/Contents/Developer/usr/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git", "/usr/bin/git"]
        XCTAssertEqual(GitRunner.locate(environment: ["DEVELOPER_DIR": "/Custom.app/Contents/Developer"], selectedDeveloperDir: nil,
                                        isExecutable: present.contains), "/Custom.app/Contents/Developer/usr/bin/git")
        XCTAssertEqual(GitRunner.locate(environment: [:], selectedDeveloperDir: "/Missing", isExecutable: present.contains),
                       "/Library/Developer/CommandLineTools/usr/bin/git")
        XCTAssertNil(GitRunner.locate(environment: [:], selectedDeveloperDir: nil, isExecutable: { $0 == "/usr/bin/git" }))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
