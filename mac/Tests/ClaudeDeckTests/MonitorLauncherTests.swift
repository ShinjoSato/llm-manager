import XCTest
@testable import MonitorKit

/// 子プロセスの代役。`exit(_:)` で終了させる。
private final class FakeChild: MonitorChildProcess, @unchecked Sendable {
    let pid: Int32
    let script: String
    private let lock = NSLock()
    private var code: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private(set) var terminated = false

    init(pid: Int32, script: String) {
        self.pid = pid
        self.script = script
    }

    var hasExited: Bool { lock.withLock { code != nil } }

    func exit(_ value: Int32) {
        let pending: [CheckedContinuation<Int32, Never>] = lock.withLock {
            code = value
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

    func terminateGroup(grace: TimeInterval) {
        terminated = true
        exit(143)
    }
}

/// スクリプトごとに終了コードを決めて即終了させる。`npm start` だけは動き続ける。
private final class FakeRunner: MonitorProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var spawned: [FakeChild] = []
    private(set) var environments: [[String: String]] = []
    var exitCodes: [String: Int32] = [:]
    var serverExitsWith: Int32?

    func spawn(script: String, directory: URL, environment: [String: String], logURL: URL?) throws -> any MonitorChildProcess {
        let child = lock.withLock { () -> FakeChild in
            let c = FakeChild(pid: Int32(1000 + spawned.count), script: script)
            spawned.append(c)
            environments.append(environment)
            return c
        }
        if script.hasSuffix("npm start") {
            if let code = serverExitsWith { child.exit(code) }
        } else {
            let code = exitCodes.first(where: { script.contains($0.key) })?.value ?? 0
            child.exit(code)
        }
        return child
    }

    var commands: [String] { lock.withLock { spawned.map(\.script) } }
}

/// 呼ばれた回数で結果を変える health。
private final class HealthScript: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool]
    init(_ answers: [Bool]) { self.answers = answers }
    func next() -> Bool {
        lock.withLock { answers.count > 1 ? answers.removeFirst() : (answers.first ?? false) }
    }
}

@MainActor
final class MonitorLauncherTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/tmp/ai-manager/monitor")

    private func makeLauncher(health: [Bool], portOpen: Bool = false, existing: Set<String>,
                              runner: FakeRunner, baseURL: URL = MonitorConfiguration.defaultBaseURL,
                              env: [String: String] = [:]) -> MonitorLauncher {
        let script = HealthScript(health)
        let environment = MonitorLauncherEnvironment(
            isHealthy: { script.next() },
            isPortOpen: { _ in portOpen },
            fileExists: { path in existing.contains(path) },
            runner: runner,
            processEnvironment: env
        )
        let launcher = MonitorLauncher(configuration: MonitorConfiguration(baseURL: baseURL),
                                       monitorDirectory: dir, logURL: nil, environment: environment)
        launcher.pollInterval = 0.01
        return launcher
    }

    private var ready: Set<String> {
        [dir.appendingPathComponent("package.json").path,
         dir.appendingPathComponent("node_modules").path,
         dir.appendingPathComponent("ui/dist/index.html").path]
    }

    func testUsesExistingMonitorWithoutSpawning() async {
        let runner = FakeRunner()
        let launcher = makeLauncher(health: [true], existing: ready, runner: runner)
        await launcher.run()
        XCTAssertEqual(launcher.phase, .usingExisting)
        XCTAssertTrue(runner.commands.isEmpty)
        launcher.stop()
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
        let launcher = makeLauncher(health: [false, false, false, true],
                                    existing: [dir.appendingPathComponent("package.json").path],
                                    runner: runner,
                                    env: ["ANTHROPIC_API_KEY": "x", "ANTHROPIC_AUTH_TOKEN": "y", "MONITOR_LAN": "1", "HOME": "/h"])
        let task = Task { await launcher.run() }
        while launcher.phase != .running(pid: 1003) { await Task.yield() }

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

        launcher.stop()
        await task.value
        XCTAssertEqual(launcher.phase, .stopped)
        XCTAssertTrue(runner.spawned[3].terminated)
        XCTAssertNil(launcher.ownedPid)
    }

    func testStepFailureIsReported() async {
        let runner = FakeRunner()
        runner.exitCodes = ["npm install": 1]
        let launcher = makeLauncher(health: [false], existing: [dir.appendingPathComponent("package.json").path], runner: runner)
        await launcher.run()
        XCTAssertEqual(launcher.phase, .failed(.stepFailed(step: "npm install", exitCode: 1)))
    }

    func testServerExitBeforeHealthy() async {
        let runner = FakeRunner()
        runner.serverExitsWith = 1
        let launcher = makeLauncher(health: [false], existing: ready, runner: runner)
        await launcher.run()
        XCTAssertEqual(launcher.phase, .failed(.processExited(exitCode: 1)))
    }

    func testHealthTimeoutKillsOwnProcess() async {
        let runner = FakeRunner()
        let launcher = makeLauncher(health: [false], existing: ready, runner: runner)
        launcher.startupTimeout = 0.05
        await launcher.run()
        XCTAssertEqual(launcher.phase, .failed(.healthTimeout(seconds: 0)))
        XCTAssertTrue(runner.spawned.last?.terminated ?? false)
    }

    func testChildEnvironmentAndLoopback() {
        let env = MonitorLauncher.childEnvironment(from: ["ANTHROPIC_API_KEY": "k", "MONITOR_LAN": "1", "PATH": "/bin"], port: 8799)
        XCTAssertEqual(env, ["PATH": "/bin", "PORT": "8799"])
        XCTAssertTrue(MonitorLauncher.isLoopback(URL(string: "http://localhost:8766")!))
        XCTAssertTrue(MonitorLauncher.isLoopback(URL(string: "http://127.0.0.1:8799")!))
        XCTAssertFalse(MonitorLauncher.isLoopback(URL(string: "http://example.com:8766")!))
    }

    /// 実プロセスで、孫プロセスまでグループごと止まることを確かめる。
    func testPosixRunnerTerminatesWholeGroup() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-\(UUID().uuidString).log")
        let child = try PosixProcessRunner().spawn(
            script: "sleep 30 & echo started; wait",
            directory: FileManager.default.temporaryDirectory,
            environment: ProcessInfo.processInfo.environment,
            logURL: log
        )
        // ログインシェルの読み込みが遅いので、子が書き始めるまで待つ。
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("started") {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(kill(-child.pid, 0), 0)
        child.terminateGroup(grace: 2)
        let code = await child.waitForExit()
        XCTAssertNotEqual(code, 0)
        XCTAssertEqual(kill(-child.pid, 0), -1, "グループに残りが無い")
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("started"))
    }
}
