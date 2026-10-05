import Foundation

/// `settings.json` の読み書き。読めない・知らない版のファイルは上書きせずに残す。
public struct SettingsFile: Sendable {
    public static let environmentKey = "CLAUDE_DECK_SETTINGS"

    public let url: URL
    /// 置き場所のディレクトリを 0700 に締めるか（既定の Application Support の時だけ）。
    public let restrictsDirectory: Bool

    public init(url: URL, restrictsDirectory: Bool? = nil) {
        self.url = url
        self.restrictsDirectory = restrictsDirectory
            ?? (url.deletingLastPathComponent().standardizedFileURL.path == DeckPaths.applicationSupport.standardizedFileURL.path)
    }

    /// 既定の場所（`CLAUDE_DECK_SETTINGS` があればそちら）。
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment[environmentKey], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return DeckPaths.applicationSupport.appendingPathComponent("settings.json")
    }

    /// 以前の版のプロジェクト一覧（設定と同じ場所の `projects.json`）。
    public var legacyProjectsURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("projects.json")
    }

    public enum LoadResult: Equatable, Sendable {
        case loaded(DeckSettings)
        case missing
        /// 読めない（壊れている・知らない版）。理由を画面に出す。
        case unreadable(String)
    }

    public func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable("\(url.path) を読めません") }
        return Self.decode(data, name: url.lastPathComponent)
    }

    /// 中身を設定として読む（取り込みにも使う）。
    public static func decode(_ data: Data, name: String = "settings.json") -> LoadResult {
        guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
            return .unreadable("\(name) が JSON として読めません")
        }
        guard let version = dict["version"] as? Int else {
            return .unreadable("\(name) に version がありません")
        }
        guard version == DeckSettings.currentVersion else {
            return .unreadable("\(name) は対応していない版です（version \(version)）。新しい claude-deck で書かれた可能性があります")
        }
        let settings: DeckSettings
        do {
            settings = try JSONDecoder().decode(DeckSettings.self, from: data)
        } catch {
            return .unreadable("\(name) の形が正しくありません（\(describe(error))）")
        }
        let blocking = SettingsValidation.blockingProblems(settings)
        guard blocking.isEmpty else {
            return .unreadable("\(name) の中身に問題があります: " + blocking.joined(separator: " / "))
        }
        return .loaded(settings)
    }

    /// ファイルの同一性（inode・更新時刻・大きさ）。自分が書いた後の変更通知で読み直しを省くために使う。
    public struct Stamp: Equatable, Sendable {
        let inode: UInt64
        let modified: Int64
        let size: Int64
    }

    public func stamp() -> Stamp? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Stamp(inode: UInt64(st.st_ino),
                     modified: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec),
                     size: Int64(st.st_size))
    }

    /// 原子的に 0600 で書く。今のファイルが読めない時は上書きしない。
    public func save(_ settings: DeckSettings) throws {
        if case .unreadable(let reason) = load() { throw SaveError.existingUnreadable(reason) }
        try SecureFile.write(try settings.encoded(), to: url, restrictDirectory: restrictsDirectory)
    }

    public enum SaveError: Error, Equatable {
        case existingUnreadable(String)
    }

    public struct Bootstrap: Equatable, Sendable {
        public var result: LoadResult
        /// 移行した内容を settings.json に書けなかった理由（中身は手元に持って表示する）。
        public var saveFailure: String?
        /// 以前の projects.json を読めなかった理由。
        public var legacyProblem: String?
    }

    /// 設定が無い時の初期値。以前の `projects.json` があれば取り込む（`projects.json` は消さない）。
    public func bootstrap() -> Bootstrap {
        let current = load()
        guard current == .missing else { return Bootstrap(result: current) }
        guard FileManager.default.fileExists(atPath: legacyProjectsURL.path) else { return Bootstrap(result: .missing) }
        guard let data = try? Data(contentsOf: legacyProjectsURL), let projects = Self.legacyProjects(from: data) else {
            return Bootstrap(result: .missing,
                             legacyProblem: "以前の \(legacyProjectsURL.path) を読めないため取り込んでいません（JSON の配列ではありません）。projects.json は書き換えずに残しています")
        }
        let settings = DeckSettings(projects: projects)
        do {
            try save(settings)
            return Bootstrap(result: .loaded(settings))
        } catch {
            return Bootstrap(result: .loaded(settings),
                             saveFailure: "\(url.path) に書けませんでした。以前の projects.json から読んだ内容を表示しています（projects.json は残しています）")
        }
    }

    /// 以前の版の `projects.json`（`[{name, path, status, note}]`）を読む。古い GitHub のキーは捨てる。
    static func legacyProjects(from data: Data) -> [ManagedProject]? {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        return array.compactMap { item in
            guard let name = item["name"] as? String, let raw = item["path"] as? String,
                  !name.isEmpty, raw.hasPrefix("/") else { return nil }
            let path = (raw as NSString).standardizingPath
            guard seen.insert(path).inserted else { return nil }
            return ManagedProject(name: name, path: path, status: .lenient(item["status"] as? String ?? ""),
                                  note: item["note"] as? String ?? "")
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return "\(error)" }
        switch error {
        case .keyNotFound(let key, let ctx): return "\(path(ctx.codingPath + [key])) がありません"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return "\(path(ctx.codingPath)) の値が正しくありません"
        @unknown default: return "\(error)"
        }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
    }
}
