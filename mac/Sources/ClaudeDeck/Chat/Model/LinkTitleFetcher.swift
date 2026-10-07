import Foundation
import MonitorKit

/// リンクの名前の候補にするページの `<title>` の取得。http / https だけ・3 秒・資格情報なし・本文は先頭 256KB まで。取れなければ nil。
enum LinkTitleFetcher {
    static func title(for text: String) async -> String? {
        guard let url = ProjectLinks.url(from: text) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("claude-deck", forHTTPHeaderField: "User-Agent")
        var data = Data()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            var sinceCheck = 0
            var closing = false
            for try await byte in bytes {
                data.append(byte)
                sinceCheck += 1
                if data.count >= LinkTitle.maxBytes { break }
                // 閉じタグが見えたら `>` まで読み足して止める（長いページを 3 秒いっぱい読まない）。
                if closing {
                    if byte == UInt8(ascii: ">") { break }
                    continue
                }
                if sinceCheck >= 4096 {
                    sinceCheck = 0
                    try Task.checkCancellation()
                    if Self.hasClosingTitle(data) { closing = true }
                }
            }
            return LinkTitle.parse(data)
        } catch {
            // 途中で時間切れでも、読めた分に題名があれば使う。
            return Task.isCancelled ? nil : LinkTitle.parse(data)
        }
    }

    private static func hasClosingTitle(_ data: Data) -> Bool {
        let tail = data.suffix(4096 + 8)
        return tail.range(of: Data("</title".utf8)) != nil || tail.range(of: Data("</TITLE".utf8)) != nil
    }
}
