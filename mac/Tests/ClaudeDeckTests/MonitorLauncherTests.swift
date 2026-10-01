import XCTest
@testable import MonitorKit

/// 子プロセスの代役。`exit(_:)` で終了させる。
private final class FakeChild: MonitorChildProcess, @unchecked Sendable {
    let pid: Int32
    let script: String
    private let lock = NSLock()
    private var code: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private var receivedSignals: [Int32] = []
    /// true の間は先頭が終わってもグループ（tsx / node 役）が残る。
    private var lingering = false
    /// 届いても終わらないシグナル（SIGTERM を無視する子の代役）。
    var ignored: Set<Int32> = []

    init(pid: Int32, script: String) {
        self.pid = pid
        self.script = script
    }

    var hasExited: Bool { lock.withLock { code != nil } }
    var signals: [Int32] { lock.withLock { receivedSignals } }
    var terminated: Bool { signals.contains(SIGTERM) }

    func exit(_ value: Int32, leavingGroup: Bool = false) {
        let pending: [CheckedContinuation<Int32, Never>] = lock.withLock {
            guard code == nil else { return [] }
            code = value
            lingering = leavingGroup
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume(returning: value) }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { c in
            lock.lock()
            if let code { lock.unlock(); c.resume(returning: code) } else { waiters.append(c); lock.unlock() }
        }
    }

    func signalGroup(_ signal: Int32) {
        let ignoring = lock.withLock { () -> Bool in
            receivedSignals.append(signal)
            if ignored.contains(signal) { return true }
            lingering = false
            return false
        }
        if !ignoring { exit(128 + signal) }
    }

    var isGroupAlive: Bool { lock.withLock { code == nil || lingering } }
}

/// スクリプトごとに終了コードを決めて即終了させる。`npm start` と `holding` に含まれる手順は動き続ける。
private final class FakeRunner: MonitorProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var children: [FakeChild] = []
    private var envs: [[String: String]] = []
    var exitCodes: [String: Int32] = [:]
    var holding: Set<String> = []
    var serverExitsWith: Int32?
    /// サーバーが落ちたとき、グループに子が残る。
    var serverLeavesGroup = false
    /// サーバー（のグループ）が SIGTERM を無視する。
    var serverIgnoresTerm = false

    func spawn(script: String, directory: URL, environment: [String: String], logURL: URL?) throws -> any MonitorChildProcess {
        let child = lock.withLock { () -> FakeChild in
            let c = FakeChild(pid: Int32(1000 + children.count), script: script)
            children.append(c)
            envs.append(environment)
            return c
        }
        if script.hasSuffix("npm start") {
            if serverIgnoresTerm { child.ignored = [SIGTERM] }
            if let code = serverExitsWith { child.exit(code, leavingGroup: serverLeavesGroup) }
        } else if !holding.contains(where: { script.hasSuffix($0) }) {
            let code = exitCodes.first(where: { script.contains($0.key) })?.value ?? 0
            child.exit(code)
        }
        return child
    }

    var spawned: [FakeChild] { lock.withLock { children } }
    var environments: [[String: String]] { lock.withLock { envs } }
    var commands: [String] { spawned.map(\.script) }
    func count(_ suffix: String) -> Int { commands.filter { $0.hasSuffix(suffix) }.count }
}

/// 呼ばれた回数で結果を変える health。`beforeAnswer` で呼び出しの途中に割り込める。
private final class HealthScript: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool]
    private var calls = 0
    var beforeAnswer: (@Sendable (Int) async -> Void)?

    init(_ answers: [Bool]) { self.answers = answers }

    func next() async -> Bool {
        let n = lock.withLock { () -> Int in calls += 1; return calls }
        await beforeAnswer?(n)
        return lock.withLock { answers.count > 1 ? answers.removeFirst() : (answers.first ?? false) }
    }
}

/// 開くまで呼び出し側を止める門。
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waitingCount: Int { lock.withLock { waiters.count } }

    func pass() async {
        await withCheckedContinuation { c in
            lock.lock()
            if isOpen { lock.unlock(); c.resume() } else { waiters.append(c); lock.unlock() }
        }
    }

    func open() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

/// 存在するファイルの集合。
private final class FakeFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String>
    init(_ paths: Set<String>) { self.paths = paths }
    func exists(_ path: String) -> Bool { lock.withLock { paths.contains(path) } }
    func create(_ path: String) { _ = lock.withLock { paths.insert(path) } }
    func remove(_ path: String) { _ = lock.withLock { paths.remove(path) } }
}

@MainActor
final class MonitorLauncherTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/tmp/ai-manager/monitor")

    private func path(_ relative: String) -> String { dir.appendingPathComponent(relative).path }

    private func makeLauncher(health: HealthScript, portOpen: Bool = false, files: FakeFiles,
                              runner: FakeRunner, baseURL: URL = MonitorConfiguration.defaultBaseURL,
                              env: [String: String] = [:]) -> MonitorLauncher {
        let environment = MonitorLauncherEnvironment(
            isHealthy: { await health.next() },
            isPortOpen: { _ in portOpen },
            fileExists: { files.exists($0) },
            createFile: { files.create($0) },
            removeFile: { files.remove($0) },
            runner: runner,
            processEnvironment: env
        )
        let launcher = MonitorLauncher(configuration: MonitorConfiguration(baseURL: baseURL),
                                       monitorDirectory: dir, logURL: nil, environment: environment)
        launcher.pollInterval = 0.01
        launcher.terminationGrace = 0.2
        return launcher
    }

    private func makeLauncher(health: [Bool], portOpen: Bool = false, existing: Set<String>,
                              runner: FakeRunner, baseURL: URL = MonitorConfiguration.defaultBaseURL,
                              env: [String: String] = [:]) -> MonitorLauncher {
        makeLauncher(health: HealthScript(health), portOpen: portOpen, files: FakeFiles(existing),
                     runner: runner, baseURL: baseURL, env: env)
    }

    private var ready: Set<String> {
        [path("package.json"), path(MonitorLauncher.installCompleteFile), path(MonitorLauncher.buildOutputFile)]
    }

    /// 条件が満たされるまで待つ。期限を過ぎたら失敗にして抜ける。
    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("待ち切れません: \(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testUsesExistingMonitorWithoutSpawning() async {
        let runner = FakeRunner()
        let launcher = makeLauncher(health: [true], existing: ready, runner: runner)
        await launcher.run()
        XCTAssertEqual(launcher.phase, .usingExisting)
        XCTAssertTrue(runner.commands.isEmpty)
        await launcher.stop()
        XCTAssertEqual(launcher.phase, .usingExisting, "既存の monitor は止めない")
    }

    func testSkipsRemoteHost() async {
        let runner = FakeRunner()
        let launcher = makeLauncher(health: [false], existing: ready, runner: runner,
                                    baseURL: URL(string: "http://192.168.1.5:8766")!)
        await launcher.run()
        XCTAssertEqual(launcher.phase, .skippedRemote(host: "192.168.1.5"))
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testPortInUseByOtherProcess() async {
        let runner = FakeRunner()
        let launcher = makeLauncher(health: [false], portOpen: true, existing: ready, runner: runner)
        await launcher.run()
        XCTAssertEqual(launcher.phase, .failed(.portInUse(port: 8766)))
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testMissingMonitorDirectory() async {
        let runner = FakeRunner()
        let launcher = makeLauncher(health: [false], existing: [], runner: runner)
        var reported: MonitorLaunchFailure?
        launcher.onFailure = { reported = $0 }
        await launcher.run()
        XCTAssertEqual(launcher.phase, .failed(.monitorDirectoryMissing(path: dir.path)))
        XCTAssertEqual(reported, .monitorDirectoryMissing(path: dir.path))
    }

    func testNodeNotFound() async {
        let runner = FakeRunner()
        runner.exitCodes = ["command -v node": 1]
        let launcher = makeLauncher(health: [false], existing: ready, runner: runner)
        await launcher.run()
        XCTAssertEqual(launcher.phase, .failed(.nodeNotFound))
        XCTAssertEqual(runner.commands.count, 1)
    }

    func testInstallsAndBuildsBeforeStartingThenStopsOwnProcess() async {
        let runner = FakeRunner()
        let files = FakeFiles([path("package.json")])
        let launcher = makeLauncher(health: HealthScript([false, false, false, true]), files: files, runner: runner,
                                    env: ["ANTHROPIC_API_KEY": "x", "ANTHROPIC_AUTH_TOKEN": "y", "MONITOR_LAN": "1", "HOME": "/h"])
        let task = Task { await launcher.run() }
        await waitUntil("running") { launcher.phase == .running(pid: 1003) }

        XCTAssertEqual(runner.commands.count, 4)
        XCTAssertTrue(runner.commands[1].hasSuffix("exec npm install"))
        XCTAssertTrue(runner.commands[2].hasSuffix("exec npm run build"))
        XCTAssertTrue(runner.commands[3].hasSuffix("exec npm start"))
        XCTAssertTrue(runner.commands[3].hasPrefix("unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN MONITOR_LAN"))
        for env in runner.environments {
            XCTAssertNil(env["ANTHROPIC_API_KEY"])
            XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
            XCTAssertNil(env["MONITOR_LAN"])
            XCTAssertEqual(env["PORT"], "8766")
            XCTAssertEqual(env["HOME"], "/h")
        }
        XCTAssertEqual(launcher.ownedPid, 1003)
        XCTAssertFalse(files.exists(path(MonitorLauncher.installIncompleteMarker)), "完了したら印を消す")
        XCTAssertFalse(files.exists(path(MonitorLauncher.buildIncompleteMarker)))

        await launcher.stop()
        await task.value
        XCTAssertEqual(launcher.phase, .stopped)
        XCTAssertTrue(runner.spawned[3].terminated)
        XCTAssertNil(launcher.ownedPid)
    }

    func testStepFailureIsReported() async {
        let runner = FakeRunner()
        runner.exitCodes = ["npm install": 1]
        let launcher = makeLauncher(health: [false], existing: [path("package.json")], runner: runner)
        await launcher.run()
        XCTAssertEqual(launcher.phase, .failed(.stepFailed(step: "npm install", exitCode: 1)))
    }

    /// 途中で止めた install は印が残り、次回は node_modules があってもやり直す。
    func testInterruptedInstallIsRerun() async {
        let runner = FakeRunner()
        runner.holding = ["npm install"]
        let files = FakeFiles([path("package.json")])
        let launcher = makeLauncher(health: HealthScript([false]), files: files, runner: runner)
        launcher.start()
        await waitUntil("install 開始") { runner.count("npm install") == 1 }
        XCTAssertTrue(files.exists(path(MonitorLauncher.installIncompleteMarker)))
        await launcher.stop()
        XCTAssertTrue(runner.spawned[1].terminated)
        XCTAssertEqual(launcher.phase, .stopped)

        // npm が途中まで書いた状態（.package-lock.json と ui/dist はある）を再現する。
        files.create(path(MonitorLauncher.installCompleteFile))
        files.create(path(MonitorLauncher.buildOutputFile))
        let next = FakeRunner()
        let relaunched = makeLauncher(health: HealthScript([false, false, true]), files: files, runner: next)
        relaunched.start()
        await waitUntil("running") { relaunched.ownedPid != nil && relaunched.phase == .running(pid: relaunched.ownedPid!) }
        XCTAssertEqual(next.count("npm install"), 1, "中断された install はやり直す")
        XCTAssertEqual(next.count("npm run build"), 0)
        XCTAssertFalse(files.exists(path(MonitorLauncher.installIncompleteMarker)))
        await relaunched.stop()
    }

    func testInterruptedBuildIsRerun() async {
        let runner = FakeRunner()
        let files = FakeFiles(ready.union([path(MonitorLauncher.buildIncompleteMarker)]))
        let launcher = makeLauncher(health: HealthScript([false, false, true]), files: files, runner: runner)
        launcher.start()
        await waitUntil("npm start") { runner.count("npm start") == 1 }
        XCTAssertEqual(runner.count("npm install"), 0)
        XCTAssertEqual(runner.count("npm run build"), 1)
        XCTAssertFalse(files.exists(path(MonitorLauncher.buildIncompleteMarker)))
        await launcher.stop()
    }

    /// 準備後の health 確認の最中に止められたら npm start を起動しない。
    func testStopDuringFinalHealthCheckDoesNotSpawnServer() async {
        let runner = FakeRunner()
        let health = HealthScript([false])
        let launcher = makeLauncher(health: health, files: FakeFiles(ready), runner: runner)
        health.beforeAnswer = { call in
            if call == 2 { await launcher.stop() }
        }
        await launcher.run()
        XCTAssertEqual(runner.count("npm start"), 0)
        XCTAssertEqual(runner.commands.count, 1, "node の確認だけ")
        XCTAssertNil(launcher.ownedPid)
    }

    /// stop 直後の start で、古い実行が新しい実行と並んで動き出さない。
    func testRestartAfterStopDoesNotResurrectOldRun() async {
        let runner = FakeRunner()
        let gate = Gate()
        let health = HealthScript([false])
        health.beforeAnswer = { call in
            if call <= 2 { await gate.pass() }
        }
        let launcher = makeLauncher(health: health, files: FakeFiles(ready), runner: runner)
        launcher.startupTimeout = 30
        var failures: [MonitorLaunchFailure] = []
        launcher.onFailure = { failures.append($0) }

        launcher.start()
        await waitUntil("1 回目の health 待ち") { gate.waitingCount == 1 }
        await launcher.stop()
        launcher.start()
        await waitUntil("2 回目の health 待ち") { gate.waitingCount == 2 }
        gate.open()

        await waitUntil("starting") {
            if case .starting = launcher.phase { return true }
            return false
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(runner.count("command -v node >/dev/null && command -v npm >/dev/null"), 1, "古い実行は何も起動しない")
        XCTAssertEqual(runner.count("npm start"), 1)
        XCTAssertTrue(failures.isEmpty)
        await launcher.stop()
        XCTAssertTrue(runner.spawned.last?.terminated ?? false)
    }

    /// health 待ちの間に npm（先頭）だけ落ちても、残った tsx / node をグループごと止める。
    func testServerExitBeforeHealthyCleansUpGroup() async {
        let runner = FakeRunner()
        runner.serverExitsWith = 1
        runner.serverLeavesGroup = true
        let launcher = makeLauncher(health: [false], existing: ready, runner: runner)
        await launcher.run()
        XCTAssertEqual(launcher.phase, .failed(.processExited(exitCode: 1)))
        XCTAssertEqual(runner.spawned.last?.signals.first, SIGTERM)
        XCTAssertFalse(runner.spawned.last?.isGroupAlive ?? true)
    }

    func testServerExitAfterRunningCleansUpGroup() async {
        let runner = FakeRunner()
        let launcher = makeLauncher(health: [false, false, true], existing: ready, runner: runner)
        launcher.start()
        await waitUntil("running") { launcher.phase == .running(pid: 1001) }
        runner.spawned[1].exit(1, leavingGroup: true)
        await waitUntil("failed") { launcher.phase == .failed(.processExited(exitCode: 1)) }
        XCTAssertEqual(runner.spawned[1].signals.first, SIGTERM)
        XCTAssertNil(launcher.ownedPid)
    }

    func testHealthTimeoutKillsOwnProcess() async {
        let runner = FakeRunner()
        let launcher = makeLauncher(health: [false], existing: ready, runner: runner)
        launcher.startupTimeout = 0.05
        await launcher.run()
        XCTAssertEqual(launcher.phase, .failed(.healthTimeout(seconds: 0)))
        XCTAssertTrue(runner.spawned.last?.terminated ?? false)
        XCTAssertFalse(launcher.hasOwnedProcess)
    }

    /// health タイムアウト後の片付け中も持ち主のままで、その間の終了で SIGKILL まで届く。
    func testCleanupAfterHealthTimeoutStaysOwned() async {
        let runner = FakeRunner()
        runner.serverIgnoresTerm = true
        let launcher = makeLauncher(health: [false], existing: ready, runner: runner)
        launcher.startupTimeout = 0.05
        launcher.terminationGrace = 30
        launcher.start()
        await waitUntil("SIGTERM") { runner.spawned.count == 2 && runner.spawned[1].signals.contains(SIGTERM) }
        XCTAssertTrue(launcher.hasOwnedProcess, "片付け中も停止対象")
        launcher.stopImmediately()
        XCTAssertEqual(runner.spawned[1].signals, [SIGTERM, SIGTERM, SIGKILL])
        XCTAssertFalse(runner.spawned[1].isGroupAlive)
        XCTAssertFalse(launcher.hasOwnedProcess)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(launcher.phase, .stopped, "片付けの続きが失敗を書き込まない")
    }

    /// npm だけ落ちて残ったグループを片付けている間も持ち主のまま。
    func testCleanupAfterServerExitStaysOwned() async {
        let runner = FakeRunner()
        runner.serverExitsWith = 1
        runner.serverLeavesGroup = true
        runner.serverIgnoresTerm = true
        let launcher = makeLauncher(health: [false], existing: ready, runner: runner)
        launcher.terminationGrace = 30
        launcher.start()
        await waitUntil("SIGTERM") { runner.spawned.count == 2 && runner.spawned[1].signals.contains(SIGTERM) }
        XCTAssertNil(launcher.ownedPid, "先頭は終了済み")
        XCTAssertTrue(launcher.hasOwnedProcess, "片付け中も停止対象")
        launcher.terminationGrace = 0.2
        let stopped = expectation(description: "停止完了")
        launcher.stopInBackground { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(runner.spawned[1].signals.last, SIGKILL)
        XCTAssertFalse(launcher.hasOwnedProcess)
    }

    /// キャンセル済みのタスクから呼んでも猶予を守り、main actor を止めない。
    func testTerminateFromCancelledTaskKeepsGraceWithoutBlockingMain() async {
        let child = FakeChild(pid: 1, script: "npm start")
        child.ignored = [SIGTERM]
        let task = Task { @MainActor () -> TimeInterval in
            withUnsafeCurrentTask { $0?.cancel() }
            let started = Date()
            await MonitorLauncher.terminate(child, grace: 0.3)
            return Date().timeIntervalSince(started)
        }
        var ticks = 0
        let until = Date().addingTimeInterval(0.2)
        while Date() < until {
            try? await Task.sleep(nanoseconds: 10_000_000)
            ticks += 1
        }
        let elapsed = await task.value
        XCTAssertGreaterThan(ticks, 5, "待ちの間も main actor が進む")
        XCTAssertGreaterThanOrEqual(elapsed, 0.25)
        XCTAssertEqual(child.signals, [SIGTERM, SIGKILL])
    }

    /// 走り出す前に止められた実行は phase を書き換えない。
    func testStopBeforeRunStartsLeavesPhase() async {
        let runner = FakeRunner()
        let launcher = makeLauncher(health: [false], existing: ready, runner: runner,
                                    baseURL: URL(string: "http://192.168.1.5:8766")!)
        launcher.start()
        await launcher.stop()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(launcher.phase, .idle)
    }

    func testTerminationGateRepliesOnceAndKeepsWaiting() {
        let gate = MonitorTerminationGate()
        XCTAssertEqual(gate.decide(needsShutdown: true), .terminateLater(startShutdown: true))
        // 1 回目で子を引き取った後は needsShutdown が false になるが、停止の途中なので抜けない。
        XCTAssertEqual(gate.decide(needsShutdown: false), .terminateLater(startShutdown: false))
        XCTAssertEqual(gate.decide(needsShutdown: true), .terminateLater(startShutdown: false))
        XCTAssertEqual(MonitorTerminationGate().decide(needsShutdown: false), .terminateNow)
    }

    func testChildEnvironmentAndLoopback() {
        let env = MonitorLauncher.childEnvironment(from: ["ANTHROPIC_API_KEY": "k", "MONITOR_LAN": "1", "PATH": "/bin"], port: 8799)
        XCTAssertEqual(env, ["PATH": "/bin", "PORT": "8799"])
        XCTAssertTrue(MonitorLauncher.isLoopback(URL(string: "http://localhost:8766")!))
        XCTAssertTrue(MonitorLauncher.isLoopback(URL(string: "http://127.0.0.1:8799")!))
        XCTAssertFalse(MonitorLauncher.isLoopback(URL(string: "http://example.com:8766")!))
    }

    func testDefaultPortFollowsScheme() {
        XCTAssertEqual(MonitorLauncher.port(of: URL(string: "http://127.0.0.1")!), 80)
        XCTAssertEqual(MonitorLauncher.port(of: URL(string: "https://localhost")!), 443)
        XCTAssertEqual(MonitorLauncher.port(of: URL(string: "https://localhost:8799")!), 8799)
    }

    /// ::1 だけで待ち受けているポートも使用中とみなす。
    func testLoopbackPortSeesIPv6Listener() throws {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        try XCTSkipIf(fd < 0, "IPv6 ソケットを作れない環境")
        defer { close(fd) }
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_addr = in6addr_loopback
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        try XCTSkipIf(bound != 0, "::1 に bind できない環境")
        XCTAssertEqual(listen(fd, 16), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = Int(UInt16(bigEndian: addr.sin6_port))
        XCTAssertTrue(LoopbackPort.isOpen(port))
        XCTAssertTrue(LoopbackPort.isOpenIPv6(port))
        XCTAssertFalse(LoopbackPort.isOpenIPv4(port))
    }

    func testLogFileIsCloseOnExecAndRotates() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: log)
            try? FileManager.default.removeItem(at: log.appendingPathExtension("1"))
        }
        let fd = MonitorLogFile.open(log)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0)
        close(fd)

        MonitorLogFile.append(String(repeating: "x", count: 100), to: log)
        MonitorLogFile.rotateIfNeeded(log, limit: 1000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path), "上限以下なら回さない")
        MonitorLogFile.rotateIfNeeded(log, limit: 50)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertEqual(try String(contentsOf: log.appendingPathExtension("1"), encoding: .utf8).count, 100)
    }

    /// 実プロセスで、孫プロセスまでグループごと止まることを確かめる（ログインシェルの設定に左右されないよう sh を使う）。
    func testPosixRunnerTerminatesWholeGroup() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let child = try PosixProcessRunner(shell: ["/bin/sh", "-c"]).spawn(
            script: "sleep 30 & echo started; wait",
            directory: FileManager.default.temporaryDirectory,
            environment: ["PATH": "/usr/bin:/bin"],
            logURL: log
        )
        await waitUntil("子の書き込み", timeout: 10) {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("started")
        }
        XCTAssertTrue(child.isGroupAlive)
        await MonitorLauncher.terminate(child, grace: 2)
        let code = await child.waitForExit()
        XCTAssertNotEqual(code, 0)
        await waitUntil("グループが空になる") { !child.isGroupAlive }
    }
}
