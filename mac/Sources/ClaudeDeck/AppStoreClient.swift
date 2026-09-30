import Foundation

// MARK: - ドメイン型（server の AppRecord に対応する最小サブセット）

/// バージョンの審査ステータス（appStoreVersions）。
struct AppStoreVersion {
    let version: String
    let platform: String
    let state: String
    let stateLabel: String
    let createdDate: String
}

/// 審査提出フロー（reviewSubmissions）の1件。
struct AppStoreSubmission {
    let state: String
    let stateLabel: String
    let platform: String
    let submittedDate: String
}

/// TestFlight ビルド（builds）の1件。
struct AppStoreBuild {
    let build: String
    let state: String
    let stateLabel: String
    let expired: Bool
    let uploadedDate: String
}

/// カスタマーレビュー集計（reviews）。
struct AppStoreReviews {
    let total: Int?
    let avgOfRecent: Double?
    let itemCount: Int
}

/// 1アプリ分の App Store 状況（server の AppRecord 相当）。
/// 取得に失敗したアプリは `error` のみが入る（他フィールドは空）。
struct AppStoreRecord {
    let appName: String
    let appId: String
    let bundleId: String
    let versions: [AppStoreVersion]
    let submissions: [AppStoreSubmission]
    let builds: [AppStoreBuild]
    let reviews: AppStoreReviews?
    let metricCategories: [String]
    /// server 側で各アプリ単位の取得に失敗したときのメッセージ。
    let error: String?
}

enum AppStoreError: Error {
    /// HTTP 取得や接続に失敗（server 未起動を含む）。
    case fetchFailed(String)
    /// 応答 JSON の解析に失敗。
    case parseFailed
    /// 認証未設定などで server が空（{}）を返した。
    case empty
}

/// `projects/appstore.tsv` の読み込みと、server HTTP API（`/api/appstore`）の取得。
///
/// 設計方針:
///  - ASC API は Swift で直接叩かない。ロジックは server に一本化済みなので
///    既存 HTTP API を fetch するだけにする（二重実装を避ける）。
///  - server 未起動・エラー時は安全にフォールバック（エラーを返すだけでアプリは落とさない）。
enum AppStoreClient {

    /// server のベース URL。環境変数で差し替え可能（既定は localhost:8765）。
    static var baseURL: String {
        ProcessInfo.processInfo.environment["CLAUDE_DECK_API_BASE"] ?? "http://localhost:8765"
    }

    // MARK: - appstore.tsv（表示対象の判定）

    private static func tsvURL() -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["CLAUDE_DECK_APPSTORE_TSV"],
           fm.fileExists(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("projects/appstore.tsv")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        let fallback = "/Users/shinjo/project/ai-manager/projects/appstore.tsv"
        return fm.fileExists(atPath: fallback) ? URL(fileURLWithPath: fallback) : nil
    }

    /// `appstore.tsv` に載っているプロジェクト名の集合を返す。
    /// github-projects.tsv と同様、ここに載っているプロジェクトのペインにだけ App Store 表示を出す。
    static func registeredNames() -> Set<String> {
        guard let url = tsvURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var names: Set<String> = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let c = rawLine.components(separatedBy: "\t")
            guard let first = c.first else { continue }
            let name = first.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.insert(name) }
        }
        return names
    }

    /// 指定プロジェクトが App Store 表示の対象か（= appstore.tsv に登録があるか）。
    static func isRegistered(projectNamed name: String) -> Bool {
        registeredNames().contains(name)
    }

    // MARK: - 取得（HTTP）

    /// `GET /api/appstore/:name` を叩いて指定プロジェクトの App Store 状況を取得する。
    /// server 側は個別 name 指定でも `{ name: record }` の形（Record）で返すため、そこから取り出す。
    static func fetch(projectNamed name: String,
                      on queue: DispatchQueue = .main,
                      completion: @escaping (Result<AppStoreRecord, AppStoreError>) -> Void) {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        guard let url = URL(string: "\(baseURL)/api/appstore/\(encoded)") else {
            queue.async { completion(.failure(.fetchFailed("URL を構築できません"))) }
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                let ns = error as NSError
                // 接続拒否（server 未起動）は分かりやすい文言にする。
                let msg = (ns.code == NSURLErrorCannotConnectToHost || ns.code == NSURLErrorCannotFindHost)
                    ? "server (:8765) に接続できません。`./scripts/dev.sh` 等で起動してください。"
                    : error.localizedDescription
                queue.async { completion(.failure(.fetchFailed(msg))) }
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                queue.async { completion(.failure(.fetchFailed("HTTP \(http.statusCode)"))) }
                return
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                queue.async { completion(.failure(.parseFailed)) }
                return
            }
            // 認証未設定だと server は {} を返す。
            if obj.isEmpty {
                queue.async { completion(.failure(.empty)) }
                return
            }
            // {name: record} から該当アプリを取り出す（name 一致が無ければ最初の1件）。
            guard let recObj = (obj[name] as? [String: Any]) ?? obj.values.first as? [String: Any] else {
                queue.async { completion(.failure(.parseFailed)) }
                return
            }
            queue.async { completion(.success(parseRecord(recObj))) }
        }
        task.resume()
    }

    // MARK: - パース

    private static func parseRecord(_ o: [String: Any]) -> AppStoreRecord {
        let versions = (o["versions"] as? [[String: Any]] ?? []).map { v in
            AppStoreVersion(
                version: v["version"] as? String ?? "",
                platform: v["platform"] as? String ?? "",
                state: v["state"] as? String ?? "",
                stateLabel: v["stateLabel"] as? String ?? (v["state"] as? String ?? ""),
                createdDate: v["createdDate"] as? String ?? "")
        }
        let submissions = (o["reviewSubmissions"] as? [[String: Any]] ?? []).map { s in
            AppStoreSubmission(
                state: s["state"] as? String ?? "",
                stateLabel: s["stateLabel"] as? String ?? (s["state"] as? String ?? ""),
                platform: s["platform"] as? String ?? "",
                submittedDate: s["submittedDate"] as? String ?? "")
        }
        let builds = (o["builds"] as? [[String: Any]] ?? []).map { b in
            AppStoreBuild(
                build: b["build"] as? String ?? "",
                state: b["state"] as? String ?? "",
                stateLabel: b["stateLabel"] as? String ?? (b["state"] as? String ?? ""),
                expired: b["expired"] as? Bool ?? false,
                uploadedDate: b["uploadedDate"] as? String ?? "")
        }
        var reviews: AppStoreReviews? = nil
        if let r = o["reviews"] as? [String: Any] {
            reviews = AppStoreReviews(
                total: r["total"] as? Int,
                avgOfRecent: (r["avgOfRecent"] as? NSNumber)?.doubleValue,
                itemCount: (r["items"] as? [Any])?.count ?? 0)
        }
        let cats = ((o["metrics"] as? [String: Any])?["categories"] as? [[String: Any]] ?? [])
            .compactMap { $0["category"] as? String }

        return AppStoreRecord(
            appName: o["appName"] as? String ?? "",
            appId: o["appId"] as? String ?? "",
            bundleId: o["bundleId"] as? String ?? "",
            versions: versions,
            submissions: submissions,
            builds: builds,
            reviews: reviews,
            metricCategories: cats,
            error: o["error"] as? String)
    }
}
