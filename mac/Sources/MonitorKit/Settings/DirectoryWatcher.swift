import Foundation

/// ディレクトリの中の変化（作成・置き換え・削除）を知らせる。続けて来る通知は少し待ってから 1 回にまとめる。
@MainActor
final class DirectoryWatcher {
    private let directory: URL
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?
    private var retry: Task<Void, Never>?

    static let coalesce: Duration = .milliseconds(100)
    /// ディレクトリがまだ無い・消えた時に張り直すまでの間。
    static let retryInterval: Duration = .seconds(2)

    init(directory: URL, onChange: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.onChange = onChange
    }

    func start() {
        stopSource()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            scheduleRetry()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                // ディレクトリ自体が消えた・動いた時は張り直す。
                if !source.data.intersection([.delete, .rename]).isEmpty {
                    self.start()
                }
                self.notifySoon()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        stopSource()
        retry?.cancel()
        retry = nil
        pending?.cancel()
        pending = nil
    }

    private func stopSource() {
        source?.cancel()
        source = nil
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
            if self.source != nil { self.notifySoon() }
        }
    }
}
