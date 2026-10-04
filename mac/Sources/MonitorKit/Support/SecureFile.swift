import Foundation

/// 自分だけが読めるファイル（ディレクトリ 0700・ファイル 0600）。途中で落ちても壊れた中身を残さないよう置き換えで書く。
enum SecureFile {
    enum Failure: Error, Equatable {
        case writeFailed(String)
    }

    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let failed = Failure.writeFailed(url.lastPathComponent)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // 既にあったディレクトリも（後から広げられていても）毎回締め直す。
        guard chmod(dir.path, 0o700) == 0 else { throw failed }
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        // 作った瞬間から 0600（作ってから権限を変えると、その間は他人に読める）。
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failed }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
        let synced = fsync(fd) == 0
        guard close(fd) == 0, written, synced, rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            throw failed
        }
    }
}
