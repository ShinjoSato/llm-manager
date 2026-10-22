import Foundation

/// 図の 1 行分のコミット。
public struct GitCommit: Sendable, Equatable, Identifiable {
    public var hash: String
    public var parents: [String]
    public var authorName: String
    public var authorEmail: String
    public var authorDate: Date
    public var subject: String

    public var id: String { hash }
    public var shortHash: String { String(hash.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }

    public init(hash: String, parents: [String], authorName: String = "", authorEmail: String = "",
                authorDate: Date = Date(timeIntervalSince1970: 0), subject: String = "") {
        self.hash = hash
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.subject = subject
    }
}

/// ブランチ・リモート・タグの ref 1 つ。
public struct GitRef: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case localBranch, remoteBranch, tag }

    public var kind: Kind
    /// 「main」「origin/main」「v1.0」。
    public var name: String
    public var fullName: String
    /// 指すコミット（注釈つきタグは剥がした先）。
    public var target: String

    public init(kind: Kind, name: String, fullName: String, target: String) {
        self.kind = kind
        self.name = name
        self.fullName = fullName
        self.target = target
    }

    /// 「origin/main」なら（"origin", "main"）。
    public var remoteParts: (remote: String, branch: String)? {
        guard kind == .remoteBranch, let slash = name.firstIndex(of: "/") else { return nil }
        return (String(name[..<slash]), String(name[name.index(after: slash)...]))
    }
}

/// 変わったファイル 1 つ。
public struct GitFileChange: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Equatable {
        case added = "A", modified = "M", deleted = "D", renamed = "R", copied = "C", typeChanged = "T", other = "?"
    }

    public var status: Status
    public var path: String
    /// 名前の変更・複製の元。
    public var oldPath: String?

    public var id: String { "\(status.rawValue)\u{0}\(oldPath ?? "")\u{0}\(path)" }

    public init(status: Status, path: String, oldPath: String? = nil) {
        self.status = status
        self.path = path
        self.oldPath = oldPath
    }
}

/// コミットを押した時に出す詳細。
public struct GitCommitDetail: Sendable, Equatable {
    public var hash: String
    public var parents: [String]
    public var authorName: String
    public var authorEmail: String
    public var authorDate: Date
    public var committerName: String
    public var committerEmail: String
    public var commitDate: Date
    public var message: String
    public var files: [GitFileChange]
    /// 一覧が出力の上限で切れた。
    public var filesTruncated: Bool
}

/// git の出力の読み取り（区切りは NUL。説明・名前に NUL は入らないので、どの文字を含んでもずれない）。
public enum GitLogParser {
    /// `log -z` の 1 件の欄（ハッシュ・親・作者名・メール・日時・1 行目）。
    public static let logFormat = "%H%x00%P%x00%an%x00%ae%x00%at%x00%s"
    static let logFieldCount = 6

    /// `for-each-ref` の 1 行（指す先・剥がした先・名前・シンボリックの先）。ref の名前に改行や NUL は入らない。
    public static let refFormat = "%(objectname)%00%(*objectname)%00%(refname)%00%(symref)"

    /// `show -s` の欄（本文は最後に置いて残り全部を取る）。
    public static let detailFormat = "%H%x00%P%x00%an%x00%ae%x00%at%x00%cn%x00%ce%x00%ct%x00%B"
    static let detailFieldCount = 9

    public static func isObjectID(_ text: some StringProtocol) -> Bool {
        (text.count == 40 || text.count == 64) && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// NUL で終わった欄だけ（上限で切れた最後の欄は途中なので捨てる）。
    static func terminatedTokens(_ data: Data) -> [String] {
        var tokens = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if !tokens.isEmpty { tokens.removeLast() }
        return tokens
    }

    /// 出力が上限で切れていれば、欠けた最後の 1 件は捨てる。欄がずれたらそこで止める。
    public static func parseLog(_ data: Data) -> [GitCommit] {
        let fields = terminatedTokens(data)
        var commits: [GitCommit] = []
        var index = 0
        while index + logFieldCount <= fields.count {
            var hash = fields[index]
            // `-z` の区切りの後に改行が入る版があっても、ハッシュの前の空白は無視する。
            hash = hash.trimmingCharacters(in: .whitespacesAndNewlines)
            let parents = fields[index + 1].split(separator: " ").map(String.init)
            guard isObjectID(hash), parents.allSatisfy(isObjectID), let seconds = TimeInterval(fields[index + 4]) else { break }
            commits.append(GitCommit(hash: hash, parents: parents, authorName: fields[index + 2],
                                     authorEmail: fields[index + 3], authorDate: Date(timeIntervalSince1970: seconds),
                                     subject: fields[index + 5]))
            index += logFieldCount
        }
        return commits
    }

    /// ブランチ・リモート・タグだけを拾う（`origin/HEAD` のようなシンボリックは同じコミットの重複になるので除く）。
    public static func parseRefs(_ data: Data) -> [GitRef] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4, parts[3].isEmpty else { return nil }
            let target = parts[1].isEmpty ? parts[0] : parts[1]
            guard isObjectID(target) else { return nil }
            let full = parts[2]
            for (prefix, kind) in [("refs/heads/", GitRef.Kind.localBranch), ("refs/remotes/", .remoteBranch), ("refs/tags/", .tag)]
            where full.hasPrefix(prefix) && full.count > prefix.count {
                return GitRef(kind: kind, name: String(full.dropFirst(prefix.count)), fullName: full, target: target)
            }
            return nil
        }
    }

    /// `show -s` と `diff-tree -z --name-status` の出力から詳細を組む。
    public static func parseDetail(_ data: Data, files: Data, filesTruncated: Bool) -> GitCommitDetail? {
        let fields = data.split(separator: 0, maxSplits: detailFieldCount - 1, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard fields.count == detailFieldCount, isObjectID(fields[0]),
              let authored = TimeInterval(fields[4]), let committed = TimeInterval(fields[7]) else { return nil }
        let message = fields[8].replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return GitCommitDetail(hash: fields[0], parents: fields[1].split(separator: " ").map(String.init),
                               authorName: fields[2], authorEmail: fields[3], authorDate: Date(timeIntervalSince1970: authored),
                               committerName: fields[5], committerEmail: fields[6], commitDate: Date(timeIntervalSince1970: committed),
                               message: message, files: parseNameStatus(files), filesTruncated: filesTruncated)
    }

    /// `-z --name-status` の並び（状態 NUL パス NUL、名前の変更と複製は 状態 NUL 元 NUL 先 NUL）。
    public static func parseNameStatus(_ data: Data) -> [GitFileChange] {
        let tokens = terminatedTokens(data)
        var changes: [GitFileChange] = []
        var index = 0
        while index < tokens.count {
            let code = tokens[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let letter = code.first, letter.isLetter else { break }
            let status = GitFileChange.Status(rawValue: String(letter)) ?? .other
            if status == .renamed || status == .copied {
                guard index + 2 < tokens.count else { break }
                changes.append(GitFileChange(status: status, path: tokens[index + 2], oldPath: tokens[index + 1]))
                index += 3
            } else {
                guard index + 1 < tokens.count else { break }
                changes.append(GitFileChange(status: status, path: tokens[index + 1]))
                index += 2
            }
        }
        return changes
    }
}
