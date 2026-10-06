import Network
import XCTest
@testable import MonitorKit

/// 書き出しの配信。ループバックの OS が選ぶポートで立て、実際に取得・拒否を確かめる。
final class SiteServerTests: XCTestCase {
    var dir: URL!
    var root: String { dir.appendingPathComponent("site/out").path }
    var servers: SitePreviewServers!
    var base: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("site-server-\(UUID().uuidString)")
        try write("index.html", "<h1>top</h1>")
        try write("ja/index.html", "<h1>ja</h1>")
        try write("about.html", "<h1>about</h1>")
        try write("_next/static/app.js", "console.log(1)")
        try write("_next/static/style.css", "body{}")
        try write("404.html", "<h1>missing</h1>")
        try write("img/logo.svg", "<svg/>")
        try write(".env", "SECRET=1")
        try write("noindex/readme.txt", "x")
        // Next.js の既定（trailingSlash: false）の形。
        try write("blog.html", "<h1>blog</h1>")
        try write("blog/first.html", "<h1>first</h1>")
        try write(".git/config", "SECRET-GIT")
        // 書き出しの外（読ませてはいけないもの）。
        try write("../secret.txt", "secret")
        try write("../../outside.txt", "outside")
        try FileManager.default.createSymbolicLink(atPath: root + "/leak.txt", withDestinationPath: dir.appendingPathComponent("outside.txt").path)
        try FileManager.default.createSymbolicLink(atPath: root + "/up", withDestinationPath: dir.path)
        try FileManager.default.createSymbolicLink(atPath: root + "/inner.js", withDestinationPath: root + "/_next/static/app.js")
        try FileManager.default.createSymbolicLink(atPath: root + "/env.txt", withDestinationPath: root + "/.env")
        try FileManager.default.createSymbolicLink(atPath: root + "/repo", withDestinationPath: root + "/.git")
        servers = SitePreviewServers()
        base = try await servers.baseURL(for: root)
    }

    override func tearDown() async throws {
        await servers?.stopAll()
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ relative: String, _ text: String) throws {
        let path = ((root as NSString).appendingPathComponent(relative) as NSString).standardizingPath
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func get(_ path: String, method: String = "GET", host: String? = nil) async throws -> (Int, String, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = method
        if let host { request.setValue(host, forHTTPHeaderField: "Host") }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        return (http.statusCode, String(decoding: data, as: UTF8.self), http)
    }

    func testListensOnLoopbackWithRandomPort() async throws {
        XCTAssertEqual(base.host, "127.0.0.1")
        XCTAssertNotEqual(base.port, 8766)
        XCTAssertNotEqual(base.port, 8767)
        let again = try await servers.baseURL(for: root)
        XCTAssertEqual(again, base, "同じサイトは使い回す")
        let other = dir.appendingPathComponent("other").path
        let otherBase = try await servers.baseURL(for: other)
        XCTAssertNotEqual(otherBase.port, base.port, "サイトごとに別のオリジン")
    }

    func testServesFilesWithContentTypes() async throws {
        var (status, body, response) = try await get("/")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, "<h1>top</h1>")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
        (status, body, response) = try await get("/_next/static/app.js")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/javascript; charset=utf-8")
        (status, _, response) = try await get("/_next/static/style.css")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/css; charset=utf-8")
        (status, _, response) = try await get("/img/logo.svg")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "image/svg+xml")
        (status, body, _) = try await get("/inner.js")
        XCTAssertEqual(status, 200, "書き出しの中を指すリンクは返す")
        XCTAssertEqual(body, "console.log(1)")
    }

    func testDirectoriesAndExtensionlessPaths() async throws {
        var (status, body, response) = try await get("/ja/")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, "<h1>ja</h1>")
        (status, _, response) = try await get("/ja?x=1")
        XCTAssertEqual(status, 308)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Location"), "/ja/?x=1")
        (status, body, _) = try await get("/about")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, "<h1>about</h1>")
        (status, body, _) = try await get("/noindex/")
        XCTAssertEqual(status, 404, "index.html の無いフォルダは一覧を出さない")
        XCTAssertEqual(body, "<h1>missing</h1>")
    }

    func testFlatHTMLBesideFolderWithoutIndex() async throws {
        var (status, body, _) = try await get("/blog")
        XCTAssertEqual(status, 200, "blog.html と blog/ が並ぶ時は転送せずに blog.html")
        XCTAssertEqual(body, "<h1>blog</h1>")
        (status, body, _) = try await get("/blog/first")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, "<h1>first</h1>")
        (status, body, _) = try await get("/blog/")
        XCTAssertEqual(status, 404)
        XCTAssertEqual(body, "<h1>missing</h1>")
    }

    func testRangeRequests() async throws {
        func fetch(_ range: String, method: String = "GET") async throws -> (Int, String, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "/", relativeTo: base)!)
            request.httpMethod = method
            request.setValue(range, forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            let http = response as! HTTPURLResponse
            return (http.statusCode, String(decoding: data, as: UTF8.self), http)
        }
        // index.html は "<h1>top</h1>"（12 バイト）。
        var (status, body, response) = try await fetch("bytes=4-6")
        XCTAssertEqual(status, 206)
        XCTAssertEqual(body, "top")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 4-6/12")
        (status, body, _) = try await fetch("bytes=-4")
        XCTAssertEqual(body, "/h1>")
        (status, body, response) = try await fetch("bytes=8-100")
        XCTAssertEqual(status, 206)
        XCTAssertEqual(body, "/h1>")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 8-11/12")
        for bad in ["bytes=12-", "bytes=5-2", "bytes=0-1,4-5", "bytes=abc", "bytes=-0", "bytes=+1-2"] {
            (status, _, response) = try await fetch(bad)
            XCTAssertEqual(status, 416, bad)
            XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes */12", bad)
        }
        (status, body, response) = try await fetch("items=0-1")
        XCTAssertEqual(status, 200, "bytes 以外の単位は無視して全体を返す")
        XCTAssertEqual(body, "<h1>top</h1>")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        (status, body, response) = try await fetch("bytes=0-3", method: "HEAD")
        XCTAssertEqual(status, 206)
        XCTAssertEqual(body, "")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), "4")
    }

    func testRedirectQueryWithControlCharactersIsRejected() async throws {
        for query in ["x\r\nSet-Cookie: a=1", "a\nb", "a\u{7F}"] {
            let response = await SiteServerRoutes.handle(HTTPRequest(method: "GET", path: "/ja", query: query), root: root)
            XCTAssertEqual(response.status, 400, query)
            XCTAssertFalse(response.headers.contains { $0.0 == "Location" }, query)
        }
        let ok = await SiteServerRoutes.handle(HTTPRequest(method: "GET", path: "/ja", query: "a=%0d%0a"), root: root)
        XCTAssertEqual(ok.status, 308)
        XCTAssertTrue(ok.headers.contains { $0.0 == "Location" && $0.1 == "/ja/?a=%0d%0a" })
    }

    func testNotFoundUsesExported404() async throws {
        let (status, body, response) = try await get("/nope/page")
        XCTAssertEqual(status, 404)
        XCTAssertEqual(body, "<h1>missing</h1>")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
    }

    func testRefusesOutsideAndHiddenFiles() async throws {
        for path in ["/../secret.txt", "/%2e%2e/secret.txt", "/ja/%2E%2E/%2E%2E/secret.txt", "/..%2fsecret.txt",
                     "/leak.txt", "/up/secret.txt", "/up/outside.txt", "/.env", "/%2eenv", "/ja/..%5c..%5csecret.txt",
                     "/env.txt", "/repo/config", "/.git/config"] {
            let (status, body, _) = try await get(path)
            XCTAssertTrue([403, 404].contains(status), "\(path): \(status)")
            XCTAssertFalse(body.contains("secret") || body.contains("outside") || body.contains("SECRET"), path)
        }
    }

    func testRawTraversalOverSocketIsRefused() async throws {
        // URLSession は `..` を詰めてしまうので、生の要求でも確かめる。
        for target in ["/../secret.txt", "/ja/../../secret.txt", "/%2e%2e/%2e%2e/outside.txt", "//etc/passwd"] {
            let response = try await raw("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(base.port!)\r\n\r\n")
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 403") || response.hasPrefix("HTTP/1.1 404"), "\(target): \(response.prefix(40))")
            XCTAssertFalse(response.contains("secret\n") || response.contains("outside") || response.contains("root:"), target)
        }
    }

    func testOnlyGetAndHead() async throws {
        let (status, body, response) = try await get("/", method: "HEAD")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, "")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), "12")
        let (post, _, allow) = try await get("/", method: "POST")
        XCTAssertEqual(post, 405)
        XCTAssertEqual(allow.value(forHTTPHeaderField: "Allow"), "GET, HEAD")
        let (delete, _, _) = try await get("/index.html", method: "DELETE")
        XCTAssertEqual(delete, 405)
    }

    func testHostMustBeLoopbackWithOwnPort() async throws {
        let port = base.port!
        var response = try await raw("GET / HTTP/1.1\r\nHost: localhost:\(port)\r\n\r\n")
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), response)
        for host in ["evil.example:\(port)", "127.0.0.1", "127.0.0.1:1", "[::1]:\(port)", "localhost.evil.example:\(port)"] {
            response = try await raw("GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 403"), "\(host): \(response.prefix(40))")
        }
        response = try await raw("GET / HTTP/1.1\r\n\r\n")
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 403"), "Host が無いものは塞ぐ")
    }

    func testMissingExportIsReported() async throws {
        try FileManager.default.removeItem(atPath: root)
        let (status, body, _) = try await get("/")
        XCTAssertEqual(status, 404)
        XCTAssertTrue(body.contains("out/"))
    }

    /// 生の HTTP を送って応答を全部読む。
    private func raw(_ text: String) async throws -> String {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(base.port!))!, using: .tcp)
        let queue = DispatchQueue(label: "site-server-test")
        connection.start(queue: queue)
        defer { connection.cancel() }
        connection.send(content: Data(text.utf8), completion: .idempotent)
        var received = Data()
        while true {
            let (data, done): (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, isComplete)) }
                }
            }
            if let data { received.append(data) }
            if done || data == nil { break }
        }
        return String(decoding: received, as: UTF8.self)
    }
}

/// 転送を自分で確かめるため、追わない。
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

final class SiteFilesTests: XCTestCase {
    func testContentTypes() {
        XCTAssertEqual(SiteFiles.contentType(for: "/a/index.html"), "text/html; charset=utf-8")
        XCTAssertEqual(SiteFiles.contentType(for: "a.WOFF2"), "font/woff2")
        XCTAssertEqual(SiteFiles.contentType(for: "a.webp"), "image/webp")
        XCTAssertEqual(SiteFiles.contentType(for: "index.txt"), "text/plain; charset=utf-8")
        XCTAssertEqual(SiteFiles.contentType(for: "noext"), "application/octet-stream")
    }

    func testRedirectLocationCannotBecomeProtocolRelative() {
        XCTAssertEqual(SiteFiles.location(["evil.example"]), "/evil.example")
        XCTAssertEqual(SiteFiles.location(["a b", "c?d"]), "/a%20b/c%3Fd")
    }

    func testByteRangeParsing() {
        XCTAssertEqual(SiteServerRoutes.byteRange("bytes=0-0", size: 10), .range(0..<1))
        XCTAssertEqual(SiteServerRoutes.byteRange("bytes=3-", size: 10), .range(3..<10))
        XCTAssertEqual(SiteServerRoutes.byteRange("bytes=-20", size: 10), .range(0..<10))
        XCTAssertEqual(SiteServerRoutes.byteRange(" Bytes=2-4 ", size: 10), .range(2..<5))
        XCTAssertEqual(SiteServerRoutes.byteRange("bytes=0-", size: 0), .unsatisfiable)
        XCTAssertEqual(SiteServerRoutes.byteRange("bytes=-", size: 10), .unsatisfiable)
        XCTAssertEqual(SiteServerRoutes.byteRange("bytes=99999999999999999999-", size: 10), .unsatisfiable)
        XCTAssertEqual(SiteServerRoutes.byteRange("none", size: 10), .ignored)
    }

    func testRejectsMalformedPaths() {
        XCTAssertEqual(SiteFiles.resolve(urlPath: "index.html", root: "/tmp"), .forbidden)
        XCTAssertEqual(SiteFiles.resolve(urlPath: "/a%00b", root: "/tmp"), .forbidden)
        XCTAssertEqual(SiteFiles.resolve(urlPath: "/%zz", root: "/tmp"), .forbidden)
    }
}

final class SiteViewportTests: XCTestCase {
    func testScalesDownToFitWidth() {
        let layout = SiteViewport.desktop.layout(available: 640, maxHeight: 2000)
        XCTAssertEqual(layout.scale, 0.5, accuracy: 0.0001)
        XCTAssertEqual(layout.frameWidth, 640)
        XCTAssertEqual(layout.frameHeight, 400)
    }

    func testNeverScalesUp() {
        let layout = SiteViewport.phone.layout(available: 1000, maxHeight: 5000)
        XCTAssertEqual(layout.scale, 1)
        XCTAssertEqual(layout.frameWidth, 390)
    }

    func testFitsHeightAndLeavesRoomForBezel() {
        let layout = SiteViewport.phone.layout(available: 1000, maxHeight: 442)
        // 枠の 10pt ずつを除いた 422 に 844 の高さを収める。
        XCTAssertEqual(layout.scale, 0.5, accuracy: 0.0001)
        XCTAssertEqual(layout.frameHeight, 422)
        XCTAssertEqual(SiteViewport.allCases.map(\.width), [1280, 820, 390])
    }

    func testThumbnailNamesChangeWithModificationTime() {
        let a = SiteThumbnails.fileName(exportDir: "/p/site/out", modified: Date(timeIntervalSince1970: 100))
        let b = SiteThumbnails.fileName(exportDir: "/p/site/out", modified: Date(timeIntervalSince1970: 200))
        let other = SiteThumbnails.fileName(exportDir: "/q/site/out", modified: Date(timeIntervalSince1970: 100))
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, other)
        XCTAssertEqual(SiteThumbnails.fileName(exportDir: "/p/site/out/", modified: Date(timeIntervalSince1970: 100)), a)
        XCTAssertEqual(SiteThumbnails.stale(in: [a, b, other, "x.png"], exportDir: "/p/site/out", keep: b), [a])
        XCTAssertTrue(SiteThumbnails.directory.path.hasSuffix("Caches/claude-deck/site-thumbs"))
    }
}

final class SiteNavigationPolicyTests: XCTestCase {
    func testAllowsWebAndRefusesLocalOrScript() {
        for ok in ["http://127.0.0.1:5000/", "https://apps.apple.com/app/x", "about:blank", "blob:https://a.example/x"] {
            XCTAssertTrue(SiteNavigationPolicy.allows(URL(string: ok), mainFrame: true), ok)
        }
        for bad in ["file:///etc/hosts", "javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,<b>x</b>",
                    "claude-deck://pair?x=1", "ftp://example.com/"] {
            XCTAssertFalse(SiteNavigationPolicy.allows(URL(string: bad), mainFrame: true), bad)
        }
        XCTAssertTrue(SiteNavigationPolicy.allows(URL(string: "data:image/png;base64,AA=="), mainFrame: false))
        XCTAssertFalse(SiteNavigationPolicy.allows(URL(string: "file:///etc/hosts"), mainFrame: false))
        XCTAssertFalse(SiteNavigationPolicy.allows(nil, mainFrame: true))
    }

    func testBrowserURLOnlyWeb() {
        XCTAssertNotNil(SiteNavigationPolicy.browserURL(URL(string: "http://127.0.0.1:5000/ja/")))
        XCTAssertNil(SiteNavigationPolicy.browserURL(URL(string: "about:blank")))
        XCTAssertNil(SiteNavigationPolicy.browserURL(URL(string: "file:///tmp/x.html")))
        XCTAssertNil(SiteNavigationPolicy.browserURL(nil))
    }
}
