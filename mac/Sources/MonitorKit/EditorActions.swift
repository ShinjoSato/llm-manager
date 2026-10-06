import Foundation

/// 見出しの「VS Code」「GitHub」「Xcode」「閉じる」を押した結果。見出しに短く出す。
public enum EditorOutcome: Sendable, Equatable {
    case opened
    /// 未保存の変更があると Xcode が確認を出すので、閉じたとは断定しない。
    case closeRequested
    case notOpen
    case notRunning
    case failed(String)
    /// 開けたが、利用者に知らせておくことがある。
    case openedWithNote(String)

    public var message: String {
        switch self {
        case .opened: return "開きました"
        case .closeRequested: return "閉じるよう伝えました"
        case .notOpen: return "Xcode では開いていません"
        case .notRunning: return "Xcode は起動していません"
        case .failed(let reason): return reason
        case .openedWithNote(let note): return note
        }
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Xcode から 1 つのワークスペースだけを閉じる（AppleScript）。
public enum XcodeClose {
    public static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
    public static let timeout: TimeInterval = 15

    public static let scriptLines: [String] = [
        "on run argv",
        "set wanted to item 1 of argv",
        // `tell application "Xcode"` は起動していない Xcode を立ち上げてしまうので running を先に見る。
        "if not (application \"Xcode\" is running) then return \"not_running\"",
        "tell application \"Xcode\"",
        "repeat with doc in workspace documents",
        // `target` は Xcode の用語なので変数名に使えない（用語として解釈され一致しない）。
        "if (path of doc) is wanted then",
        "close doc",
        "return \"closed\"",
        "end if",
        "end repeat",
        "end tell",
        "return \"not_open\"",
        "end run",
    ]

    /// パスはスクリプトに埋め込まず argv で渡す（`"` や `\` を含むパスで壊れないため）。
    /// 相対パスは弾く（`-` で始まると osascript のオプションとして解釈される）。
    public static func arguments(for path: String) -> [String]? {
        guard path.hasPrefix("/") else { return nil }
        return scriptLines.flatMap { ["-e", $0] } + [path]
    }

    public static func outcome(status: Int32, stdout: String, stderr: String, timedOut: Bool) -> EditorOutcome {
        if timedOut { return .failed("応答がありません（確認ダイアログが出ているかもしれません）") }
        guard status == 0 else {
            let reason = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(reason.isEmpty ? "閉じられませんでした（終了コード \(status)）" : reason)
        }
        switch stdout.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "closed": return .closeRequested
        case "not_open": return .notOpen
        case "not_running": return .notRunning
        default: return .failed("応答を読めません")
        }
    }

    /// シェルを経由せず引数配列で osascript を起動する。
    public static func close(path: String) async -> EditorOutcome {
        guard let args = arguments(for: path) else { return .failed("閉じる先が絶対パスではありません") }
        let result = await ProcessRunner.run(executable: osascript, arguments: args, timeout: timeout)
        if let launchError = result.launchError { return .failed(launchError) }
        return outcome(status: result.status, stdout: result.stdout, stderr: result.stderr, timedOut: result.timedOut)
    }
}

/// 子プロセスを 1 つ走らせて出力を集める。時間切れなら止める。
public enum ProcessRunner {
    public struct Result: Sendable, Equatable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
        public var launchError: String?
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        func get() -> Bool { lock.withLock { value } }
    }

    public static func run(executable: URL, arguments: [String], timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            let timedOut = TimeoutFlag()
            process.terminationHandler = { finished in
                let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: Result(status: finished.terminationStatus, stdout: stdout,
                                                      stderr: stderr, timedOut: timedOut.get(), launchError: nil))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: Result(status: -1, stdout: "", stderr: "", timedOut: false,
                                                      launchError: error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
            }
        }
    }
}
