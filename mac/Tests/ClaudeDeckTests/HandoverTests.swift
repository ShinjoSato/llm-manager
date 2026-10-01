import XCTest
import Darwin
@testable import MonitorKit

final class SessionIdValidationTests: XCTestCase {
    func testAcceptsUUID() {
        XCTAssertTrue(SessionHandover.isValidSessionId("acb12868-4061-4d7e-987c-0522878e518d"))
    }

    func testRejectsShellMetacharacters() {
        for bad in ["", "a b", "a;rm -rf ~", "$(id)", "`id`", "a\nb", "../x", "a'b", "ａ", String(repeating: "a", count: 129)] {
            XCTAssertFalse(SessionHandover.isValidSessionId(bad), bad)
        }
    }
}

final class HandoverVerifyTests: XCTestCase {
    private let uid: uid_t = 501
    private let start = Date(timeIntervalSince1970: 1_790_848_942)
    private let sid = "acb12868-4061-4d7e-987c-0522878e518d"

    private func facts(uid: uid_t = 501, start: Date? = nil, path: String = "/Users/u/.local/share/claude/versions/2.1.286",
                       argv0: String? = "claude", zombie: Bool = false) -> ProcessFacts {
        ProcessFacts(uid: uid, startedAt: start ?? self.start, executablePath: path, argv0: argv0, isZombie: zombie)
    }

    private func record(pid: Int32 = 100, sessionId: String? = nil, procStart: String? = "Thu Oct  1 10:02:22 2026",
                        startedAt: Double? = 1_790_848_951_291) -> ClaudeSessionRecord {
        ClaudeSessionRecord(pid: pid, sessionId: sessionId ?? sid, cwd: "/tmp", startedAt: startedAt, procStart: procStart)
    }

    func testOkWhenEverythingMatches() {
        XCTAssertEqual(SessionHandover.verify(pid: 100, sessionId: sid, record: record(), facts: facts(), ownUid: uid), .ok)
    }

    func testProcStartIsUTC() {
        XCTAssertEqual(SessionHandover.parseProcStart("Thu Oct  1 10:02:22 2026"), start)
    }

    func testGoneProcessIsNotRunning() {
        XCTAssertEqual(SessionHandover.verify(pid: 100, sessionId: sid, record: nil, facts: nil, ownUid: uid), .notRunning)
        XCTAssertEqual(SessionHandover.verify(pid: 100, sessionId: sid, record: record(), facts: facts(zombie: true), ownUid: uid),
                       .notRunning)
    }

    func testRefusesOtherUsersProcess() {
        XCTAssertNotEqual(SessionHandover.verify(pid: 100, sessionId: sid, record: record(), facts: facts(uid: 0), ownUid: uid), .ok)
    }

    func testRefusesNonClaudeProcess() {
        let other = facts(path: "/bin/zsh", argv0: "-zsh")
        XCTAssertNotEqual(SessionHandover.verify(pid: 100, sessionId: sid, record: record(), facts: other, ownUid: uid), .ok)
    }

    func testRefusesWhenRegistryIsMissingOrForAnotherSession() {
        XCTAssertNotEqual(SessionHandover.verify(pid: 100, sessionId: sid, record: nil, facts: facts(), ownUid: uid), .ok)
        XCTAssertNotEqual(SessionHandover.verify(pid: 100, sessionId: sid, record: record(sessionId: "other"), facts: facts(), ownUid: uid), .ok)
        XCTAssertNotEqual(SessionHandover.verify(pid: 100, sessionId: sid, record: record(pid: 101), facts: facts(), ownUid: uid), .ok)
    }

    func testRefusesReusedPid() {
        // 記録が残ったまま pid が別の claude に再利用された（起動時刻が違う）。
        let reused = facts(start: start.addingTimeInterval(3600))
        XCTAssertNotEqual(SessionHandover.verify(pid: 100, sessionId: sid, record: record(), facts: reused, ownUid: uid), .ok)
    }

    func testFallsBackToStartedAtWithoutProcStart() {
        XCTAssertEqual(SessionHandover.verify(pid: 100, sessionId: sid, record: record(procStart: nil), facts: facts(), ownUid: uid), .ok)
        let late = record(procStart: nil, startedAt: start.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        XCTAssertNotEqual(SessionHandover.verify(pid: 100, sessionId: sid, record: late, facts: facts(), ownUid: uid), .ok)
    }

    func testRecognizesClaudeExecutables() {
        XCTAssertTrue(facts(argv0: nil).looksLikeClaude)
        XCTAssertTrue(facts(path: "/opt/homebrew/bin/claude", argv0: nil).looksLikeClaude)
        XCTAssertTrue(facts(path: "/usr/local/bin/node", argv0: "claude").looksLikeClaude)
        XCTAssertFalse(facts(path: "/usr/local/bin/node", argv0: "node").looksLikeClaude)
    }

    func testParsesArgv0FromProcArgs() {
        var bytes: [UInt8] = [2, 0, 0, 0]
        bytes += Array("/Users/u/.local/share/claude/versions/2.1.286".utf8) + [0, 0, 0]
        bytes += Array("claude".utf8) + [0] + Array("--resume".utf8) + [0]
        XCTAssertEqual(ProcessFacts.parseArgv0(procArgs: bytes), "claude")
    }

    func testInspectsOwnProcess() throws {
        let facts = try XCTUnwrap(ProcessFacts.inspect(pid: getpid()))
        XCTAssertEqual(facts.uid, getuid())
        XCTAssertFalse(facts.isZombie)
        XCTAssertNotNil(facts.executablePath)
    }
}

/// シグナルの送り先と、送った後にプロセスがどうなるかを差し替えて終了処理を確かめる。
final class SessionTerminatorTests: XCTestCase {
    private final class FakeProcess: @unchecked Sendable {
        let lock = NSLock()
        var facts: ProcessFacts?
        var record: ClaudeSessionRecord?
        var signals: [Int32] = []
        /// このシグナルを受けたら終わる。
        var exitsOn: Set<Int32> = []
        /// このシグナルを受けたら pid が別のプロセスに替わる。
        var replacedOn: Set<Int32> = []

        func receive(_ sig: Int32) {
            lock.lock(); defer { lock.unlock() }
            signals.append(sig)
            if exitsOn.contains(sig) {
                facts = nil
                record = nil
            } else if replacedOn.contains(sig), let current = facts {
                facts = ProcessFacts(uid: current.uid, startedAt: current.startedAt.addingTimeInterval(10),
                                     executablePath: "/bin/sleep", argv0: "sleep", isZombie: false)
            }
        }

        func read<T>(_ body: (FakeProcess) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(self)
        }
    }

    private let sid = "acb12868-4061-4d7e-987c-0522878e518d"
    private let start = Date(timeIntervalSince1970: 1_790_848_942)

    private func makeProcess() -> FakeProcess {
        let process = FakeProcess()
        process.facts = ProcessFacts(uid: 501, startedAt: start, executablePath: "/x/claude/versions/2.1.286",
                                     argv0: "claude", isZombie: false)
        process.record = ClaudeSessionRecord(pid: 100, sessionId: sid, procStart: "Thu Oct  1 10:02:22 2026")
        return process
    }

    private func terminator(_ process: FakeProcess) -> SessionTerminator {
        var terminator = SessionTerminator(inspect: { _ in process.read { $0.facts } },
                                           record: { _ in process.read { $0.record } },
                                           signal: { _, sig in process.receive(sig) },
                                           sleep: { _ in },
                                           ownUid: 501)
        terminator.interruptGrace = .milliseconds(600)
        terminator.terminateGrace = .milliseconds(600)
        return terminator
    }

    func testExitsOnSigint() async {
        let process = makeProcess()
        process.exitsOn = [SIGINT]
        let outcome = await terminator(process).terminate(pid: 100, sessionId: sid)
        XCTAssertEqual(outcome, .exited)
        XCTAssertEqual(process.read { $0.signals }, [SIGINT])
    }

    func testEscalatesToSigtermWhenSigintIsIgnored() async {
        let process = makeProcess()
        process.exitsOn = [SIGTERM]
        let outcome = await terminator(process).terminate(pid: 100, sessionId: sid)
        XCTAssertEqual(outcome, .exited)
        XCTAssertEqual(process.read { $0.signals }, [SIGINT, SIGTERM])
    }

    func testReportsStillRunning() async {
        let process = makeProcess()
        let outcome = await terminator(process).terminate(pid: 100, sessionId: sid)
        XCTAssertEqual(outcome, .stillRunning)
        XCTAssertEqual(process.read { $0.signals }, [SIGINT, SIGTERM])
    }

    func testSendsNothingToAnotherSession() async {
        let process = makeProcess()
        process.record = ClaudeSessionRecord(pid: 100, sessionId: "another", procStart: "Thu Oct  1 10:02:22 2026")
        let outcome = await terminator(process).terminate(pid: 100, sessionId: sid)
        guard case .refused = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(process.read { $0.signals }, [])
    }

    func testDoesNotEscalateOnceThePidIsReused() async {
        let process = makeProcess()
        process.replacedOn = [SIGINT]
        let outcome = await terminator(process).terminate(pid: 100, sessionId: sid)
        XCTAssertEqual(outcome, .exited)
        XCTAssertEqual(process.read { $0.signals }, [SIGINT])
    }

    func testAlreadyGoneCountsAsExited() async {
        let process = makeProcess()
        process.facts = nil
        let outcome = await terminator(process).terminate(pid: 100, sessionId: sid)
        XCTAssertEqual(outcome, .exited)
        XCTAssertEqual(process.read { $0.signals }, [])
    }
}

final class RelayNotesTests: XCTestCase {
    private func user(_ id: String, _ text: String, at: Double?) -> TranscriptItem {
        TranscriptItem(id: id, kind: .user, at: at, text: text, tool: nil, parentId: nil)
    }

    private func assistant(_ id: String, at: Double?) -> TranscriptItem {
        TranscriptItem(id: id, kind: .assistant, at: at, text: id, tool: nil, parentId: nil)
    }

    func testNotesAreInsertedByTime() {
        let items = [user("u1", "最初", at: 1000), assistant("a1", at: 2000), user("u2", "次", at: 5000), assistant("a2", at: 6000)]
        let note = RelayNote(id: "n", text: "伝言", sentAt: 3000, state: .sent)
        let entries = ChatTimeline.entries(from: items, notes: [note])
        XCTAssertEqual(entries.map(\.id), ["u1", "a1", "relay:n", "u2", "a2"])
        XCTAssertEqual(entries[2].role, .relay)
        XCTAssertEqual(entries[2].relay?.state, .sent)
    }

    func testNoteAfterEverythingIsAppended() {
        let items = [user("u1", "最初", at: 1000), assistant("a1", at: nil)]
        let entries = ChatTimeline.entries(from: items, notes: [RelayNote(id: "n", text: "伝言", sentAt: 9000)])
        XCTAssertEqual(entries.map(\.id), ["u1", "a1", "relay:n"])
    }

    func testEchoInTranscriptIsNotShownTwice() {
        let echo = user("e", "Another Claude session sent a message:\n伝言です\n\nThis came from another Claude session — …", at: 3100)
        let items = [user("u1", "最初", at: 1000), echo, assistant("a1", at: 4000)]
        let entries = ChatTimeline.entries(from: items, notes: [RelayNote(id: "n", text: "伝言です\n", sentAt: 3000, state: .sent)])
        XCTAssertEqual(entries.map(\.id), ["u1", "relay:n", "a1"])
    }

    func testPlainEchoRightAfterSendingIsDeduplicated() {
        let items = [user("e", "伝言です", at: 3100)]
        let entries = ChatTimeline.entries(from: items, notes: [RelayNote(id: "n", text: "伝言です", sentAt: 3000, state: .sent)])
        XCTAssertEqual(entries.map(\.id), ["relay:n"])
    }

    func testOwnMessagesWithTheSameTextAreKept() {
        let note = RelayNote(id: "n", text: "OK", sentAt: 100_000, state: .sent)
        // 送る前に本人が打った同文・ずっと後に打った同文・届かなかった伝言と同文は消さない。
        let before = user("b", "OK", at: 10_000)
        let later = user("l", "OK", at: 100_000 + 60 * 60_000)
        XCTAssertEqual(RelayNotes.removingEchoes(from: [before, later], notes: [note]).map(\.id), ["b", "l"])
        let failed = RelayNote(id: "f", text: "OK", sentAt: 100_000, state: .failed("x"))
        XCTAssertEqual(RelayNotes.removingEchoes(from: [user("x", "OK", at: 100_100)], notes: [failed]).map(\.id), ["x"])
    }

    func testOneNoteHidesAtMostOneEcho() {
        let note = RelayNote(id: "n", text: "OK", sentAt: 1000, state: .sent)
        let items = [user("e1", "OK", at: 1100), user("e2", "OK", at: 1200)]
        XCTAssertEqual(RelayNotes.removingEchoes(from: items, notes: [note]).map(\.id), ["e2"])
    }

    func testFailureReasons() {
        XCTAssertEqual(RelayNotes.failureReason(MonitorError.http(status: 409, code: "not_alive", message: "x")), "このセッションは終了しています")
        XCTAssertTrue(RelayNotes.failureReason(MonitorError.http(status: 409, code: "no_socket", message: nil)).contains("受け口"))
        XCTAssertTrue(RelayNotes.failureReason(MonitorError.http(status: 404, code: "not_found", message: nil)).contains("見失って"))
        XCTAssertTrue(RelayNotes.failureReason(MonitorError.http(status: 502, code: "unreachable", message: "timeout")).contains("timeout"))
        XCTAssertEqual(RelayNotes.failureReason(MonitorError.unreachable("refused")), "monitor に接続できません")
    }
}
