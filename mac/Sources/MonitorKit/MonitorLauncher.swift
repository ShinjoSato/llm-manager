import Foundation
import Observation

/// monitor 自動起動の進み具合。画面表示はこれを見る。
public enum MonitorLaunchPhase: Sendable, Equatable {
    /// `start()` 前。
    case idle
    /// 既存の monitor が応答するか確かめている。
    case checking
    /// 既に動いていた monitor を使う（止めない）。
    case usingExisting
    /// 接続先がループバック以外なので起動しない。
    case skippedRemote(host: String)
    /// `npm install` 中。
    case installing
    /// `npm run build`（ui/dist の生成）中。
    case building
    /// 起動して health を待っている。
    case starting(pid: Int32)
    /// 自分が起動した monitor が応答している。
    case running(pid: Int32)
    /// 自分が起動した monitor を止めた。
    case stopped
    case failed(MonitorLaunchFailure)

    /// 長くかかる準備中か（install / build / 起動待ち）。
    public var isBusy: Bool {
        switch self {
        case .checking, .installing, .building, .starting: return true
        default: return false
        }
    }
}

/// 自動起動できなかった理由。
public enum MonitorLaunchFailure: Sendable, Equatable, LocalizedError {
    /// ai-manager ルート（または monitor/）が見つからない。`path` は探した場所。
    case monitorDirectoryMissing(path: String?)
    /// ログインシェルから node / npm が見つからない。
    case nodeNotFound
    /// ポートは使われているが monitor の health に応答しない。
    case portInUse(port: Int)
    /// `npm install` / `npm run build` が失敗した。
    case stepFailed(step: String, exitCode: Int32)
    /// 起動したが一定時間内に health が上がらなかった。
    case healthTimeout(seconds: Int)
    /// 起動した monitor が終了した。
    case processExited(exitCode: Int32)
    /// 子プロセスを作れなかった。
    case spawnFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .monitorDirectoryMissing(let path):
            return "monitor ディレクトリが見つかりません（\(path ?? "ai-manager ルートを解決できません")）。AI_MANAGER_ROOT を確認してください。"
        case .nodeNotFound:
            return "node / npm が見つかりません。ログインシェル（zsh -l）の PATH に node を通してください。"
        case .portInUse(let port):
            return "ポート \(port) は別のプロセスが使用中で、monitor として応答しません。"
        case .stepFailed(let step, let code):
            return "`\(step)` が失敗しました（終了コード \(code)）。"
        case .healthTimeout(let seconds):
            return "monitor を起動しましたが \(seconds) 秒以内に応答しませんでした。"
        case .processExited(let code):
            return "monitor が終了しました（終了コード \(code)）。"
        case .spawnFailed(let message):
            return "monitor を起動できません: \(message)"
        }
    }
}

/// 起動した子プロセス（プロセスグループの先頭）。
public protocol MonitorChildProcess: AnyObject, Sendable {
    var pid: Int32 { get }
    var hasExited: Bool { get }
    /// 終了を待ち、終了コード（シグナル終了なら 128+番号）を返す。
    func waitForExit() async -> Int32
    /// プロセスグループ全体にシグナルを送る（先頭が終了済みでも残りに届く）。
    func signalGroup(_ signal: Int32)
    /// グループにまだプロセスが残っているか。
    var isGroupAlive: Bool { get }
}

/// シェルスクリプトを子プロセスとして起動する口。テストでは差し替える。
public protocol MonitorProcessRunning: Sendable {
    func spawn(script: String, directory: URL, environment: [String: String], logURL: URL?) throws -> any MonitorChildProcess
}

/// launcher が外界に触れる口。テストでは差し替える。
public struct MonitorLauncherEnvironment: Sendable {
    public var isHealthy: @Sendable () async -> Bool
    public var isPortOpen: @Sendable (Int) -> Bool
    public var fileExists: @Sendable (String) -> Bool
    /// 空ファイルを作る（親ディレクトリも作る）。
    public var createFile: @Sendable (String) -> Void
    public var removeFile: @Sendable (String) -> Void
    public var runner: any MonitorProcessRunning
    public var processEnvironment: [String: String]

    public init(isHealthy: @escaping @Sendable () async -> Bool,
                isPortOpen: @escaping @Sendable (Int) -> Bool,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                createFile: @escaping @Sendable (String) -> Void = MonitorLauncherEnvironment.createEmptyFile,
                removeFile: @escaping @Sendable (String) -> Void = { try? FileManager.default.removeItem(atPath: $0) },
                runner: any MonitorProcessRunning = PosixProcessRunner(),
                processEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.isHealthy = isHealthy
        self.isPortOpen = isPortOpen
        self.fileExists = fileExists
        self.createFile = createFile
        self.removeFile = removeFile
        self.runner = runner
        self.processEnvironment = processEnvironment
    }

    @Sendable public static func createEmptyFile(_ path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    /// 実機用。health は短いタイムアウトで 1 回だけ叩く。
    public static func live(configuration: MonitorConfiguration) -> MonitorLauncherEnvironment {
        var probeConfig = configuration
        probeConfig.idleTimeout = 2
        let client = MonitorClient(configuration: probeConfig)
        return MonitorLauncherEnvironment(
            isHealthy: { (try? await client.health()) ?? false },
            isPortOpen: { port in LoopbackPort.isOpen(port) }
        )
    }
}

/// monitor が動いていなければ `monitor/` で起動し、自分が起動したものだけをアプリ終了時に止める。
@MainActor
@Observable
public final class MonitorLauncher {
    public private(set) var phase: MonitorLaunchPhase = .idle
    /// 子プロセスの標準出力 / 標準エラーの書き先。
    public let logURL: URL?

    public let configuration: MonitorConfiguration
    public let monitorDirectory: URL?

    /// 起動後に health が上がるまで待つ秒数。
    public var startupTimeout: TimeInterval = 45
    public var pollInterval: TimeInterval = 0.5
    /// 非同期の停止で SIGTERM から SIGKILL へ切り替えるまでの秒数。
    public var terminationGrace: TimeInterval = 3
    /// 同期の停止（アプリ終了の最終手段）で SIGKILL までに待つ秒数。main を止めるので短くする。
    public var immediateTerminationGrace: TimeInterval = 0.3
    /// 起動時にこれを超えていたらログを `.1` に回す。
    public var logRotationBytes: Int = 5 * 1024 * 1024

    /// 失敗したときに呼ばれる（メインスレッド）。
    @ObservationIgnored public var onFailure: ((MonitorLaunchFailure) -> Void)?

    @ObservationIgnored private let environment: MonitorLauncherEnvironment
    @ObservationIgnored private var child: (any MonitorChildProcess)?
    /// 落ちた / 見限った子をグループごと片付けている最中のもの。終了時の停止対象に含める。
    @ObservationIgnored private var cleaning: [any MonitorChildProcess] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    /// start / stop ごとに進める。古い実行が新しい実行の状態を書き換えないよう照合に使う。
    @ObservationIgnored private var generation = 0

    public init(configuration: MonitorConfiguration,
                monitorDirectory: URL?,
                logURL: URL? = MonitorLauncher.defaultLogURL,
                environment: MonitorLauncherEnvironment? = nil) {
        self.configuration = configuration
        self.monitorDirectory = monitorDirectory
        self.logURL = logURL
        self.environment = environment ?? .live(configuration: configuration)
    }

    public nonisolated static var defaultLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/claude-deck/monitor.log")
    }

    /// install / build の途中で止まったことを示す印（npm は node_modules 直下のドットファイルを消さない）。
    public nonisolated static let installIncompleteMarker = "node_modules/.claude-deck-install-incomplete"
    public nonisolated static let buildIncompleteMarker = "node_modules/.claude-deck-build-incomplete"
    /// npm が install の最後に書く。これが無ければ install は終わっていない。
    public nonisolated static let installCompleteFile = "node_modules/.package-lock.json"
    public nonisolated static let buildOutputFile = "ui/dist/index.html"

    /// 自分が起動して今も動いている monitor の pid。
    public var ownedPid: Int32? {
        guard let child, !child.hasExited else { return nil }
        return child.pid
    }

    /// 止めるべき子プロセス（準備中の npm を含む）を持っているか。
    public var hasOwnedProcess: Bool { child != nil || !cleaning.isEmpty }

    public var port: Int { Self.port(of: configuration.baseURL) }

    public nonisolated static func port(of url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }

    /// ループバック以外は他人の monitor なので起動しない。
    public nonisolated static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    /// 子プロセスに渡す環境。API キーは課金経路になり、MONITOR_LAN は LAN 公開になるので渡さない。
    public nonisolated static func childEnvironment(from base: [String: String], port: Int) -> [String: String] {
        var env = base
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "MONITOR_LAN", "MONITOR_TOKEN"] {
            env.removeValue(forKey: key)
        }
        env["PORT"] = String(port)
        return env
    }

    /// ログインシェルで読んだ設定が戻さないよう、シェル側でも消してから exec する。
    public nonisolated static func shellScript(_ command: String, port: Int) -> String {
        "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN MONITOR_LAN MONITOR_TOKEN; export PORT=\(port); exec \(command)"
    }

    public func start() {
        guard task == nil else { return }
        generation &+= 1
        let current = generation
        task = Task { [weak self] in await self?.run(generation: current) }
    }

    /// 自分が起動したもの（準備中の npm を含む）だけを止める。main を止めずに SIGTERM → 猶予 → SIGKILL。
    public func stop() async {
        let processes = detachForStop()
        guard !processes.isEmpty else { return }
        await Self.terminate(processes, grace: terminationGrace)
        appendLog(Self.stoppedMessage(processes))
    }

    /// main actor に戻らずに止め、完了をバックグラウンドで知らせる（終了確認中の run loop では main actor のタスクが進まないため）。
    public func stopInBackground(completion: @escaping @Sendable () -> Void) {
        let processes = detachForStop()
        guard !processes.isEmpty else { return completion() }
        let grace = terminationGrace
        let logURL = logURL
        DispatchQueue.global(qos: .userInitiated).async {
            Self.terminateBlocking(processes, grace: grace)
            if let logURL { MonitorLogFile.append(Self.stoppedMessage(processes) + "\n", to: logURL) }
            completion()
        }
    }

    /// 同期で止める（非同期の停止を経ずに終わる経路の最終手段）。
    public func stopImmediately() {
        let processes = detachForStop()
        guard !processes.isEmpty else { return }
        Self.terminateBlocking(processes, grace: immediateTerminationGrace)
        appendLog(Self.stoppedMessage(processes))
    }

    /// 実行中の手順を無効にし、止めるべき子（片付け中のものを含む）を引き取る。
    private func detachForStop() -> [any MonitorChildProcess] {
        generation &+= 1
        task?.cancel()
        task = nil
        let processes = (child.map { [$0] } ?? []) + cleaning.filter { $0 !== child }
        child = nil
        cleaning = []
        if !processes.isEmpty || phase.isBusy { phase = .stopped }
        return processes
    }

    private nonisolated static func stoppedMessage(_ processes: [any MonitorChildProcess]) -> String {
        "[claude-deck] monitor（pgid \(processes.map { String($0.pid) }.joined(separator: ", "))）を停止しました"
    }

    nonisolated static func terminate(_ process: any MonitorChildProcess, grace: TimeInterval) async {
        await terminate([process], grace: grace)
    }

    /// グループへ SIGTERM し、猶予内に消えなければ SIGKILL する。
    nonisolated static func terminate(_ processes: [any MonitorChildProcess], grace: TimeInterval) async {
        processes.forEach { $0.signalGroup(SIGTERM) }
        // 呼び出し元がキャンセル済みでも猶予を守り、かつスレッドを塞がないよう、キャンセルの伝わらない別タスクで待つ。
        await Task.detached {
            let deadline = Date().addingTimeInterval(grace)
            while processes.contains(where: \.isGroupAlive) && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }.value
        processes.filter(\.isGroupAlive).forEach { $0.signalGroup(SIGKILL) }
    }

    nonisolated static func terminateBlocking(_ processes: [any MonitorChildProcess], grace: TimeInterval) {
        processes.forEach { $0.signalGroup(SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while processes.contains(where: \.isGroupAlive) && Date() < deadline { usleep(20_000) }
        processes.filter(\.isGroupAlive).forEach { $0.signalGroup(SIGKILL) }
    }

    // MARK: - 手順

    /// テスト用: 新しい世代として手順を 1 回走らせる。
    func run() async {
        generation &+= 1
        await run(generation: generation)
    }

    private func isCurrent(_ gen: Int) -> Bool { gen == generation }

    private func run(generation gen: Int) async {
        guard isCurrent(gen) else { return }
        phase = .checking
        guard Self.isLoopback(configuration.baseURL) else {
            guard isCurrent(gen) else { return }
            phase = .skippedRemote(host: configuration.baseURL.host ?? "?")
            return
        }
        if await environment.isHealthy() {
            guard isCurrent(gen) else { return }
            phase = .usingExisting
            return
        }
        guard isCurrent(gen) else { return }
        if environment.isPortOpen(port) { return fail(.portInUse(port: port), gen) }

        guard let dir = monitorDirectory,
              environment.fileExists(dir.appendingPathComponent("package.json").path) else {
            return fail(.monitorDirectoryMissing(path: monitorDirectory?.path), gen)
        }

        if let logURL { MonitorLogFile.rotateIfNeeded(logURL, limit: logRotationBytes) }
        appendLog("[claude-deck] \(Date()) monitor を起動します（\(dir.path)、port \(port)）")
        guard let nodeExit = await runStep("command -v node >/dev/null && command -v npm >/dev/null", in: dir, gen) else { return }
        if nodeExit != 0 { return fail(.nodeNotFound, gen) }

        let path = { (relative: String) in dir.appendingPathComponent(relative).path }
        if !environment.fileExists(path(Self.installCompleteFile)) || environment.fileExists(path(Self.installIncompleteMarker)) {
            phase = .installing
            environment.createFile(path(Self.installIncompleteMarker))
            guard let code = await runStep("npm install", in: dir, gen) else { return }
            if code != 0 { return fail(.stepFailed(step: "npm install", exitCode: code), gen) }
            environment.removeFile(path(Self.installIncompleteMarker))
        }
        if !environment.fileExists(path(Self.buildOutputFile)) || environment.fileExists(path(Self.buildIncompleteMarker)) {
            phase = .building
            environment.createFile(path(Self.buildIncompleteMarker))
            guard let code = await runStep("npm run build", in: dir, gen) else { return }
            if code != 0 { return fail(.stepFailed(step: "npm run build", exitCode: code), gen) }
            environment.removeFile(path(Self.buildIncompleteMarker))
        }

        // 準備の間に他所で monitor が立ち上がっていればそれを使う。
        let appeared = await environment.isHealthy()
        guard isCurrent(gen) else { return }
        if appeared {
            phase = .usingExisting
            return
        }

        let server: any MonitorChildProcess
        do {
            guard let spawned = try spawn("npm start", in: dir, gen) else { return }
            server = spawned
        } catch {
            return fail(.spawnFailed(message: String(describing: error)), gen)
        }
        phase = .starting(pid: server.pid)

        let deadline = Date().addingTimeInterval(startupTimeout)
        while true {
            guard isCurrent(gen) else { return }
            if server.hasExited {
                let code = await server.waitForExit()
                guard isCurrent(gen) else { return }
                await releaseExited(server)
                return fail(environment.isPortOpen(port) ? .portInUse(port: port) : .processExited(exitCode: code), gen)
            }
            let healthy = await environment.isHealthy()
            guard isCurrent(gen) else { return }
            if healthy { break }
            if Date() >= deadline {
                await cleanUp(server)
                return fail(.healthTimeout(seconds: Int(startupTimeout)), gen)
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        phase = .running(pid: server.pid)

        // 動き出した後に落ちたら知らせる。
        let code = await server.waitForExit()
        guard isCurrent(gen), child === server else { return }
        await releaseExited(server)
        fail(.processExited(exitCode: code), gen)
    }

    /// 先頭（npm）が落ちてもグループに tsx / node が残りうるので、まとめて片付ける。
    private func releaseExited(_ process: any MonitorChildProcess) async {
        if process.isGroupAlive {
            await cleanUp(process)
        } else if child === process {
            child = nil
        }
    }

    /// 片付けの間も `cleaning` に残し、その間にアプリが終了しても停止対象から漏れないようにする。
    private func cleanUp(_ process: any MonitorChildProcess) async {
        if child === process { child = nil }
        cleaning.append(process)
        await Self.terminate(process, grace: terminationGrace)
        cleaning.removeAll { $0 === process }
    }

    /// 完了まで待って終了コードを返す。止められたら nil。
    private func runStep(_ command: String, in dir: URL, _ gen: Int) async -> Int32? {
        let process: any MonitorChildProcess
        do {
            guard let spawned = try spawn(command, in: dir, gen) else { return nil }
            process = spawned
        } catch {
            fail(.spawnFailed(message: String(describing: error)), gen)
            return nil
        }
        let code = await process.waitForExit()
        if child === process { child = nil }
        return isCurrent(gen) ? code : nil
    }

    /// 止められた後なら起動せず nil を返す。
    private func spawn(_ command: String, in dir: URL, _ gen: Int) throws -> (any MonitorChildProcess)? {
        guard isCurrent(gen) else { return nil }
        let process = try environment.runner.spawn(
            script: Self.shellScript(command, port: port),
            directory: dir,
            environment: Self.childEnvironment(from: environment.processEnvironment, port: port),
            logURL: logURL
        )
        child = process
        return process
    }

    private func fail(_ failure: MonitorLaunchFailure, _ gen: Int) {
        guard isCurrent(gen) else { return }
        phase = .failed(failure)
        appendLog("[claude-deck] 自動起動に失敗: \(failure.errorDescription ?? "\(failure)")")
        onFailure?(failure)
    }

    private func appendLog(_ line: String) {
        guard let logURL else { return }
        MonitorLogFile.append(line + "\n", to: logURL)
    }
}

/// アプリ終了要求への返答を決める。停止の最中に来た 2 回目の要求で停止を打ち切らない。
@MainActor
public final class MonitorTerminationGate {
    public enum Decision: Equatable, Sendable {
        case terminateNow
        /// 遅延終了にする。`startShutdown` が true のときだけ停止を始めて返答する（返答を 1 回にするため）。
        case terminateLater(startShutdown: Bool)
    }

    public private(set) var shuttingDown = false

    public nonisolated init() {}

    public func decide(needsShutdown: Bool) -> Decision {
        if shuttingDown { return .terminateLater(startShutdown: false) }
        guard needsShutdown else { return .terminateNow }
        shuttingDown = true
        return .terminateLater(startShutdown: true)
    }
}

// MARK: - 実機の子プロセス

enum MonitorLogFile {
    /// 書き込み用に開いた fd（追記）。失敗したら -1。他所の fork（端末ペイン等）に漏れないよう CLOEXEC を付ける。
    static func open(_ url: URL) -> Int32 {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
    }

    static func append(_ text: String, to url: URL) {
        let fd = open(url)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }

    /// `limit` バイトを超えていたら `<name>.1` に回す（1 世代だけ残す）。
    static func rotateIfNeeded(_ url: URL, limit: Int) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > limit else { return }
        let rotated = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }
}

public enum PosixSpawnError: Error, CustomStringConvertible {
    case failed(Int32)
    public var description: String { "posix_spawn: \(String(cString: strerror(errnoValue)))" }
    private var errnoValue: Int32 { if case .failed(let e) = self { return e }; return 0 }
}

/// シェル経由のスクリプトを新しいプロセスグループの先頭として起動する（npm → tsx → node をまとめて止めるため）。
public struct PosixProcessRunner: MonitorProcessRunning {
    /// 既定はログインシェル（node / npm の PATH を得るため）。
    public var shell: [String]

    public init(shell: [String] = ["/bin/zsh", "-lc"]) {
        self.shell = shell
    }

    public func spawn(script: String, directory: URL, environment: [String: String], logURL: URL?) throws -> any MonitorChildProcess {
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setpgroup(&attr, 0)
        // 親（GUI）が無視・遮断しているシグナルを引き継がせない。
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        let logFD = logURL.map(MonitorLogFile.open) ?? -1
        defer { if logFD >= 0 { close(logFD) } }
        if logFD >= 0 {
            posix_spawn_file_actions_adddup2(&actions, logFD, 1)
            posix_spawn_file_actions_adddup2(&actions, logFD, 2)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)

        let args = shell + [script]
        let env = environment.map { "\($0.key)=\($0.value)" }
        var cArgs = args.map { strdup($0) } + [nil]
        var cEnv = env.map { strdup($0) } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, shell[0], &actions, &attr, &cArgs, &cEnv)
        guard rc == 0 else { throw PosixSpawnError.failed(rc) }
        return PosixChildProcess(pid: pid)
    }
}

final class PosixChildProcess: MonitorChildProcess, @unchecked Sendable {
    let pid: Int32
    private let lock = NSLock()
    private var exitCode: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(pid: Int32) {
        self.pid = pid
        // 回収役。ここで waitpid しないとゾンビが残りグループが空にならない。
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            let low = status & 0x7f
            let code = low == 0 ? (status >> 8) & 0xff : 128 + low
            lock.lock()
            exitCode = code
            let pending = waiters
            waiters = []
            lock.unlock()
            pending.forEach { $0.resume(returning: code) }
        }
    }

    var hasExited: Bool {
        lock.lock(); defer { lock.unlock() }
        return exitCode != nil
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitCode {
                lock.unlock()
                continuation.resume(returning: exitCode)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func signalGroup(_ signal: Int32) {
        kill(-pid, signal)
    }

    var isGroupAlive: Bool {
        kill(-pid, 0) == 0 || errno == EPERM
    }
}

/// SIGTERM / SIGINT の既定動作（即終了）だけを外す。
public enum TerminationSignals {
    /// SIG_IGN は exec を越えて子（端末ペインの claude 等）に残るが、登録したハンドラは exec で既定に戻るので漏れない。
    public static func installNoopHandlers(for signals: [Int32] = [SIGTERM, SIGINT]) {
        for sig in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = noopSignalHandler
            sigemptyset(&action.sa_mask)
            action.sa_flags = SA_RESTART
            sigaction(sig, &action, nil)
        }
    }
}

private func noopSignalHandler(_: Int32) {}

/// ループバック（127.0.0.1 と ::1）のポートに誰かが待ち受けているか。
public enum LoopbackPort {
    public static func isOpen(_ port: Int) -> Bool {
        isOpenIPv4(port) || isOpenIPv6(port)
    }

    static func isOpenIPv4(_ port: Int) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return connects(family: AF_INET, &addr)
    }

    static func isOpenIPv6(_ port: Int) -> Bool {
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(UInt16(port).bigEndian)
        addr.sin6_addr = in6addr_loopback
        return connects(family: AF_INET6, &addr)
    }

    private static func connects<Address>(family: Int32, _ addr: inout Address) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<Address>.size))
            }
        }
        return rc == 0
    }
}
