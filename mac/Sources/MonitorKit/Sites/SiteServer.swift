import Foundation
import Network

/// 静的書き出しの配信の口（GET / HEAD だけ）。書き出しのフォルダの外・隠しファイルは返さない。
public enum SiteServerRoutes {
    /// これより大きいファイルは返さない（メモリに読み込んで返すため）。
    public static let maxFileBytes = 64 * 1024 * 1024

    /// Host は 127.0.0.1 / localhost の自分のポートだけ（DNS リバインディングで別のサイトから読ませない）。接続元もループバックだけ。
    public static func rejection(_ request: HTTPRequest, port: Int) -> HTTPResponse? {
        guard isAllowedHost(request.header("host"), port: port) else { return text(403, "invalid host header") }
        guard LoopbackGuard.isLoopbackAddress(request.remoteAddress) else { return text(404, "not found") }
        return nil
    }

    static func isAllowedHost(_ value: String?, port: Int) -> Bool {
        guard let value, !value.isEmpty else { return false }
        let (host, hostPort) = LoopbackGuard.splitHostPort(value.lowercased())
        return (host == "127.0.0.1" || host == "localhost") && hostPort == String(port)
    }

    public static func handle(_ request: HTTPRequest, root: String) async -> HTTPResponse {
        let head = request.method == "HEAD"
        guard request.method == "GET" || head else {
            var response = text(405, "method not allowed")
            response.headers.append(("Allow", "GET, HEAD"))
            return response
        }
        var response: HTTPResponse
        switch SiteFiles.resolve(urlPath: request.path, root: root) {
        case .file(let path):
            response = file(path, status: 200)
        case .redirect(let location):
            let target = request.query.map { "\(location)?\($0)" } ?? location
            response = HTTPResponse(status: 308, headers: [("Location", target), ("Cache-Control", "no-store")])
        case .forbidden:
            response = text(403, "forbidden")
        case .notFound:
            if let page = SiteFiles.notFoundPage(root: root) {
                response = file(page, status: 404)
            } else {
                response = text(404, FileManager.default.fileExists(atPath: root) ? "not found" : "書き出し（out/）がありません")
            }
        }
        response.omitsBody = head
        return response
    }

    static func file(_ path: String, status: Int) -> HTTPResponse {
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        guard size <= maxFileBytes else { return text(413, "file too large") }
        guard let data = FileManager.default.contents(atPath: path) else { return text(404, "not found") }
        // 書き出しは作り直されるので、毎回取り直させる。
        return HTTPResponse(status: status,
                            headers: [("Content-Type", SiteFiles.contentType(for: path)), ("Cache-Control", "no-cache"),
                                      ("X-Content-Type-Options", "nosniff")],
                            body: data)
    }

    static func text(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status,
                     headers: [("Content-Type", "text/plain; charset=utf-8"), ("Cache-Control", "no-store"),
                               ("X-Content-Type-Options", "nosniff")],
                     body: Data(message.utf8))
    }
}

/// サイトごとの配信。書き出しは `/_next/...` の絶対パスで参照し合うので、サイトごとに 127.0.0.1 の別のポート（＝別のオリジン）で立てる。
public actor SitePreviewServers {
    public static let shared = SitePreviewServers()

    public enum Failure: Error, Equatable {
        case failed(String)
    }

    private var servers: [String: HTTPServer] = [:]
    /// 開き始めた分（同時に頼まれても 1 回だけ開く）。
    private var opening: [String: Task<Int, Error>] = [:]

    public init() {}

    /// 書き出しのフォルダを配信するトップの URL（`http://127.0.0.1:<port>/`）。
    public func baseURL(for exportDir: String) async throws -> URL {
        let key = (exportDir as NSString).standardizingPath
        if let task = opening[key] {
            do {
                return Self.url(port: try await task.value)
            } catch {
                // 開けなかった分は次に頼まれた時に開き直す。
                if opening[key] == task { opening[key] = nil; servers[key] = nil }
                throw error
            }
        }
        let options = HTTPServerOptions(maxConnections: 32, maxBodyBytes: 0,
                                        rejection: { SiteServerRoutes.rejection($0, port: $1) })
        let server = HTTPServer(options: options) { request in await SiteServerRoutes.handle(request, root: key) }
        servers[key] = server
        let task = Task { try await Self.open(server) }
        opening[key] = task
        return try await baseURL(for: key)
    }

    private static func open(_ server: HTTPServer) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            server.start(port: 0) { state in
                switch state {
                case .listening(let port):
                    if once.claim() { continuation.resume(returning: port) }
                case .failed(let reason):
                    if once.claim() { continuation.resume(throwing: Failure.failed(reason)) }
                case .portInUse:
                    if once.claim() { continuation.resume(throwing: Failure.failed("ポートを取れませんでした")) }
                default:
                    break
                }
            }
        }
    }

    /// 全部閉じる（試験用）。
    public func stopAll() async {
        let all = Array(servers.values)
        servers = [:]
        opening = [:]
        for server in all { await server.stopAndWait() }
    }

    static func url(port: Int) -> URL { URL(string: "http://127.0.0.1:\(port)/")! }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool { lock.withLock { defer { used = true }; return !used } }
}
