import Foundation

/// 読むだけの git を 1 回走らせた結果。
public struct GitOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String
    /// 出力の上限で読むのをやめて止めた。
    public var truncated: Bool

    public var succeeded: Bool { status == 0 && !truncated }
    public var text: String { String(decoding: stdout, as: UTF8.self) }
}

/// git を走らせられなかった理由。
public enum GitRunError: Error, Equatable, Sendable {
    case gitNotFound
    case launchFailed(Int32)
    case timedOut
    case cancelled

    public var message: String {
        switch self {
        case .gitNotFound: return "git が見つかりません。Xcode のコマンドラインツール（xcode-select --install）を入れると表示できます。"
        case .launchFailed(let code): return "git を起動できませんでした（\(String(cString: strerror(code)))）"
        case .timedOut: return "git が時間内に終わりませんでした"
        case .cancelled: return "取り消しました"
        }
    }
}

/// ブランチの図のために git を読むだけのコマンドで走らせる（起動はこの型の `execute` の 1 か所だけ）。
public struct GitRunner: Sendable {
    public var executable: String
    public var timeout: TimeInterval
    public var outputLimit: Int

    public static let defaultTimeout: TimeInterval = 5
    public static let defaultOutputLimit = 16 << 20
    static let stderrLimit = 64 << 10

    public init(executable: String, timeout: TimeInterval = defaultTimeout, outputLimit: Int = defaultOutputLimit) {
        self.executable = executable
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    /// 見つかった git で作る。無ければ nil。
    public static func standard() -> GitRunner? {
        locate().map { GitRunner(executable: $0) }
    }

    /// /usr/bin/git は道具が無いと導入のダイアログを出すため、実体の場所を直接探す。
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              selectedDeveloperDir: String? = selectedDeveloperDirectory(),
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        var dirs: [String] = []
        if let dir = environment["DEVELOPER_DIR"], dir.hasPrefix("/") { dirs.append(dir) }
        if let selectedDeveloperDir { dirs.append(selectedDeveloperDir) }
        dirs += ["/Library/Developer/CommandLineTools", "/Applications/Xcode.app/Contents/Developer"]
        let candidates = dirs.map { $0 + "/usr/bin/git" } + ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        return candidates.first(where: isExecutable)
    }

    /// `xcode-select` で選ばれている Developer フォルダ（無ければ nil）。
    public static func selectedDeveloperDirectory() -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")
    }

    /// 子の環境。課金経路と子セッション印を外し、利用者の GIT_* で別のリポジトリを指されないよう落とし、ロックとプロンプトと遅延取得を止める。
    public static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = ChildEnvironment.sanitized(base).filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_NO_LAZY_FETCH"] = "1"
        env["GIT_PAGER"] = "cat"
        env["PAGER"] = "cat"
        env["LC_ALL"] = "C"
        return env
    }

    /// どのコマンドにも付ける前置き（ページャ・fsmonitor・署名の確認・色・パスの引用を切り、出力は UTF-8 に固定する）。
    public static let commonArguments = [
        "--no-pager", "--no-optional-locks",
        "-c", "core.fsmonitor=false", "-c", "core.pager=cat", "-c", "log.showSignature=false",
        "-c", "color.ui=false", "-c", "core.quotePath=false", "-c", "i18n.logOutputEncoding=UTF-8",
    ] + networkGuardArguments

    /// GIT_NO_LAZY_FETCH を知らない版でも、partial clone の遅延取得で通信や外部コマンドを走らせない（プロトコル別の許可より強く効くよう全部閉じる）。
    static let networkGuardArguments = ["-c", "protocol.allow=never"]
        + ["file", "git", "ssh", "http", "https", "ext"].flatMap { ["-c", "protocol.\($0).allow=never"] }
        + ["-c", "core.sshCommand=false"]

    /// 読むだけのサブコマンドに限る（書き換え・ネットワークに出るものを通さない）。
    static let allowedSubcommands: Set<String> = ["rev-parse", "symbolic-ref", "for-each-ref", "log", "show", "diff-tree"]

    public func run(_ arguments: [String], in directory: String, outputLimit: Int? = nil) async throws -> GitOutput {
        guard let sub = arguments.first, Self.allowedSubcommands.contains(sub) else { throw GitRunError.launchFailed(EINVAL) }
        let flag = CancelFlag()
        let executable = executable, timeout = timeout, limit = outputLimit ?? self.outputLimit
        let result: Result<GitOutput, GitRunError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Self.execute(executable: executable,
                                                                arguments: Self.commonArguments + arguments,
                                                                environment: Self.environment(),
                                                                directory: directory, timeout: timeout,
                                                                limit: limit, cancelled: flag))
                }
            }
        } onCancel: {
            flag.set()
        }
        return try result.get()
    }

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// 起動して stdout と stderr を読み切る。時間切れ・上限・取り消しではグループごと止める。
    static func execute(executable: String, arguments: [String], environment: [String: String], directory: String,
                        timeout: TimeInterval, limit: Int, cancelled: CancelFlag) -> Result<GitOutput, GitRunError> {
        guard let out = ChildProcessControl.makePipe() else { return .failure(.launchFailed(errno)) }
        guard let err = ChildProcessControl.makePipe() else {
            let code = errno
            close(out.read); close(out.write)
            return .failure(.launchFailed(code))
        }
        let outFDs = [out.read, out.write], errFDs = [err.read, err.write]
        let (pid, rc) = ProcessGroup.spawn(executable: executable, arguments: arguments, environment: environment,
                                           directory: directory) { actions in
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, outFDs[1], 1)
            posix_spawn_file_actions_adddup2(&actions, errFDs[1], 2)
        }
        close(outFDs[1])
        close(errFDs[1])
        guard rc == 0 else {
            close(outFDs[0]); close(errFDs[0])
            return .failure(.launchFailed(rc))
        }
        defer { close(outFDs[0]); close(errFDs[0]) }
        for fd in [outFDs[0], errFDs[0]] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }

        let deadline = Date().addingTimeInterval(timeout)
        var stdout = Data(), stderr = Data()
        var open: [Int32] = [outFDs[0], errFDs[0]]
        var stop: GitRunError?
        var truncated = false
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while !open.isEmpty {
            if cancelled.isSet { stop = .cancelled; break }
            if Date() >= deadline { stop = .timedOut; break }
            var pollFDs = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&pollFDs, nfds_t(pollFDs.count), 50)
            if ready < 0 && errno != EINTR { break }
            guard ready > 0 else { continue }
            for entry in pollFDs where entry.revents != 0 {
                let count = read(entry.fd, &buffer, buffer.count)
                if count > 0 {
                    if entry.fd == outFDs[0] {
                        stdout.append(contentsOf: buffer[0..<count])
                        if stdout.count > limit {
                            stdout = stdout.prefix(limit)
                            truncated = true
                        }
                    } else if stderr.count < stderrLimit {
                        stderr.append(contentsOf: buffer[0..<min(count, stderrLimit - stderr.count)])
                    }
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    open.removeAll { $0 == entry.fd }
                }
            }
            if truncated { break }
        }
        if stop != nil || truncated || !open.isEmpty { killpg(pid, SIGKILL) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        if let stop { return .failure(stop) }
        let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
        return .success(GitOutput(status: exitCode, stdout: stdout,
                                  stderr: String(decoding: stderr, as: UTF8.self), truncated: truncated))
    }
}
