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
    /// プロセスグループごと SIGTERM し、`grace` 秒待っても残れば SIGKILL する。終わるまで呼び出し元を止める。
    func terminateGroup(grace: TimeInterval)
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
    public var runner: any MonitorProcessRunning
    public var processEnvironment: [String: String]

    public init(isHealthy: @escaping @Sendable () async -> Bool,
                isPortOpen: @escaping @Sendable (Int) -> Bool,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                runner: any MonitorProcessRunning = PosixProcessRunner(),
                processEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.isHealthy = isHealthy
        self.isPortOpen = isPortOpen
        self.fileExists = fileExists
        self.runner = runner
        self.processEnvironment = processEnvironment
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
    /// 停止時に SIGTERM から SIGKILL へ切り替えるまでの秒数。
    public var terminationGrace: TimeInterval = 3

    /// 失敗したときに呼ばれる（メインスレッド）。
    @ObservationIgnored public var onFailure: ((MonitorLaunchFailure) -> Void)?

    @ObservationIgnored private let environment: MonitorLauncherEnvironment
    @ObservationIgnored private var child: (any MonitorChildProcess)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stopping = false

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

    /// 自分が起動して今も動いている monitor の pid。
    public var ownedPid: Int32? {
        guard let child, !child.hasExited else { return nil }
        return child.pid
    }

    public var port: Int { configuration.baseURL.port ?? 80 }

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
        stopping = false
        task = Task { [weak self] in await self?.run() }
    }

    /// 自分が起動したもの（準備中の npm を含む）だけを止める。既存の monitor には触れない。
    public func stop() {
        stopping = true
        task?.cancel()
        task = nil
        if terminateChild() { phase = .stopped }
    }

    /// 子プロセスがあればグループごと止める。止めたら true。
    @discardableResult
    private func terminateChild() -> Bool {
        guard let child else { return false }
        self.child = nil
        child.terminateGroup(grace: terminationGrace)
        appendLog("[claude-deck] monitor（pgid \(child.pid)）を停止しました")
        return true
    }

    // MARK: - 手順

    func run() async {
        phase = .checking
        guard Self.isLoopback(configuration.baseURL) else {
            phase = .skippedRemote(host: configuration.baseURL.host ?? "?")
            return
        }
        if await environment.isHealthy() {
            phase = .usingExisting
            return
        }
        if environment.isPortOpen(port) { return fail(.portInUse(port: port)) }

        guard let dir = monitorDirectory,
              environment.fileExists(dir.appendingPathComponent("package.json").path) else {
            return fail(.monitorDirectoryMissing(path: monitorDirectory?.path))
        }

        appendLog("[claude-deck] \(Date()) monitor を起動します（\(dir.path)、port \(port)）")
        guard let nodeExit = await runStep("command -v node >/dev/null && command -v npm >/dev/null", in: dir),
              !stopping else { return }
        if nodeExit != 0 { return fail(.nodeNotFound) }

        if !environment.fileExists(dir.appendingPathComponent("node_modules").path) {
            phase = .installing
            guard let code = await runStep("npm install", in: dir), !stopping else { return }
            if code != 0 { return fail(.stepFailed(step: "npm install", exitCode: code)) }
        }
        if !environment.fileExists(dir.appendingPathComponent("ui/dist/index.html").path) {
            phase = .building
            guard let code = await runStep("npm run build", in: dir), !stopping else { return }
            if code != 0 { return fail(.stepFailed(step: "npm run build", exitCode: code)) }
        }

        // 準備の間に他所で monitor が立ち上がっていればそれを使う。
        if await environment.isHealthy() {
            phase = .usingExisting
            return
        }

        let server: any MonitorChildProcess
        do {
            server = try spawn("npm start", in: dir)
        } catch {
            return fail(.spawnFailed(message: String(describing: error)))
        }
        phase = .starting(pid: server.pid)

        let deadline = Date().addingTimeInterval(startupTimeout)
        while !stopping {
            if server.hasExited {
                let code = await server.waitForExit()
                child = nil
                return fail(environment.isPortOpen(port) ? .portInUse(port: port) : .processExited(exitCode: code))
            }
            if await environment.isHealthy() { break }
            if Date() >= deadline {
                terminateChild()
                return fail(.healthTimeout(seconds: Int(startupTimeout)))
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        guard !stopping else { return }
        phase = .running(pid: server.pid)

        // 動き出した後に落ちたら知らせる。
        let code = await server.waitForExit()
        guard !stopping, child === server else { return }
        child = nil
        fail(.processExited(exitCode: code))
    }

    /// 完了まで待って終了コードを返す。止められたら nil。
    private func runStep(_ command: String, in dir: URL) async -> Int32? {
        let process: any MonitorChildProcess
        do {
            process = try spawn(command, in: dir)
        } catch {
            fail(.spawnFailed(message: String(describing: error)))
            return nil
        }
        let code = await process.waitForExit()
        if child === process { child = nil }
        return stopping ? nil : code
    }

    private func spawn(_ command: String, in dir: URL) throws -> any MonitorChildProcess {
        let process = try environment.runner.spawn(
            script: Self.shellScript(command, port: port),
            directory: dir,
            environment: Self.childEnvironment(from: environment.processEnvironment, port: port),
            logURL: logURL
        )
        child = process
        return process
    }

    private func fail(_ failure: MonitorLaunchFailure) {
        phase = .failed(failure)
        appendLog("[claude-deck] 自動起動に失敗: \(failure.errorDescription ?? "\(failure)")")
        onFailure?(failure)
    }

    private func appendLog(_ line: String) {
        guard let logURL else { return }
        MonitorLogFile.append(line + "\n", to: logURL)
    }
}

// MARK: - 実機の子プロセス

enum MonitorLogFile {
    /// 書き込み用に開いた fd（追記）。失敗したら -1。
    static func open(_ url: URL) -> Int32 {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    }

    static func append(_ text: String, to url: URL) {
        let fd = open(url)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }
}

public enum PosixSpawnError: Error, CustomStringConvertible {
    case failed(Int32)
    public var description: String { "posix_spawn: \(String(cString: strerror(errnoValue)))" }
    private var errnoValue: Int32 { if case .failed(let e) = self { return e }; return 0 }
}

/// `/bin/zsh -lc` を新しいプロセスグループの先頭として起動する（npm → tsx → node をまとめて止めるため）。
public struct PosixProcessRunner: MonitorProcessRunning {
    public init() {}

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

        let args = ["/bin/zsh", "-lc", script]
        let env = environment.map { "\($0.key)=\($0.value)" }
        var cArgs = args.map { strdup($0) } + [nil]
        var cEnv = env.map { strdup($0) } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/zsh", &actions, &attr, &cArgs, &cEnv)
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

    func terminateGroup(grace: TimeInterval) {
        guard kill(-pid, SIGTERM) == 0 else { return }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if !Self.groupAlive(pid) { return }
            usleep(50_000)
        }
        kill(-pid, SIGKILL)
        let hardDeadline = Date().addingTimeInterval(1)
        while Self.groupAlive(pid) && Date() < hardDeadline { usleep(20_000) }
    }

    private static func groupAlive(_ pgid: Int32) -> Bool {
        kill(-pgid, 0) == 0 || errno == EPERM
    }
}

/// ループバックのポートに誰かが待ち受けているか。
public enum LoopbackPort {
    public static func isOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }
}
