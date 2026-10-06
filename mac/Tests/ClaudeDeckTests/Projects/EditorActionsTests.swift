import XCTest
@testable import MonitorKit

final class XcodeCloseTests: XCTestCase {
    func testPathIsPassedAsLastArgumentNotEmbedded() throws {
        let path = #"/Users/me/My "App" \ Folder/App Store Checker.xcodeproj"#
        let args = try XCTUnwrap(XcodeClose.arguments(for: path))
        XCTAssertEqual(args.last, path)
        XCTAssertEqual(args.count, XcodeClose.scriptLines.count * 2 + 1)
        for (i, line) in XcodeClose.scriptLines.enumerated() {
            XCTAssertEqual(args[i * 2], "-e")
            XCTAssertEqual(args[i * 2 + 1], line)
            XCTAssertFalse(line.contains(path))
        }
    }

    func testRejectsRelativeAndOptionLikePaths() {
        for bad in ["", "-e", "-l JavaScript", "App.xcodeproj", "./App.xcodeproj", "~/App.xcodeproj"] {
            XCTAssertNil(XcodeClose.arguments(for: bad), bad)
        }
    }

    func testChecksRunningBeforeTellingXcode() throws {
        let running = try XCTUnwrap(XcodeClose.scriptLines.firstIndex { $0.contains("is running") })
        let tell = try XCTUnwrap(XcodeClose.scriptLines.firstIndex { $0.hasPrefix("tell application") })
        XCTAssertLessThan(running, tell)
        // Xcode 本体を終了させる命令は含めない。
        XCTAssertFalse(XcodeClose.scriptLines.contains { $0.contains("quit") })
    }

    func testOutcomeFromStdout() {
        XCTAssertEqual(XcodeClose.outcome(status: 0, stdout: "closed\n", stderr: "", timedOut: false), .closeRequested)
        XCTAssertEqual(XcodeClose.outcome(status: 0, stdout: "not_open\n", stderr: "", timedOut: false), .notOpen)
        XCTAssertEqual(XcodeClose.outcome(status: 0, stdout: " not_running ", stderr: "", timedOut: false), .notRunning)
        XCTAssertEqual(XcodeClose.outcome(status: 0, stdout: "true", stderr: "", timedOut: false), .failed("応答を読めません"))
    }

    func testOutcomeOnFailure() {
        XCTAssertEqual(XcodeClose.outcome(status: 1, stdout: "", stderr: "execution error: 拒否 (-1743)\n", timedOut: false),
                       .failed("execution error: 拒否 (-1743)"))
        XCTAssertEqual(XcodeClose.outcome(status: 1, stdout: "", stderr: "", timedOut: false),
                       .failed("閉じられませんでした（終了コード 1）"))
        // 時間切れは標準出力より優先する（止めた後の出力は当てにならない）。
        XCTAssertEqual(XcodeClose.outcome(status: 15, stdout: "closed", stderr: "", timedOut: true),
                       .failed("応答がありません（確認ダイアログが出ているかもしれません）"))
    }

    func testMessages() {
        XCTAssertEqual(EditorOutcome.opened.message, "開きました")
        XCTAssertEqual(EditorOutcome.closeRequested.message, "閉じるよう伝えました")
        XCTAssertEqual(EditorOutcome.notOpen.message, "Xcode では開いていません")
        XCTAssertEqual(EditorOutcome.notRunning.message, "Xcode は起動していません")
        XCTAssertEqual(EditorOutcome.failed("x").message, "x")
        XCTAssertTrue(EditorOutcome.failed("x").isFailure)
        XCTAssertFalse(EditorOutcome.notRunning.isFailure)
    }

    func testRelativePathFailsWithoutLaunching() async {
        let outcome = await XcodeClose.close(path: "App.xcodeproj")
        XCTAssertEqual(outcome, .failed("閉じる先が絶対パスではありません"))
    }
}

final class ProcessRunnerTests: XCTestCase {
    func testCollectsOutputAndStatus() async {
        let result = await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                             arguments: ["-c", "echo not_open; echo oops >&2; exit 3"], timeout: 5)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdout, "not_open\n")
        XCTAssertEqual(result.stderr, "oops\n")
        XCTAssertFalse(result.timedOut)
        XCTAssertNil(result.launchError)
    }

    func testTimesOut() async {
        let started = Date()
        let result = await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.3)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testMissingExecutable() async {
        let result = await ProcessRunner.run(executable: URL(fileURLWithPath: "/nonexistent/osascript"), arguments: [], timeout: 1)
        XCTAssertNotNil(result.launchError)
    }
}
