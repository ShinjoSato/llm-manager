import Foundation

/// DNS リバインディング対策（攻撃者のドメインを 127.0.0.1 に向けても Host は攻撃者のもの）と接続元の判定。
public enum LoopbackGuard {
    /// ループバックを指すホスト名。これ以外は外部のドメイン。
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]"]

    /// URL から取り出したホスト名（小文字）がループバックか。IPv6 は括弧の有無を問わない。
    static func isLoopbackHostName(_ host: String) -> Bool {
        loopbackHosts.contains(host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host)
    }

    /// `host:port` をホストとポートに割る。`[::1]:8766` のブラケット形式も扱う。
    public static func splitHostPort(_ value: String) -> (host: String, port: String) {
        if value.hasPrefix("[") {
            guard let end = value.firstIndex(of: "]") else { return (value, "") }
            let after = value.index(after: end)
            if after < value.endIndex && value[after] != ":" { return (value, "") }
            let host = String(value[...end])
            let port = after < value.endIndex ? String(value[value.index(after: after)...]) : ""
            return (host, port)
        }
        guard let sep = value.lastIndex(of: ":") else { return (value, "") }
        return (String(value[..<sep]), String(value[value.index(after: sep)...]))
    }

    public static func isAllowedHost(_ value: String?, port: Int) -> Bool {
        guard let value, !value.isEmpty else { return false } // Host 無し（HTTP/1.0 等）は塞ぐ側に倒す。
        let (host, hostPort) = splitHostPort(value.lowercased()) // ホスト名は大文字小文字を区別しない
        guard loopbackHosts.contains(host) else { return false }
        // 既定ポート(80)で待つ時だけクライアントがポートを省く。
        return hostPort == String(port) || (hostPort.isEmpty && port == 80)
    }

    public static func isAllowedOrigin(_ value: String, port: Int) -> Bool {
        // Origin: null（sandbox iframe 等）や壊れた値はここで弾かれる。
        guard let url = URLComponents(string: value), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        // 画面を持たないので、自分自身（手元の同じポート）のページ以外から来る理由が無い。
        guard scheme == "http", isLoopbackHostName(host) else { return false }
        if let p = url.port { return p == port }
        return port == 80
    }

    /// 接続元が手元かどうか。Host は詐称できるのでソケットのアドレスで判定する。
    public static func isLoopbackAddress(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        let addr = value.hasPrefix("::ffff:") ? String(value.dropFirst("::ffff:".count)) : value // IPv4 射影アドレス
        if addr == "::1" { return true }
        let parts = addr.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.dropFirst().allSatisfy { (1...3).contains($0.count) && $0.allSatisfy(\.isASCIIDigit) }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
