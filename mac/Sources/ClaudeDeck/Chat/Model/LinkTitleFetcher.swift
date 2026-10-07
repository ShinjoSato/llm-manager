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
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("claude-deck", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            var data = Data()
            var sinceCheck = 0
            for try await byte in bytes {
                data.append(byte)
                sinceCheck += 1
                if data.count >= LinkTitle.maxBytes { break }
                // 題名が読めたら残りは要らない（長いページを 3 秒いっぱい読まない）。
                if sinceCheck >= 4096 {
                    sinceCheck = 0
                    try Task.checkCancellation()
                    if data.range(of: Data("</title".utf8), options: .backwards) != nil { break }
                }
            }
            return LinkTitle.parse(data)
        } catch {
            return nil
        }
    }
}
