import Foundation

/// mcpbridge から届くもの。
public enum XcodeBridgeEvent: Sendable {
    case line(Data)
    /// 先頭のプロセスが終わった（標準エラーの末尾を添える）。
    case exited(String)
}

/// mcpbridge との行のやりとり（テストでは置き換える）。
public protocol XcodeBridgeTransport: AnyObject, Sendable {
    func send(_ line: Data) throws
    func stop() async
}

/// `events` に行と終了を流す転送を作る。
public typealias XcodeBridgeLaunch = @Sendable (_ events: AsyncStream<XcodeBridgeEvent>.Continuation) throws -> any XcodeBridgeTransport

/// `xcrun mcpbridge` を新しいプロセスグループで起動し、stdin / stdout で 1 行 1 メッセージをやりとりする（止め方は `ProcessGroup`）。
public final class XcodeBridgeProcess: XcodeBridgeTransport, @unchecked Sendable {
    /// 改行の来ない行をため込む上限（壊れた出力でメモリを食い続けないため）。
    static let maxLine = 32 * 1024 * 1024
    static let stderrTailLimit = 4 * 1024

    public let pid: pid_t
    private let lock = NSLock()
    private var input: FileHandle?
    private var outputs: [FileHandle] = []
    private var exitSource: DispatchSourceProcess?
    private var group: ProcessGroup
    private var stopTask: Task<Void, Never>?
    private var buffer = Data()
    private var stderrTail = Data()
    private var exitReported = false
    private let events: AsyncStream<XcodeBridgeEvent>.Continuation

    private init(pid: pid_t, events: AsyncStream<XcodeBridgeEvent>.Continuation) {
        self.pid = pid
        group = ProcessGroup(pid: pid)
        self.events = events
    }

    /// 環境は呼び出し側で API キー等を除いたものを渡す。
    public static func launcher(environment: [String: String], directory: String) -> XcodeBridgeLaunch {
        { events in
            try spawn(executable: "/usr/bin/xcrun", arguments: ["mcpbridge"], environment: environment, directory: directory, events: events)
        }
    }

    public static func spawn(executable: String, arguments: [String], environment: [String: String], directory: String,
                             events: AsyncStream<XcodeBridgeEvent>.Continuation) throws -> XcodeBridgeProcess {
        var inFDs: [Int32] = [0, 0], outFDs: [Int32] = [0, 0], errFDs: [Int32] = [0, 0]
        guard pipe(&inFDs) == 0 else { throw PosixSpawnError.failed(errno) }
        guard pipe(&outFDs) == 0 else {
            inFDs.forEach { close($0) }
            throw PosixSpawnError.failed(errno)
        }
        guard pipe(&errFDs) == 0 else {
            (inFDs + outFDs).forEach { close($0) }
            throw PosixSpawnError.failed(errno)
        }
        for fd in [inFDs[1], outFDs[0], errFDs[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // 相手が先に終わっても書き込みで SIGPIPE を受けず、EPIPE で知る。
        _ = fcntl(inFDs[1], F_SETNOSIGPIPE, 1)

        let (pid, rc) = ProcessGroup.spawn(executable: executable, arguments: arguments, environment: environment,
                                           directory: directory) { actions in
            posix_spawn_file_actions_adddup2(&actions, inFDs[0], 0)
            posix_spawn_file_actions_adddup2(&actions, outFDs[1], 1)
            posix_spawn_file_actions_adddup2(&actions, errFDs[1], 2)
        }
        [inFDs[0], outFDs[1], errFDs[1]].forEach { close($0) }
        guard rc == 0 else {
            [inFDs[1], outFDs[0], errFDs[0]].forEach { close($0) }
            throw PosixSpawnError.failed(rc)
        }

        let process = XcodeBridgeProcess(pid: pid, events: events)
        let input = FileHandle(fileDescriptor: inFDs[1], closeOnDealloc: true)
        let output = FileHandle(fileDescriptor: outFDs[0], closeOnDealloc: true)
        let errors = FileHandle(fileDescriptor: errFDs[0], closeOnDealloc: true)
        output.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { process.receive(data) }
        }
        errors.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { process.receiveError(data) }
        }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { process.leaderExited() }
        process.lock.withLock {
            process.input = input
            process.outputs = [output, errors]
            process.exitSource = source
        }
        source.resume()
        if process.peekExited() { process.leaderExited() }
        return process
    }

    public func send(_ line: Data) throws {
        guard let input = lock.withLock({ input }) else { throw XcodeBridgeFailure.bridgeUnavailable("mcpbridge は終了しています") }
        var data = line
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    /// 改行ごとに 1 行として渡す（行の分け目は読む単位に依らない）。
    private func receive(_ data: Data) {
        let lines = lock.withLock { () -> [Data] in
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                if !line.isEmpty { lines.append(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if buffer.count > Self.maxLine { buffer.removeAll() }
            return lines
        }
        lines.forEach { events.yield(.line($0)) }
    }

    private func receiveError(_ data: Data) {
        lock.withLock {
            stderrTail.append(data)
            if stderrTail.count > Self.stderrTailLimit { stderrTail = Data(stderrTail.suffix(Self.stderrTailLimit)) }
        }
    }

    private func peekExited() -> Bool { ProcessGroup.peekExit(pid) != nil }

    private func leaderExited() {
        guard peekExited() else { return }
        let report = lock.withLock { () -> Bool in
            exitSource?.cancel()
            exitSource = nil
            defer { exitReported = true }
            return !exitReported
        }
        guard report else { return }
        Task { await self.stop() }
        // 出力の最後を読み切ってから知らせる。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) { [self] in
            let tail = lock.withLock { String(decoding: stderrTail, as: UTF8.self) }
            events.yield(.exited(tail.trimmingCharacters(in: .whitespacesAndNewlines)))
            events.finish()
        }
    }

    public var isFinished: Bool { lock.withLock { group.reaped } }

    /// stdin を閉じ（行儀よく終わる機会を与え）、グループごと止める。何度呼んでも 1 回分の手順。
    public func stop() async {
        let task = lock.withLock { () -> Task<Void, Never> in
            if let stopTask { return stopTask }
            try? input?.close()
            input = nil
            let task = Task.detached(priority: .utility) { [self] in
                // stdin を閉じて自分から終わるのを少し待つ。
                for _ in 0..<5 where !peekExited() { try? await Task.sleep(for: .milliseconds(100)) }
                while !advance(now: Date()) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            stopTask = task
            return task
        }
        await task.value
    }

    /// アプリの終了時。まとめて止め、止まるか猶予が尽きるまでこのスレッドで待つ。
    public static func stopAllBlocking(_ processes: [XcodeBridgeProcess]) {
        for process in processes { process.lock.withLock { try? process.input?.close(); process.input = nil } }
        ProcessGroup.advanceAllBlocking(processes.map { process in { process.advance(now: $0) } })
    }

    private func advance(now: Date) -> Bool {
        lock.withLock {
            guard group.advance(now: now) else { return false }
            exitSource?.cancel()
            exitSource = nil
            return true
        }
    }
}
