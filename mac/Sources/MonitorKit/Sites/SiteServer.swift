import Foundation
import Network

/// 静的書き出しの配信の口（GET / HEAD だけ）。書き出しのフォルダの外・隠しファイルは返さない。
public enum SiteServerRoutes {
    /// 1 回の応答で読む上限（メモリに読み込んで返すため。これより大きいファイルは範囲指定でだけ返す）。
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
            response = file(path, status: 200, range: request.header("range"), head: head)
        case .redirect(let location):
            if let query = request.query, query.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                // 転送先の見出しに改行等を混ぜて別の見出しを差し込ませない。
                response = text(400, "bad request")
            } else {
                let target = request.query.map { "\(location)?\($0)" } ?? location
                response = HTTPResponse(status: 308, headers: [("Location", target), ("Cache-Control", "no-store")])
            }
        case .forbidden:
            response = text(403, "forbidden")
        case .notFound:
            if let page = SiteFiles.notFoundPage(root: root) {
                response = file(page, status: 404, head: head)
            } else {
                response = text(404, FileManager.default.fileExists(atPath: root) ? "not found" : "書き出し（out/）がありません")
            }
        }
        response.omitsBody = head
        return response
    }

    /// `Range` の読み取り結果。
    enum ByteRange: Equatable {
        /// bytes 以外の単位（無視して全体を返す）。
        case ignored
        case unsatisfiable
        case range(Range<Int>)
    }

    /// 単一範囲（`bytes=a-b` / `bytes=a-` / `bytes=-n`）だけを受ける。
    static func byteRange(_ header: String, size: Int) -> ByteRange {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes=") else { return .ignored }
        let spec = value.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard let dash = spec.firstIndex(of: "-") else { return .unsatisfiable }
        let first = String(spec[..<dash]), last = String(spec[spec.index(after: dash)...])
        let digits = { (s: String) in s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }
        guard digits(first), digits(last), !(first.isEmpty && last.isEmpty) else { return .unsatisfiable }
        if first.isEmpty {
            guard let suffix = Int(last), suffix > 0, size > 0 else { return .unsatisfiable }
            return .range(max(0, size - suffix)..<size)
        }
        guard let start = Int(first), start < size else { return .unsatisfiable }
        if last.isEmpty { return .range(start..<size) }
        guard let end = Int(last), end >= start else { return .unsatisfiable }
        return .range(start..<min(end, size - 1) + 1)
    }

    static func file(_ path: String, status: Int, range: String? = nil, head: Bool = false) -> HTTPResponse {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int else { return text(404, "not found") }
        // 書き出しは作り直されるので、毎回取り直させる。
        var headers = [("Content-Type", SiteFiles.contentType(for: path)), ("Cache-Control", "no-cache"),
                       ("X-Content-Type-Options", "nosniff")]
        var status = status
        var span = 0..<size
        if status == 200 {
            headers.append(("Accept-Ranges", "bytes"))
            switch range.map({ byteRange($0, size: size) }) ?? .ignored {
            case .ignored:
                guard size <= maxFileBytes else { return text(413, "file too large") }
            case .unsatisfiable:
                var response = text(416, "range not satisfiable")
                response.headers.append(("Content-Range", "bytes */\(size)"))
                return response
            case .range(let requested):
                // 動画等の大きいファイルも範囲ごとなら返せるよう、1 回分だけを上限に収める。
                span = requested.lowerBound..<min(requested.upperBound, requested.lowerBound + maxFileBytes)
                status = 206
                headers.append(("Content-Range", "bytes \(span.lowerBound)-\(span.upperBound - 1)/\(size)"))
            }
        } else if size > maxFileBytes {
            return text(413, "file too large")
        }
        if head {
            var response = HTTPResponse(status: status, headers: headers)
            response.omitsBody = true
            response.declaredLength = span.count
            return response
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return text(404, "not found") }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(span.lowerBound))) != nil,
              let data = try? handle.read(upToCount: span.count) ?? Data(), data.count == span.count else {
            return text(404, "not found")
        }
        return HTTPResponse(status: status, headers: headers, body: data)
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
        let task = Task { [weak self] in
            try await Self.open(server) { [weak self] in Task { await self?.dropped(key, server: server) } }
        }
        opening[key] = task
        return try await baseURL(for: key)
    }

    /// 待ち受けが後から落ちたら外し、次に頼まれた時に開き直す。
    private func dropped(_ key: String, server: HTTPServer) {
        guard servers[key] === server else { return }
        servers[key] = nil
        opening[key] = nil
    }

    private static func open(_ server: HTTPServer, onLost: @escaping @Sendable () -> Void) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            server.start(port: 0) { state in
                switch state {
                case .listening(let port):
                    if once.claim() { continuation.resume(returning: port) }
                case .failed(let reason):
                    if once.claim() { continuation.resume(throwing: Failure.failed(reason)) } else { onLost() }
                case .portInUse:
                    if once.claim() { continuation.resume(throwing: Failure.failed("ポートを取れませんでした")) } else { onLost() }
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
