import Foundation

/// ディレクトリの中の変化（作成・置き換え・削除）と、指定したファイル自体の書き換えを知らせる。
/// 続けて来る通知は少し待ってから 1 回にまとめる。
@MainActor
final class DirectoryWatcher {
    private let directory: URL
    private let fileName: String?
    private let onChange: @MainActor () -> Void
    // deinit（MainActor の外）から止めるため。どれも作り替えは MainActor の上だけで行う。
    nonisolated(unsafe) private var directorySource: DispatchSourceFileSystemObject?
    nonisolated(unsafe) private var fileSource: DispatchSourceFileSystemObject?
    nonisolated(unsafe) private var pending: Task<Void, Never>?
    nonisolated(unsafe) private var retry: Task<Void, Never>?
    private var fileInode: UInt64?

    static let coalesce: Duration = .milliseconds(100)
    /// ディレクトリがまだ無い・消えた時に張り直すまでの間。
    static let retryInterval: Duration = .seconds(2)

    init(directory: URL, fileName: String? = nil, onChange: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.fileName = fileName
        self.onChange = onChange
    }

    deinit {
        directorySource?.cancel()
        fileSource?.cancel()
        pending?.cancel()
        retry?.cancel()
    }

    func start() {
        stopDirectory()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            stopFile()
            scheduleRetry()
            return
        }
        directorySource = Self.makeSource(fd: fd, mask: [.write, .delete, .rename]) { [weak self] events in
            guard let self else { return }
            // ディレクトリ自体が消えた・動いた時は張り直す。中身の変化ではファイルの置き換えを確かめる。
            if !events.intersection([.delete, .rename]).isEmpty {
                self.start()
            } else {
                self.armFile()
            }
            self.notifySoon()
        }
        armFile()
    }

    func stop() {
        stopDirectory()
        stopFile()
        retry?.cancel()
        retry = nil
        pending?.cancel()
        pending = nil
    }

    private func stopDirectory() {
        directorySource?.cancel()
        directorySource = nil
    }

    private func stopFile() {
        fileSource?.cancel()
        fileSource = nil
        fileInode = nil
    }

    /// ファイルに監視を張る。置き換えで inode が替わっていれば張り直す。無ければディレクトリの監視で出現を待つ。
    private func armFile() {
        guard let fileName else { return }
        let path = directory.appendingPathComponent(fileName).path
        var st = stat()
        guard stat(path, &st) == 0 else {
            stopFile()
            return
        }
        if fileSource != nil, fileInode == UInt64(st.st_ino) { return }
        stopFile()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else {
            close(fd)
            return
        }
        fileInode = UInt64(opened.st_ino)
        fileSource = Self.makeSource(fd: fd, mask: [.write, .extend, .attrib, .delete, .rename]) { [weak self] events in
            guard let self else { return }
            if !events.intersection([.delete, .rename]).isEmpty {
                self.stopFile()
                self.armFile()
            }
            self.notifySoon()
        }
    }

    private static func makeSource(fd: Int32, mask: DispatchSource.FileSystemEvent,
                                   handler: @escaping @MainActor (DispatchSource.FileSystemEvent) -> Void)
        -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { [weak source] in
            guard let source else { return }
            let events = source.data
            MainActor.assumeIsolated { handler(events) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func notifySoon() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesce)
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }

    private func scheduleRetry() {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: Self.retryInterval)
            guard !Task.isCancelled, let self else { return }
            self.start()
            if self.directorySource != nil { self.notifySoon() }
        }
    }
}
