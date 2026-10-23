import XCTest
import Darwin
@testable import MonitorKit

/// VS Code のタブが閉じられるのを待つ引き継ぎの状態遷移。
final class HandoverCloseWaitTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testWaitsWhileTheOriginalRuns() {
        var wait = HandoverCloseWait()
        XCTAssertEqual(wait.step(.init(originalAlive: true), now: t0), .wait)
        XCTAssertEqual(wait.phase, .waitingForClose)
        XCTAssertEqual(wait.step(.init(originalAlive: true), now: t0.addingTimeInterval(600)), .wait, "待ちに時間切れは無い")
    }

    func testResumesAfterTheOriginalHasBeenGoneForTheSettle() {
        var wait = HandoverCloseWait()
        _ = wait.step(.init(originalAlive: true), now: t0)
        XCTAssertEqual(wait.step(.init(originalAlive: false), now: t0.addingTimeInterval(1)), .wait)
        XCTAssertEqual(wait.phase, .settling)
        XCTAssertEqual(wait.step(.init(originalAlive: false), now: t0.addingTimeInterval(3)), .wait)
        XCTAssertEqual(wait.step(.init(originalAlive: false), now: t0.addingTimeInterval(3.5)), .resume)
    }

    func testWaitsForAnotherClaudeOfTheSameConversation() {
        var wait = HandoverCloseWait()
        XCTAssertEqual(wait.step(.init(originalAlive: false), now: t0), .wait)
        // 終わった直後に同じ会話の claude が動き出したら、それが終わるまで待ち直す。
        XCTAssertEqual(wait.step(.init(originalAlive: false, otherPid: 200), now: t0.addingTimeInterval(0.5)), .wait)
        XCTAssertEqual(wait.phase, .waitingForOther(200))
        XCTAssertEqual(wait.step(.init(originalAlive: false, otherPid: 200), now: t0.addingTimeInterval(5)), .wait)
        XCTAssertEqual(wait.step(.init(originalAlive: false), now: t0.addingTimeInterval(6)), .wait)
        XCTAssertEqual(wait.step(.init(originalAlive: false), now: t0.addingTimeInterval(8)), .wait)
        XCTAssertEqual(wait.step(.init(originalAlive: false), now: t0.addingTimeInterval(8.5)), .resume)
    }

    func testCancelsWhenTheLimitIsReached() {
        var wait = HandoverCloseWait()
        XCTAssertEqual(wait.step(.init(originalAlive: true, limitReached: true), now: t0), .cancel(.limit))
        var gone = HandoverCloseWait()
        _ = gone.step(.init(originalAlive: false), now: t0)
        XCTAssertEqual(gone.step(.init(originalAlive: false, limitReached: true), now: t0.addingTimeInterval(5)), .cancel(.limit))
    }

    func testCancelsWhenTheAppAlreadyHostsTheConversation() {
        var wait = HandoverCloseWait()
        XCTAssertEqual(wait.step(.init(originalAlive: false, alreadyHosted: true), now: t0), .cancel(.alreadyHosted))
    }

    func testDoesNotResumeWhileQuitting() {
        var wait = HandoverCloseWait()
        _ = wait.step(.init(originalAlive: false), now: t0)
        XCTAssertEqual(wait.step(.init(originalAlive: false, holding: true), now: t0.addingTimeInterval(5)), .wait)
        XCTAssertEqual(wait.step(.init(originalAlive: false), now: t0.addingTimeInterval(5.5)), .resume, "settle は終わった時から数える")
    }
}

/// 待ちの観測と、引き継いだ後の二重起動の判定（プロセスは差し替える）。
final class HandoverObservationTests: XCTestCase {
    private let sid = "acb12868-4061-4d7e-987c-0522878e518d"
    private let start = Date(timeIntervalSince1970: 1_790_848_942)
    private let vscodePath = "/Users/u/.vscode/extensions/anthropic.claude-code-2.1.304/resources/native-binary/claude"

    private func facts(start: Date? = nil) -> ProcessFacts {
        ProcessFacts(uid: 501, startedAt: start ?? self.start, executablePath: vscodePath, argv0: nil, isZombie: false)
    }

    private func record(pid: Int32, sessionId: String? = nil, procStart: String = "Thu Oct  1 10:02:22 2026",
                        entrypoint: String = "claude-vscode") -> ClaudeSessionRecord {
        ClaudeSessionRecord(pid: pid, sessionId: sessionId ?? sid, procStart: procStart, entrypoint: entrypoint, kind: "interactive")
    }

    private var target: HandoverTarget {
        HandoverTarget(pid: 100, sessionId: sid, source: .editorExtension, original: facts())
    }

    func testOriginalIsAliveOnlyWhileItIsTheSameProcess() {
        XCTAssertTrue(SessionHandover.isAlive(target) { _ in self.facts() })
        XCTAssertFalse(SessionHandover.isAlive(target) { _ in nil })
        XCTAssertFalse(SessionHandover.isAlive(target) { _ in
            ProcessFacts(uid: 501, startedAt: self.start, executablePath: nil, argv0: nil, isZombie: true)
        })
        XCTAssertFalse(SessionHandover.isAlive(target) { _ in self.facts(start: self.start.addingTimeInterval(60)) }, "pid の再利用")
    }

    func testObserveCountsOnlyOtherLiveClaudes() {
        let otherStart = Date(timeIntervalSince1970: 1_790_850_000)
        let records = [record(pid: 100), record(pid: 200, procStart: "Thu Oct  1 10:20:00 2026"),
                       record(pid: 300, sessionId: "bcb12868-4061-4d7e-987c-0522878e518d")]
        var alive: Set<Int32> = [100, 200, 300]
        let inspect: (Int32) -> ProcessFacts? = { pid in
            guard alive.contains(pid) else { return nil }
            return pid == 200 ? self.facts(start: otherStart) : self.facts()
        }
        var observation = HandoverCloseWait.observe(target, records: records, inspect: inspect, limitReached: false, holding: false,
                                                    alreadyHosted: false)
        XCTAssertTrue(observation.originalAlive)
        XCTAssertEqual(observation.otherPid, 200)

        alive = [200, 300]
        observation = HandoverCloseWait.observe(target, records: records, inspect: inspect, limitReached: true, holding: true,
                                                alreadyHosted: true)
        XCTAssertEqual(observation, .init(originalAlive: false, otherPid: 200, limitReached: true, holding: true, alreadyHosted: true))

        alive = [300]
        observation = HandoverCloseWait.observe(target, records: records, inspect: inspect, limitReached: false, holding: false,
                                                alreadyHosted: false)
        XCTAssertEqual(observation, .init(originalAlive: false))
    }

    func testOriginalSwitchedToAnotherConversationCountsAsGone() {
        // 同じプロセス（pid 100・起動時刻も同じ）のまま、記録の sessionId だけが別の会話に替わった。
        let records = [record(pid: 100, sessionId: "bcb12868-4061-4d7e-987c-0522878e518d")]
        let observation = HandoverCloseWait.observe(target, records: records) { _ in self.facts() }
        XCTAssertEqual(observation, .init(originalAlive: false))
        var wait = HandoverCloseWait()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(wait.step(observation, now: t0), .wait)
        XCTAssertEqual(wait.step(observation, now: t0.addingTimeInterval(HandoverCloseWait.settle)), .resume)
        // 記録が同じ会話のままなら待ち続ける。
        XCTAssertTrue(HandoverCloseWait.observe(target, records: [record(pid: 100)]) { _ in self.facts() }.originalAlive)
    }

    func testFindsTheExternalDuplicateButNotTheHostedClaude() {
        let records = [record(pid: 100, entrypoint: "cli"), record(pid: 200, procStart: "Thu Oct  1 10:20:00 2026")]
        let otherStart = Date(timeIntervalSince1970: 1_790_850_000)
        let inspect: (Int32) -> ProcessFacts? = { pid in pid == 200 ? self.facts(start: otherStart) : self.facts() }
        // 100 はアプリがホストしている claude。
        let duplicate = ExternalDuplicate.find(sessionId: sid, hostedPids: [100], records: records, inspect: inspect)
        XCTAssertEqual(duplicate, ExternalDuplicate(pid: 200, entrypoint: "claude-vscode"))
        XCTAssertNil(ExternalDuplicate.find(sessionId: sid, hostedPids: [100, 200], records: records, inspect: inspect))
        XCTAssertNil(ExternalDuplicate.find(sessionId: sid, hostedPids: [100], records: records) { pid in pid == 200 ? nil : self.facts() },
                     "終わった claude の残骸は数えない")
        XCTAssertNil(ExternalDuplicate.find(sessionId: sid, hostedPids: [100], records: records) { _ in self.facts() },
                     "記録と起動時刻が合わないもの（pid の再利用）は数えない")
    }

    func testDuplicateWordingNamesWhereItRuns() {
        let vscode = ExternalDuplicate(pid: 200, entrypoint: "claude-vscode")
        XCTAssertTrue(vscode.warning.hasPrefix("VS Code で同じ会話が動き出しました"))
        XCTAssertTrue(vscode.warning.contains("VS Code のタブを閉じてください"))
        XCTAssertTrue(vscode.sendBlockedReason.contains("VS Code"))
        XCTAssertTrue(ExternalDuplicate(pid: 200, entrypoint: "cli").warning.hasPrefix("ターミナルで"))
        XCTAssertTrue(ExternalDuplicate(pid: 200, entrypoint: nil).warning.hasPrefix("このアプリの外で"))
    }
}

/// VS Code の拡張の場所をまねた一時フォルダに置いた小さなプロセスを相手に、確かめ・止めて引き継ぐ・タブを閉じたら引き継ぐ・二重の判定を通す。
/// シグナルを送るのはここで起動したプロセスだけ。再開（claude の起動）はせず、呼ばれた回数だけを数える。
final class HandoverDummyProcessTests: XCTestCase {
    private let sid = "acb12868-4061-4d7e-987c-0522878e518d"
    private var root: URL!
    private var binary: URL!
    private var registry: ClaudeSessionRegistry!
    private var launched: [Dummy] = []

    /// 起動したダミー。終わっても回収するまではゾンビとして残る（引き継ぎの判定はゾンビを終わったものとみなす）。
    private final class Dummy {
        let pid: pid_t
        private var reaped = false
        init(pid: pid_t) { self.pid = pid }

        var isRunning: Bool { !reaped && ProcessFacts.inspect(pid: pid).map { !$0.isZombie } == true }

        /// 終わるのを待って回収し、終わらせたシグナル（自分で終わったら 0）を返す。
        @discardableResult
        func waitForExit() -> Int32 {
            guard !reaped else { return -1 }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            reaped = true
            return status & 0x7f
        }

        func stop() {
            guard !reaped else { return }
            kill(pid, SIGKILL)
            waitForExit()
        }
    }

    /// クラスで 1 回だけビルドしたダミー（無ければ飛ばす理由）。
    nonisolated(unsafe) private static var builtDummy: URL?
    nonisolated(unsafe) private static var buildFolder: URL?
    nonisolated(unsafe) private static var skipReason: String?

    override class func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("handover-build-\(UUID().uuidString)")
        buildFolder = folder
        do {
            builtDummy = try buildDummy(in: folder)
        } catch {
            skipReason = "ダミーのプロセスを作れません: \(error)"
        }
    }

    override class func tearDown() {
        if let buildFolder { try? FileManager.default.removeItem(at: buildFolder) }
        super.tearDown()
    }

    override func setUpWithError() throws {
        guard let built = Self.builtDummy else { throw XCTSkip(Self.skipReason ?? "ダミーのプロセスがありません") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("handover-\(UUID().uuidString)")
        binary = root.appendingPathComponent(".vscode/extensions/anthropic.claude-code-9.9.9-darwin-arm64/resources/native-binary/claude")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: built, to: binary)
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        registry = ClaudeSessionRegistry(directory: sessions)
    }

    override func tearDownWithError() throws {
        for dummy in launched { dummy.stop() }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// 秒数だけ眠る小さなプログラム（引数: 秒数・ignore なら SIGINT / SIGTERM を無視・用意ができたら作るファイル）。
    /// OS のコマンドの写しは別の場所から動かすと OS に止められるので、その場でビルドする。
    private static let dummySource = """
        #include <fcntl.h>
        #include <signal.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
            if (argc < 4) return 2;
            unsigned left = (unsigned)atoi(argv[1]);
            if (strcmp(argv[2], "ignore") == 0) { signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN); }
            close(open(argv[3], O_CREAT | O_WRONLY, 0600));
            while (left > 0) left = sleep(left);
            return 0;
        }
        """

    private struct BuildFailure: Error, CustomStringConvertible {
        var description: String
    }

    /// clang の有無を先に xcrun で確かめる（`/usr/bin/cc` のスタブを叩くと導入のダイアログが出うるため）。
    private static func buildDummy(in folder: URL) throws -> URL {
        guard let clang = run("/usr/bin/xcrun", ["--find", "clang"]), !clang.isEmpty else {
            throw BuildFailure(description: "clang が見つかりません")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("dummy.c")
        let output = folder.appendingPathComponent("dummy")
        try dummySource.write(to: source, atomically: true, encoding: .utf8)
        guard run(clang, ["-o", output.path, source.path]) != nil else { throw BuildFailure(description: "ビルドに失敗しました") }
        return output
    }

    /// 終了コードが 0 なら標準出力（前後の空白を除く）、それ以外は nil。
    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// VS Code の拡張の場所に置いたダミーの claude を起動する。
    private func launchDummy(seconds: Int, ignoringSignals: Bool = false) throws -> Dummy {
        let ready = root.appendingPathComponent("ready-\(UUID().uuidString)")
        let arguments = [binary.path, "\(seconds)", ignoringSignals ? "ignore" : "default", ready.path]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        // 親（テストの実行器）のシグナルの無視・塞ぎを持ち込まず、既定の扱いで起動する。
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var empty = sigset_t()
        sigemptyset(&empty)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attributes, &empty)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        var pid: pid_t = 0
        let result = posix_spawn(&pid, binary.path, nil, &attributes, argv, environ)
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        let dummy = Dummy(pid: pid)
        launched.append(dummy)
        // 初回の起動は署名の確かめで遅いことがあるので、シグナルの扱いを決め終えるまで待つ。
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline { usleep(20_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "ダミーの用意ができない")
        XCTAssertTrue(ProcessFacts.inspect(pid: pid)?.executablePath?.hasSuffix("/native-binary/claude") == true)
        return dummy
    }

    private func writeRecord(for dummy: Dummy, entrypoint: String = "claude-vscode", startOffset: TimeInterval = 0) throws {
        let pid = dummy.pid
        let facts = try XCTUnwrap(ProcessFacts.inspect(pid: pid))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let record = ClaudeSessionRecord(pid: pid, sessionId: sid, cwd: root.path,
                                         procStart: formatter.string(from: facts.startedAt.addingTimeInterval(startOffset)),
                                         entrypoint: entrypoint, kind: "interactive")
        try JSONEncoder().encode(record).write(to: registry.directory.appendingPathComponent("\(pid).json"))
    }

    private func check(_ dummy: Dummy) -> SessionHandover.TargetCheck {
        let pid = dummy.pid
        return SessionHandover.checkTarget(pid: pid, sessionId: sid, record: registry.record(forPid: pid),
                                           facts: ProcessFacts.inspect(pid: pid), ownUid: getuid())
    }

    /// 送り先を起動したダミーに限った終了処理。
    private func terminator(allowed: Set<Int32>) -> SessionTerminator {
        let registry = registry!
        var terminator = SessionTerminator(record: { registry.record(forPid: $0) }, records: { registry.allRecords() },
                                           signal: { pid, sig in
                                               precondition(allowed.contains(pid), "起動したダミー以外にシグナルを送ろうとした")
                                               _ = kill(pid, sig)
                                           })
        terminator.interruptGrace = .seconds(2)
        terminator.terminateGrace = .seconds(2)
        terminator.pollInterval = .milliseconds(50)
        return terminator
    }

    func testRecognizesTheDummyAsVSCodeClaude() throws {
        let dummy = try launchDummy(seconds: 30)
        try writeRecord(for: dummy)
        guard case .ok(let target) = check(dummy) else { return XCTFail("\(check(dummy))") }
        XCTAssertEqual(target.source, .editorExtension)
        XCTAssertEqual(target.pid, dummy.pid)
    }

    func testRefusesTheDummyWhenTheRecordDoesNotMatch() throws {
        let dummy = try launchDummy(seconds: 30)
        try writeRecord(for: dummy, startOffset: 3600)
        guard case .refused = check(dummy) else { return XCTFail("起動時刻の合わない記録を通した") }
        try writeRecord(for: dummy, entrypoint: "claude-desktop")
        guard case .refused = check(dummy) else { return XCTFail("VS Code・ターミナル以外を通した") }
        XCTAssertTrue(dummy.isRunning)
    }

    func testStopsTheDummyAndHandsOver() async throws {
        let dummy = try launchDummy(seconds: 30)
        try writeRecord(for: dummy)
        guard case .ok = check(dummy) else { return XCTFail("\(check(dummy))") }
        var resumed = 0
        let outcome = await terminator(allowed: [dummy.pid]).terminate(pid: dummy.pid, sessionId: sid)
        if outcome == .exited { resumed += 1 }
        XCTAssertEqual(outcome, .exited)
        XCTAssertEqual(resumed, 1)
        XCTAssertEqual(dummy.waitForExit(), SIGINT)
    }

    func testDoesNotHandOverWhenTheDummyIgnoresSignals() async throws {
        let dummy = try launchDummy(seconds: 30, ignoringSignals: true)
        try writeRecord(for: dummy)
        let outcome = await terminator(allowed: [dummy.pid]).terminate(pid: dummy.pid, sessionId: sid)
        XCTAssertEqual(outcome, .stillRunning)
        XCTAssertTrue(dummy.isRunning)
    }

    func testHandsOverAfterTheDummyClosesByItself() async throws {
        let dummy = try launchDummy(seconds: 3)
        try writeRecord(for: dummy)
        guard case .ok(let target) = check(dummy) else { return XCTFail("\(check(dummy))") }
        var wait = HandoverCloseWait()
        var resumedWhileAlive = false
        var resumed = false
        let deadline = Date().addingTimeInterval(20)
        while !resumed, Date() < deadline {
            let observation = HandoverCloseWait.observe(target, records: registry.allRecords(), inspect: ProcessFacts.inspect,
                                                        limitReached: false, holding: false, alreadyHosted: false)
            if wait.step(observation, now: Date()) == .resume {
                resumed = true
                resumedWhileAlive = dummy.isRunning
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(resumed)
        XCTAssertFalse(resumedWhileAlive)
    }

    func testWaitsForAnotherDummyOfTheSameConversation() async throws {
        let original = try launchDummy(seconds: 30)
        try writeRecord(for: original)
        guard case .ok(let target) = check(original) else { return XCTFail("\(check(original))") }
        let other = try launchDummy(seconds: 30)
        try writeRecord(for: other)
        original.stop()

        var wait = HandoverCloseWait()
        func step() -> HandoverCloseWait.Step {
            wait.step(HandoverCloseWait.observe(target, records: registry.allRecords(), inspect: ProcessFacts.inspect,
                                                limitReached: false, holding: false, alreadyHosted: false), now: Date())
        }
        XCTAssertEqual(step(), .wait)
        XCTAssertEqual(wait.phase, .waitingForOther(other.pid))

        other.stop()
        XCTAssertEqual(step(), .wait)
        XCTAssertEqual(wait.phase, .settling)
        try await Task.sleep(for: .seconds(HandoverCloseWait.settle + 0.1))
        XCTAssertEqual(step(), .resume)
    }

    func testWarnsWhileTheSameConversationRunsOutsideAfterHandover() throws {
        let hosted = try launchDummy(seconds: 30)
        try writeRecord(for: hosted, entrypoint: "cli")
        let hostedPids: Set<Int32> = [hosted.pid]
        XCTAssertNil(ExternalDuplicate.find(sessionId: sid, hostedPids: hostedPids, records: registry.allRecords(),
                                            inspect: ProcessFacts.inspect))

        let vscode = try launchDummy(seconds: 30)
        try writeRecord(for: vscode)
        let duplicate = ExternalDuplicate.find(sessionId: sid, hostedPids: hostedPids, records: registry.allRecords(),
                                               inspect: ProcessFacts.inspect)
        XCTAssertEqual(duplicate, ExternalDuplicate(pid: vscode.pid, entrypoint: "claude-vscode"))

        vscode.stop()
        // 記録の残骸があっても、終わったものは数えない（警告と送信の止めを外す）。
        XCTAssertNil(ExternalDuplicate.find(sessionId: sid, hostedPids: hostedPids, records: registry.allRecords(),
                                            inspect: ProcessFacts.inspect))
    }
}
