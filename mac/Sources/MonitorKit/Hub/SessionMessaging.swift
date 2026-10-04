import Foundation

/// セッションの受信箱ソケットへテキストを投稿する（移植元: 旧 monitor（削除済み）の src/messaging.ts）。
/// 公式に文書化された経路（cross-session messaging の inbox socket）で、行区切りの JSON を書く。
/// 届いたテキストは「別セッションからのメッセージ」として扱われ、本人の指示・権限承認にはならない。
public enum SessionMessaging {
    /// 無通信がこれだけ続いたら諦める。受信側は 30 秒で切る。
    static let idleTimeout: TimeInterval = 5
    /// 相手が読み続けても待ち続けないための全体の締め切り。
    static let totalTimeout: TimeInterval = 15

    /// 自分が所有する Unix ソケットか。lstat なのでシンボリックリンクは通らず、他人が仕掛けた口に書き込まない。
    public static func isOwnSocket(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK && st.st_uid == getuid()
    }

    /// レジストリに socket パスが無い場合の既定位置。パスが長すぎる場合だけ `cc-socks-<uid>/` に退避する。
    public static func defaultSocketPath(pid: Int32, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let runtime = environment["XDG_RUNTIME_DIR"] ?? "/tmp"
        let candidates = [
            "\(runtime)/cc-socks/\(pid).sock",
            "/tmp/cc-socks-\(getuid())/\(pid).sock",
        ]
        return candidates.first(where: isOwnSocket)
    }

    /// ~ 始まりのパスを展開する（レジストリの値をそのまま使えるように）。
    public static func expandHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" { return home }
        return path.hasPrefix("~/") ? home + "/" + path.dropFirst(2) : path
    }

    /// 書く 1 行（認証行は macOS/Linux では任意。他セッションのトークンは持てないので付けない）。
    static func line(for text: String) -> Data {
        let object: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        var data = JSONLoose.data(object, options: [.withoutEscapingSlashes], fallback: Data())
        data.append(0x0A)
        return data
    }

    /// 受信箱へ 1 通投稿する。成功は「書き終えた」までの保証で、受理されたかまでは分からない。失敗なら理由。
    public static func send(socketPath: String, text: String) async -> String? {
        let payload = line(for: text)
        return await Task.detached(priority: .userInitiated) { write(payload, to: socketPath) }.value
    }

    private static func write(_ payload: Data, to path: String) -> String? {
        var addr = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return "ソケットのパスが長すぎます" }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: pathBytes)
            buf[pathBytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return String(cString: strerror(errno)) }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: Int(idleTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return String(cString: strerror(errno)) }

        let deadline = Date().addingTimeInterval(totalTimeout)
        var sent = 0
        let failure: String? = payload.withUnsafeBytes { buf in
            while sent < buf.count {
                if Date() > deadline { return "送信が時間内に終わりませんでした" }
                let n = Darwin.write(fd, buf.baseAddress! + sent, buf.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { return "応答がありませんでした" }
                    return String(cString: strerror(errno))
                }
                sent += n
            }
            return nil
        }
        if let failure { return failure }
        shutdown(fd, SHUT_WR)
        return nil
    }
}
