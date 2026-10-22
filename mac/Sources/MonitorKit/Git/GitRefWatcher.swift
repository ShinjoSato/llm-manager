import CoreServices
import Foundation

/// 図に関わる変化か（HEAD・ref・packed-refs・HEAD の reflog）。index や objects の書き換えでは描き直さない。
public enum GitWatchFilter {
    public static func isRelevant(_ path: String, location: GitRepositoryLocation) -> Bool {
        for root in [location.gitDir, location.commonDir] {
            if path == root { return true }
            guard path.hasPrefix(root + "/") else { continue }
            let relative = String(path.dropFirst(root.count + 1))
            // ロックは書き終わりの置き換えでもう一度届くので、途中では数えない。
            if relative.hasSuffix(".lock") { continue }
            if relative == "HEAD" || relative == "packed-refs" || relative == "logs/HEAD" { return true }
            if relative == "refs" || relative.hasPrefix("refs/") { return true }
        }
        return false
    }
}

/// git dir と共通の dir を下層まで FSEvents で見張り、図に関わる変化を知らせる（まとめるのは受け手）。
@MainActor
public final class GitRefWatcher {
    public let location: GitRepositoryLocation
    private let onChange: @MainActor () -> Void
    // deinit（MainActor の外）から止めるため。作り替えは MainActor の上だけで行う。
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    nonisolated(unsafe) private var box: Unmanaged<CallbackBox>?

    static let latency: CFTimeInterval = 0.25

    /// 呼び戻しは main の上だけで watcher を読む。
    private final class CallbackBox: @unchecked Sendable {
        weak var watcher: GitRefWatcher?
        init(_ watcher: GitRefWatcher) { self.watcher = watcher }
    }

    public init(location: GitRepositoryLocation, onChange: @escaping @MainActor () -> Void) {
        self.location = location
        self.onChange = onChange
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        box?.release()
    }

    public var isRunning: Bool { stream != nil }

    public func start() {
        guard stream == nil else { return }
        let paths = Array(Set([location.gitDir, location.commonDir])) as CFArray
        let retained = Unmanaged.passRetained(CallbackBox(self))
        var context = FSEventStreamContext(version: 0, info: retained.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, Self.callback, &context, paths,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags) else {
            retained.release()
            return
        }
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            retained.release()
            return
        }
        stream = created
        box = retained
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        box?.release()
        box = nil
    }

    fileprivate func received(_ paths: [String], flags: [FSEventStreamEventFlags]) {
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
        let relevant = zip(paths, flags).contains { path, flag in
            (flag & rescan) != 0 || GitWatchFilter.isRelevant(path, location: location)
        }
        if relevant { onChange() }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        let paths = (unsafeBitCast(rawPaths, to: NSArray.self) as? [String]) ?? []
        let flags = Array(UnsafeBufferPointer(start: rawFlags, count: count))
        // FSEventStreamSetDispatchQueue(.main) なので main の上で呼ばれる。
        MainActor.assumeIsolated { box.watcher?.received(paths, flags: flags) }
    }
}
