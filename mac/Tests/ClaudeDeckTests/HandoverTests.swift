import XCTest
import Darwin
@testable import MonitorKit

final class SessionIdValidationTests: XCTestCase {
    func testAcceptsUUID() {
        XCTAssertTrue(SessionHandover.isResumableSessionId("acb12868-4061-4d7e-987c-0522878e518d"))
    }

    func testRejectsShellMetacharacters() {
        for bad in ["", "a b", "a;rm -rf ~", "$(id)", "`id`", "a\nb", "../x", "a'b", "ａ", String(repeating: "a", count: 129)] {
            XCTAssertFalse(SessionHandover.isResumableSessionId(bad), bad)
        }
    }

    func testRejectsOptionsThatWouldTurnIntoHeadless() {
        for bad in ["-p", "--print", "--dangerously-skip-permissions", "-pacb12868-4061-4d7e-987c-0522878e518d",
                    "-cb12868-4061-4d7e-987c-0522878e518d", "acb12868-4061-4d7e-987c-0522878e518d -p",
                    "acb1286840614d7e987c0522878e518d", "acb12868-4061-4d7e-987c-0522878e518"] {
            XCTAssertFalse(SessionHandover.isResumableSessionId(bad), bad)
            XCTAssertNil(SessionHandover.resumeArgument(bad), bad)
        }
    }

    func testResumeArgumentIsJoinedWithEquals() {
        XCTAssertEqual(SessionHandover.resumeArgument("ACB12868-4061-4d7e-987c-0522878e518d"),
                       "--resume=ACB12868-4061-4d7e-987c-0522878e518d")
    }
}

final class HandoverSourceTests: XCTestCase {
    func testOnlyInteractiveTerminalSessionsCanBeHandedOver() {
        XCTAssertNil(SessionHandover.unsupportedSourceReason(entrypoint: "cli", kind: "interactive"))
        XCTAssertNil(SessionHandover.unsupportedSourceReason(entrypoint: "cli", kind: nil))
        XCTAssertEqual(SessionHandover.unsupportedSourceReason(entrypoint: "claude-vscode", kind: "interactive"),
                       "VS Code 等で動いているセッションは引き継げません")
        XCTAssertNotNil(SessionHandover.unsupportedSourceReason(entrypoint: "sdk-cli", kind: nil))
        XCTAssertNotNil(SessionHandover.unsupportedSourceReason(entrypoint: nil, kind: "interactive"))
        XCTAssertNotNil(SessionHandover.unsupportedSourceReason(entrypoint: "cli", kind: "print"))
    }

    func testDescribesWhereTheSessionRuns() {
        XCTAssertTrue(SessionHandover.sourceDescription(entrypoint: "cli").contains("ターミナル"))
        XCTAssertTrue(SessionHandover.sourceDescription(entrypoint: "claude-vscode").contains("VS Code"))
        XCTAssertFalse(SessionHandover.sourceDescription(entrypoint: nil).contains("ターミナル"))
    }

    func testDecodesEntrypointAndKindFromRegistry() throws {
        let json = #"{"pid":3450,"sessionId":"9c5a73ea-48db-4aef-9ca5-a772f22c89a0","cwd":"/x","startedAt":1790782475754,"procStart":"Wed Sep 30 15:34:34 2026","kind":"interactive","entrypoint":"claude-vscode","status":"busy"}"#
        let record = try JSONDecoder().decode(ClaudeSessionRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.entrypoint, "claude-vscode")
        XCTAssertEqual(record.kind, "interactive")
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
        ClaudeSessionRecord(pid: pid, sessionId: sessionId ?? sid, cwd: "/tmp", startedAt: startedAt, procStart: procStart,
                            entrypoint: "cli", kind: "interactive")
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

    func testRefusesVSCodeSession() {
        var vscode = record()
        vscode.entrypoint = "claude-vscode"
        vscode.kind = "interactive"
        // 実体のパス末尾が claude でも、VS Code 拡張の claude は撃たない。
        let facts = facts(path: "/Users/u/.vscode/extensions/anthropic.claude-code/resources/native-binary/claude", argv0: nil)
        XCTAssertTrue(facts.looksLikeClaude)
        XCTAssertEqual(SessionHandover.verify(pid: 100, sessionId: sid, record: vscode, facts: facts, ownUid: uid),
                       .refused("VS Code 等で動いているセッションは引き継げません"))
    }

    func testSameProcessIgnoresExecutablePath() {
        XCTAssertTrue(facts().isSameProcess(as: ProcessFacts(uid: 501, startedAt: start, executablePath: nil, argv0: nil, isZombie: false)))
        XCTAssertTrue(facts().isSameProcess(as: facts(path: "/somewhere/else")))
        XCTAssertFalse(facts().isSameProcess(as: facts(start: start.addingTimeInterval(1))))
        XCTAssertFalse(facts().isSameProcess(as: facts(uid: 0)))
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
        /// このシグナルを受けたら実行パスが読めなくなる（プロセスは同じまま）。
        var pathLostOn: Set<Int32> = []
        /// 同じ会話を動かしている別の claude。
        var others: [Int32: (ClaudeSessionRecord, ProcessFacts?)] = [:]

        func receive(_ sig: Int32) {
            lock.lock(); defer { lock.unlock() }
            signals.append(sig)
            if exitsOn.contains(sig) {
                facts = nil
                record = nil
            } else if replacedOn.contains(sig), let current = facts {
                facts = ProcessFacts(uid: current.uid, startedAt: current.startedAt.addingTimeInterval(10),
                                     executablePath: "/bin/sleep", argv0: "sleep", isZombie: false)
            } else if pathLostOn.contains(sig), let current = facts {
                facts = ProcessFacts(uid: current.uid, startedAt: current.startedAt, executablePath: nil, argv0: nil, isZombie: false)
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
        process.record = ClaudeSessionRecord(pid: 100, sessionId: sid, procStart: "Thu Oct  1 10:02:22 2026",
                                             entrypoint: "cli", kind: "interactive")
        return process
    }

    private func terminator(_ process: FakeProcess) -> SessionTerminator {
        var terminator = SessionTerminator(inspect: { pid in process.read { pid == 100 ? $0.facts : $0.others[pid]?.1 } },
                                           record: { _ in process.read { $0.record } },
                                           records: { process.read { p in [p.record].compactMap { $0 } + p.others.values.map(\.0) } },
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

    func testPathReadFailureIsNotTreatedAsExit() async {
        let process = makeProcess()
        process.pathLostOn = [SIGINT]
        let outcome = await terminator(process).terminate(pid: 100, sessionId: sid)
        XCTAssertEqual(outcome, .stillRunning)
        XCTAssertEqual(process.read { $0.signals }, [SIGINT, SIGTERM])
    }

    func testDoesNotResumeWhileTheSameConversationRunsElsewhere() async {
        let process = makeProcess()
        process.facts = nil
        let otherStart = Date(timeIntervalSince1970: 1_790_850_000)
        process.others[200] = (ClaudeSessionRecord(pid: 200, sessionId: sid, procStart: "Thu Oct  1 10:20:00 2026",
                                                   entrypoint: "cli", kind: "interactive"),
                               ProcessFacts(uid: 501, startedAt: otherStart, executablePath: "/x/claude", argv0: "claude", isZombie: false))
        let outcome = await terminator(process).terminate(pid: 100, sessionId: sid)
        XCTAssertEqual(outcome, .runningElsewhere(200))
        XCTAssertEqual(process.read { $0.signals }, [])
    }

    func testDoesNotInterruptWhenTheConversationAlreadyRunsElsewhere() async {
        let process = makeProcess()
        let otherStart = Date(timeIntervalSince1970: 1_790_850_000)
        process.others[200] = (ClaudeSessionRecord(pid: 200, sessionId: sid, procStart: "Thu Oct  1 10:20:00 2026",
                                                   entrypoint: "cli", kind: "interactive"),
                               ProcessFacts(uid: 501, startedAt: otherStart, executablePath: "/x/claude", argv0: "claude", isZombie: false))
        let outcome = await terminator(process).terminate(pid: 100, sessionId: sid)
        XCTAssertEqual(outcome, .runningElsewhere(200))
        XCTAssertEqual(process.read { $0.signals }, [], "止める前に重複を見つけたらシグナルを送らない")
    }

    func testStaleRecordsDoNotBlockResume() async {
        let process = makeProcess()
        process.exitsOn = [SIGINT]
        // 終了済み（pid が無い）・pid が再利用済み（起動時刻が違う）・別の会話は数えない。
        let reused = ProcessFacts(uid: 501, startedAt: Date(timeIntervalSince1970: 1_790_860_000), executablePath: "/bin/zsh",
                                  argv0: "zsh", isZombie: false)
        process.others[200] = (ClaudeSessionRecord(pid: 200, sessionId: sid, procStart: "Thu Oct  1 10:20:00 2026"), nil)
        process.others[201] = (ClaudeSessionRecord(pid: 201, sessionId: sid, procStart: "Thu Oct  1 10:20:00 2026"), reused)
        process.others[202] = (ClaudeSessionRecord(pid: 202, sessionId: "bcb12868-4061-4d7e-987c-0522878e518d",
                                                   procStart: "Thu Oct  1 10:02:22 2026"),
                               ProcessFacts(uid: 501, startedAt: start, executablePath: nil, argv0: nil, isZombie: false))
        let outcome = await terminator(process).terminate(pid: 100, sessionId: sid)
        XCTAssertEqual(outcome, .exited)
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

    func testPlainTextWithoutTimestampIsKept() {
        // 時刻の無い過去の発話は、書き出しが無ければ伝言の写しと見なさない。
        let note = RelayNote(id: "n", text: "OK", sentAt: 100_000, state: .sent)
        XCTAssertEqual(RelayNotes.removingEchoes(from: [user("old", "OK", at: nil)], notes: [note]).map(\.id), ["old"])
        let prefixed = user("p", "Another Claude session sent a message:\nOK", at: nil)
        XCTAssertEqual(RelayNotes.removingEchoes(from: [prefixed], notes: [note]).map(\.id), [])
    }

    func testOneNoteHidesAtMostOneEcho() {
        let note = RelayNote(id: "n", text: "OK", sentAt: 1000, state: .sent)
        let items = [user("e1", "OK", at: 1100), user("e2", "OK", at: 1200)]
        XCTAssertEqual(RelayNotes.removingEchoes(from: items, notes: [note]).map(\.id), ["e2"])
    }

    func testFailureReasons() {
        XCTAssertEqual(RelayNotes.failureReason(HubFailure(code: "not_alive", message: "x")), "このセッションは終了しています")
        XCTAssertTrue(RelayNotes.failureReason(HubFailure(code: "no_socket", message: "")).contains("受け口"))
        XCTAssertTrue(RelayNotes.failureReason(HubFailure(code: "not_found", message: "")).contains("見失って"))
        XCTAssertTrue(RelayNotes.failureReason(HubFailure(code: "unreachable", message: "timeout")).contains("timeout"))
        XCTAssertEqual(RelayNotes.failureReason(HubFailure(code: "failed", message: "だめ")), "だめ")
    }
}
