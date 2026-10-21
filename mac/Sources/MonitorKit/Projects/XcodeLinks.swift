import Foundation

/// 見出し・iPhone のタブ・iPhone のプレビューが使う Xcode のプロジェクトの決まり方。
public struct XcodeResolution: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// 設定が無く、自動で探した。
        case detected
        /// 設定で指定した。
        case configured
        /// 設定で使わないとした。
        case disabled
    }

    /// 開く `.xcworkspace` / `.xcodeproj` の実体のパス（無ければ nil）。
    public var path: String?
    public var source: Source
    /// 指定した先が使えない理由。
    public var problem: String?

    public init(path: String?, source: Source, problem: String? = nil) {
        self.path = path
        self.source = source
        self.problem = problem
    }

    public var url: URL? { path.map { URL(fileURLWithPath: $0) } }
}

/// Xcode の紐づけの解決（自動 = `XcodeFinder`・指定 = 存在と拡張子とフォルダの内側を確かめる・使わない = nil）。
public enum XcodeLinks {
    public static let extensions: Set<String> = ["xcodeproj", "xcworkspace"]

    /// 指定の形の問題（絶対パス・`~`・`..`・拡張子違い・バンドルの中）。
    public static func pathProblem(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Xcode のプロジェクトを選んでください" }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { return "Xcode のプロジェクトはプロジェクトからの相対パスにしてください" }
        if trimmed.contains("\\") || trimmed.contains("\0") { return "Xcode のプロジェクトの場所に使えない文字が入っています" }
        let parts = components(trimmed)
        if parts.contains("..") { return "Xcode のプロジェクトはプロジェクトの外を指せません" }
        guard let last = parts.last, extensions.contains((last as NSString).pathExtension.lowercased()) else {
            return "Xcode のプロジェクトは .xcodeproj か .xcworkspace を指定してください"
        }
        if parts.dropLast().contains(where: { extensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
            return "Xcode のプロジェクトの中のものは指定できません"
        }
        return nil
    }

    /// `./ios//App.xcodeproj` を `ios/App.xcodeproj` にそろえる（形が正しくなければ nil）。
    public static func normalizedPath(_ raw: String) -> String? {
        guard pathProblem(raw) == nil else { return nil }
        return components(raw.trimmingCharacters(in: .whitespacesAndNewlines)).joined(separator: "/")
    }

    /// 登録プロジェクト（無ければ cwd だけ）の紐づけから、開く先を決める。
    public static func resolve(project: ManagedProject?, cwd: String) -> XcodeResolution {
        guard let project else { return detect(in: cwd) }
        switch project.xcode {
        case nil:
            return detect(in: cwd)
        case .disabled:
            return XcodeResolution(path: nil, source: .disabled)
        case .path(let raw):
            // 作業ツリーで動くルームは、その作業ツリーの同じ場所を先に見る（自動の時と同じく手元のものを開くため）。
            if let tree = worktreeRoot(of: cwd, inside: project.path) {
                let inTree = configured(raw, in: tree)
                if inTree.path != nil { return inTree }
            }
            return configured(raw, in: project.path)
        }
    }

    public static func detect(in cwd: String) -> XcodeResolution {
        XcodeResolution(path: XcodeFinder.find(in: cwd), source: .detected)
    }

    /// 指定の相対パスを `base` の中で確かめる。
    public static func configured(_ raw: String, in base: String) -> XcodeResolution {
        if let problem = pathProblem(raw) { return XcodeResolution(path: nil, source: .configured, problem: problem) }
        let relative = normalizedPath(raw) ?? raw
        let full = (base as NSString).appendingPathComponent(relative)
        guard let realBase = FilePaths.realPath(base), let real = FilePaths.realPath(full) else {
            return XcodeResolution(path: nil, source: .configured, problem: "指定した Xcode のプロジェクトが見つかりません（\(relative)）")
        }
        guard real.hasPrefix(realBase + "/") else {
            return XcodeResolution(path: nil, source: .configured, problem: "指定した Xcode のプロジェクトはプロジェクトの外を指しています（\(relative)）")
        }
        guard extensions.contains((real as NSString).pathExtension.lowercased()), FilePaths.isDirectory(real) else {
            return XcodeResolution(path: nil, source: .configured, problem: "指定した場所は Xcode のプロジェクトではありません（\(relative)）")
        }
        return XcodeResolution(path: real, source: .configured)
    }

    /// 選んだ場所をプロジェクトからの相対パスにする（外・形が違うものは理由を返す）。
    public static func relativePath(of path: String, in projectPath: String) -> Result<String, XcodeLinkFailure> {
        guard let relative = SiteLocator.relativePath(of: path, in: projectPath), relative != "." else {
            return .failure(XcodeLinkFailure(message: "プロジェクトのフォルダの中の .xcodeproj / .xcworkspace を選んでください"))
        }
        if let problem = pathProblem(relative) { return .failure(XcodeLinkFailure(message: problem)) }
        return .success(relative)
    }

    /// 設定画面に出す候補（`XcodeFinder` と同じ除外・上限で浅く探す）。
    public static func candidates(in projectPath: String) -> [String] {
        XcodeFinder.candidates(in: projectPath)
    }

    /// cwd を含む作業ツリー（`.git` がファイルのフォルダ）のうち、プロジェクトのフォルダより下のもの。
    static func worktreeRoot(of cwd: String, inside projectPath: String) -> String? {
        guard let project = ProjectMatcher.normalized(projectPath), var current = ProjectMatcher.normalized(cwd) else { return nil }
        while current.hasPrefix(project + "/") {
            var st = stat()
            if lstat(current + "/.git", &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
    }
}

public struct XcodeLinkFailure: Error, Equatable, Sendable {
    public let message: String
}
