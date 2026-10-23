import Foundation

/// リポジトリの git dir と共通の dir（作業ツリーなら別・そうでなければ同じ）。見張る場所に使う。
public struct GitRepositoryLocation: Sendable, Equatable {
    public var gitDir: String
    public var commonDir: String

    public init(gitDir: String, commonDir: String) {
        self.gitDir = gitDir
        self.commonDir = commonDir
    }

    public var isWorktree: Bool { gitDir != commonDir }

    /// 図の見出しに出すリポジトリの名前（共通の dir の親フォルダ）。
    public var name: String {
        let url = URL(fileURLWithPath: commonDir)
        return url.lastPathComponent == ".git" ? url.deletingLastPathComponent().lastPathComponent : url.lastPathComponent
    }
}

/// 図の 1 行（コミット・線・札）。
public struct GitGraphEntry: Sendable, Equatable, Identifiable {
    public var commit: GitCommit
    public var row: GitGraphRow
    public var labels: [GitRefLabel]

    public var id: String { commit.hash }
}

/// 1 回読み込んだ図。
public struct GitGraphSnapshot: Sendable, Equatable {
    public var location: GitRepositoryLocation
    public var entries: [GitGraphEntry]
    /// 「refs/heads/main」。切り離しなら nil。
    public var headRef: String?
    public var headOid: String?
    public var limit: Int
    /// 件数の上限に達した（古いものが残っているかもしれない）。
    public var hasMore: Bool
    /// 図に出す列の最大数。
    public var maxWidth: Int

    public var currentBranch: String? { headRef.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 } }
}

public enum GitGraphLoad: Sendable, Equatable {
    case loaded(GitGraphSnapshot)
    case notRepository
    case missingFolder
    case failed(String)
}

/// 図と詳細を git から読む（読むだけのコマンドだけ）。
public struct GitRepositoryReader: Sendable {
    public var runner: GitRunner

    public static let defaultLimit = 300
    public static let limitStep = 300
    public static let maxLimit = 3000
    /// 詳細に出すファイルの一覧の出力の上限。
    static let filesOutputLimit = 1 << 20
    static let detailOutputLimit = 1 << 20

    public init(runner: GitRunner) {
        self.runner = runner
    }

    public func load(directory: String, limit: Int = defaultLimit) async -> GitGraphLoad {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else { return .missingFolder }
        do {
            let located = try await runner.run(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], in: directory)
            guard located.succeeded else { return Self.classify(located.stderr) }
            let paths = located.text.split(separator: "\n").map(String.init)
            guard paths.count >= 2 else { return .failed("リポジトリの場所を読めませんでした") }
            let location = GitRepositoryLocation(gitDir: Self.canonical(paths[0]), commonDir: Self.canonical(paths[1]))

            let symbolic = try await runner.run(["symbolic-ref", "-q", "HEAD"], in: directory)
            let headRef = symbolic.status == 0 ? symbolic.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            let verified = try await runner.run(["rev-parse", "-q", "--verify", "HEAD^{commit}"], in: directory)
            let headOid = verified.status == 0 ? verified.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil

            let refsOutput = try await runner.run(["for-each-ref", "--format=\(GitLogParser.refFormat)",
                                                   "refs/heads", "refs/remotes", "refs/tags"], in: directory)
            guard refsOutput.succeeded else { return .failed(Self.firstLine(refsOutput.stderr) ?? "ref を読めませんでした") }
            let refs = GitLogParser.parseRefs(refsOutput.stdout)

            let capped = min(max(limit, 1), Self.maxLimit)
            var commits: [GitCommit] = []
            if headOid != nil || !refs.isEmpty {
                let log: GitOutput
                do {
                    log = try await runner.run(Self.logArguments(limit: capped, includeHead: headOid != nil, dateOrder: true),
                                               in: directory)
                } catch GitRunError.timedOut {
                    // 大きなリポジトリで日付順の並べ替えが間に合わない時は、並べ替えを外して読み直す。
                    log = try await runner.run(Self.logArguments(limit: capped, includeHead: headOid != nil, dateOrder: false),
                                               in: directory)
                }
                guard log.status == 0 || log.truncated else { return .failed(Self.firstLine(log.stderr) ?? "履歴を読めませんでした") }
                commits = GitLogParser.parseLog(log.stdout)
            }
            return .loaded(Self.snapshot(location: location, commits: commits, refs: refs, headRef: headRef,
                                         headOid: headOid, limit: capped))
        } catch let error as GitRunError {
            return .failed(error.message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// --all はスタッシュとノートの履歴まで混ぜるので、ブランチ・リモート・タグと HEAD に限る。
    static func logArguments(limit: Int, includeHead: Bool, dateOrder: Bool) -> [String] {
        var args = ["log"] + (dateOrder ? ["--date-order"] : []) + ["-z", "-n", String(limit), "--format=\(GitLogParser.logFormat)",
                                                                   "--branches", "--remotes", "--tags"]
        if includeHead { args.append("HEAD") }
        args.append("--")
        return args
    }

    /// マージは最初の親との差分、根は空の木との差分。
    static func diffTreeArguments(hash: String, firstParent: String?, renames: Bool) -> [String] {
        var args = ["diff-tree", "--no-ext-diff", "--no-textconv", "-r", "-z", "--name-status"] + (renames ? ["-M"] : []) + ["--no-commit-id"]
        if let firstParent {
            args += [firstParent, hash]
        } else {
            args += ["--root", hash]
        }
        args.append("--")
        return args
    }

    static func snapshot(location: GitRepositoryLocation, commits: [GitCommit], refs: [GitRef], headRef: String?,
                         headOid: String?, limit: Int) -> GitGraphSnapshot {
        let rows = GitGraphLayout.rows(for: commits)
        let labels = GitRefLabels.labels(refs: refs, headRef: headRef, headOid: headOid)
        let entries = zip(commits, rows).map { GitGraphEntry(commit: $0, row: $1, labels: labels[$0.hash] ?? []) }
        return GitGraphSnapshot(location: location, entries: entries, headRef: headRef, headOid: headOid, limit: limit,
                                hasMore: commits.count >= limit, maxWidth: rows.map(\.width).max() ?? 0)
    }

    public func detail(directory: String, hash: String) async -> Result<GitCommitDetail, GitRunErrorMessage> {
        guard GitLogParser.isObjectID(hash) else { return .failure(GitRunErrorMessage("コミットの ID が正しくありません")) }
        do {
            let shown = try await runner.run(["show", "--no-ext-diff", "--no-textconv", "-s", "-z",
                                              "--format=\(GitLogParser.detailFormat)", hash, "--"],
                                             in: directory, outputLimit: Self.detailOutputLimit)
            guard shown.status == 0 || shown.truncated else {
                return .failure(GitRunErrorMessage(Self.firstLine(shown.stderr) ?? "コミットを読めませんでした"))
            }
            // 「-z」で本文の後ろに付く NUL は本文に含めない。
            var body = shown.stdout
            if body.last == 0 { body.removeLast() }
            let firstParent = Self.parentList(body).first
            let files: GitOutput
            do {
                files = try await runner.run(Self.diffTreeArguments(hash: hash, firstParent: firstParent, renames: true),
                                             in: directory, outputLimit: Self.filesOutputLimit)
            } catch GitRunError.timedOut {
                // 名前の変更の判定は中身を比べるので重い。間に合わなければ判定を外して一覧だけ出す。
                files = try await runner.run(Self.diffTreeArguments(hash: hash, firstParent: firstParent, renames: false),
                                             in: directory, outputLimit: Self.filesOutputLimit)
            }
            guard files.status == 0 || files.truncated else {
                return .failure(GitRunErrorMessage(Self.firstLine(files.stderr) ?? "変わったファイルを読めませんでした"))
            }
            guard let detail = GitLogParser.parseDetail(body, files: files.stdout, filesTruncated: files.truncated) else {
                return .failure(GitRunErrorMessage("コミットを読めませんでした"))
            }
            return .success(detail)
        } catch let error as GitRunError {
            return .failure(GitRunErrorMessage(error.message))
        } catch {
            return .failure(GitRunErrorMessage(error.localizedDescription))
        }
    }

    private static func parentList(_ data: Data) -> [String] {
        let fields = data.split(separator: 0, maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count >= 2 else { return [] }
        return String(decoding: fields[1], as: UTF8.self).split(separator: " ").map(String.init).filter(GitLogParser.isObjectID)
    }

    static func classify(_ stderr: String) -> GitGraphLoad {
        if stderr.contains("not a git repository") { return .notRepository }
        return .failed(firstLine(stderr) ?? "リポジトリを読めませんでした")
    }

    static func firstLine(_ text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// 見張りのイベントは実体のパスで届くので、シンボリックリンクを解いておく。
    public static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// 画面に出す失敗の文言。
public struct GitRunErrorMessage: Error, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}
