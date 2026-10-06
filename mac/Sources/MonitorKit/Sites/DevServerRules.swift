import Foundation

/// LP の開発サーバー（`npm run dev`）を起動できるか。
public enum DevServerReadiness: Equatable, Sendable {
    case ready(script: String)
    case noPackageJson
    case unreadablePackageJson
    case noDevScript

    /// 起動できない理由（起動できるなら nil）。
    public var problem: String? {
        switch self {
        case .ready: return nil
        case .noPackageJson: return "package.json がありません"
        case .unreadablePackageJson: return "package.json を読めません（JSON の形を確かめてください）"
        case .noDevScript: return "package.json に dev スクリプトがありません"
        }
    }
}

/// 開発サーバーの終わり方（終了コードかシグナル）。
public struct DevServerExit: Equatable, Sendable {
    public var code: Int32?
    public var signal: Int32?

    public init(code: Int32? = nil, signal: Int32? = nil) {
        self.code = code
        self.signal = signal
    }

    /// waitid の結果から作る。
    public init(siginfoCode: Int32, status: Int32) {
        if siginfoCode == CLD_EXITED {
            self.init(code: status)
        } else {
            self.init(signal: status)
        }
    }

    var label: String {
        if let signal { return "シグナル \(signal)" }
        return "終了コード \(code ?? -1)"
    }
}

/// 起動条件・出力からのアドレスの読み取り・失敗の理由。
public enum DevServerRules {
    /// 節の中で見られる出力の行数。
    public static let maxLogLines = 400

    /// ログインシェルで PATH（nvm 等）を得て、API キーを外してから npm に替わる。
    public static let shellCommand = "\(ChildEnvironment.unsetCommand); exec npm run dev"
    public static let shell = "/bin/zsh"
    public static let shellArguments = ["-lic", shellCommand]

    public static func readiness(siteRoot: String, fileManager: FileManager = .default) -> DevServerReadiness {
        let path = (siteRoot as NSString).appendingPathComponent("package.json")
        guard fileManager.fileExists(atPath: path) else { return .noPackageJson }
        return readiness(packageJSON: fileManager.contents(atPath: path))
    }

    public static func readiness(packageJSON: Data?) -> DevServerReadiness {
        guard let packageJSON else { return .unreadablePackageJson }
        guard let object = try? JSONSerialization.jsonObject(with: packageJSON) as? [String: Any] else { return .unreadablePackageJson }
        guard let scripts = object["scripts"] as? [String: Any], let dev = scripts["dev"] as? String,
              !dev.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .noDevScript }
        return .ready(script: dev)
    }

    /// 子の環境。API キー・子セッション印を除き、ブラウザを勝手に開かせず、出力の色は付けさせない。
    public static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = ChildEnvironment.sanitized(base)
        env["BROWSER"] = "none"
        env["NO_COLOR"] = "1"
        env["FORCE_COLOR"] = "0"
        return env
    }

    // MARK: - アドレス

    private static let addressPattern = try! NSRegularExpression(
        pattern: #"(?:(https?)://)?(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):([0-9]{1,5})(/[A-Za-z0-9._~%/\-]*)?"#,
        options: [.caseInsensitive])

    /// 出力の 1 行から、開発サーバーの手元のアドレス（localhost / 127.0.0.1）を読む。LAN のアドレスやエラーの行は使わない。
    public static func address(in rawLine: String) -> URL? {
        let line = DevServerLog.clean(rawLine)
        let lower = line.lowercased()
        // 「使用中」のエラーに出るアドレスは自分のものではない。
        if lower.contains("eaddrinuse") || lower.contains("in use") || lower.contains("error") { return nil }
        let range = NSRange(line.startIndex..., in: line)
        for match in addressPattern.matches(in: line, range: range) {
            guard let portRange = Range(match.range(at: 3), in: line), let port = Int(line[portRange]),
                  (1...65535).contains(port), let hostRange = Range(match.range(at: 2), in: line) else { continue }
            let scheme = Range(match.range(at: 1), in: line).map { line[$0].lowercased() } ?? "http"
            let rawHost = line[hostRange].lowercased()
            // 0.0.0.0 は待ち受けの指定で、開く先ではない。IPv6 のループバックも名前で開く。
            let host = rawHost == "127.0.0.1" ? "127.0.0.1" : "localhost"
            var path = Range(match.range(at: 4), in: line).map { String(line[$0]) } ?? "/"
            if path.isEmpty { path = "/" }
            if let url = URL(string: "\(scheme)://\(host):\(port)\(path)") { return url }
        }
        return nil
    }

    /// プレビューで開いてよい開発サーバーのアドレス（手元の http / https だけ）。
    public static func isLocalAddress(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), url.port != nil else { return false }
        return host == "localhost" || host == "127.0.0.1"
    }

    // MARK: - 失敗の理由

    private static let inUsePattern = try! NSRegularExpression(
        pattern: #"(?:EADDRINUSE[^\n]*?:([0-9]{2,5})\b|[Pp]ort ([0-9]{2,5}) is already in use)"#)

    /// 自分で止めた以外の終わり方の理由。
    public static func failureReason(exit: DevServerExit, log: [String], foundAddress: Bool) -> String {
        let text = log.suffix(80).joined(separator: "\n")
        if exit.code == 127 || text.contains("command not found: npm") || text.contains("npm: command not found") {
            return "npm が見つかりません。ログインシェル（zsh）の PATH で node / npm を使えるようにしてください"
        }
        if text.contains("env: node: No such file or directory") || text.contains("command not found: node") {
            return "node が見つかりません。ログインシェル（zsh）の PATH で node を使えるようにしてください"
        }
        if text.contains("Missing script: \"dev\"") || text.contains("missing script: dev") {
            return "package.json に dev スクリプトがありません"
        }
        let range = NSRange(text.startIndex..., in: text)
        if let match = inUsePattern.firstMatch(in: text, range: range) {
            let port = [1, 2].compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }.first
            return "ポート\(port.map { " \($0) " } ?? "")は他のプロセスが使っています。そのプロセスを止めるか、別のポートで起動するよう dev スクリプトを直してください"
        }
        if foundAddress {
            return "開発サーバーが終了しました（\(exit.label)）"
        }
        return "開発サーバーがすぐ終了しました（\(exit.label)）。出力を確かめてください"
    }
}

/// 開発サーバーの出力の末尾。行に分け、色などの制御文字を落とし、古い行から捨てる。
public struct DevServerLog: Equatable, Sendable {
    public private(set) var lines: [String] = []
    private var pending = Data()
    public let limit: Int
    /// 改行の来ない出力をため込みすぎない。
    static let maxLineBytes = 16 * 1024

    public init(limit: Int = DevServerRules.maxLogLines) {
        self.limit = max(limit, 1)
    }

    /// 受け取った分を足し、改行まで揃った行を返す。
    @discardableResult
    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var completed: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            completed.append(Self.decode(pending[pending.startIndex..<newline]))
            pending.removeSubrange(pending.startIndex...newline)
        }
        if pending.count > Self.maxLineBytes {
            completed.append(Self.decode(pending))
            pending.removeAll()
        }
        push(completed)
        return completed
    }

    /// 終わった時に、改行の無い最後の行を確定させる。
    @discardableResult
    public mutating func finish() -> [String] {
        guard !pending.isEmpty else { return [] }
        let last = [Self.decode(pending)]
        pending.removeAll()
        push(last)
        return last
    }

    /// 見せる行（改行待ちの行も含む）。
    public var tail: [String] {
        pending.isEmpty ? lines : lines + [Self.decode(pending)]
    }

    private mutating func push(_ new: [String]) {
        lines.append(contentsOf: new)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    static func decode(_ bytes: Data) -> String {
        var text = String(decoding: bytes, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        // 進み具合の表示は \r で上書きするので、最後の書き込みだけ残す。
        if let last = text.range(of: "\r", options: .backwards) { text = String(text[last.upperBound...]) }
        return clean(text)
    }

    private static let escapes = try! NSRegularExpression(
        pattern: #"\u001B\][^\u0007\u001B]*(?:\u0007|\u001B\\)|\u001B\[[0-9;?]*[ -/]*[@-~]|\u001B[@-Z\\-_]"#)

    /// 端末の制御（色・カーソル移動・タイトル）を落とし、タブ以外の制御文字を除く。
    public static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = escapes.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return String(String.UnicodeScalarView(stripped.unicodeScalars.filter { $0 == "\t" || !($0.properties.generalCategory == .control) }))
    }
}

/// 止める手順の次の一手。プロセスグループに SIGTERM → 猶予の後も残れば SIGKILL。
public enum DevServerStopStep: Equatable, Sendable {
    case terminate
    case wait
    case kill
    case finished
}

public enum DevServerStopPlan {
    /// SIGTERM の後に待つ時間。
    public static let grace: TimeInterval = 3
    /// SIGKILL の後に消えるのを待つ時間（それでも残ればあきらめる）。
    public static let killWait: TimeInterval = 1

    /// 自分の子のグループでなければ何も送らない（番号が別のプロセスに使い回されている恐れがあるため）。
    public static func next(ownsGroup: Bool, groupAlive: Bool, termSentAt: Date?, killSentAt: Date?, now: Date,
                            grace: TimeInterval = grace, killWait: TimeInterval = killWait) -> DevServerStopStep {
        guard ownsGroup, groupAlive else { return .finished }
        guard let termSentAt else { return .terminate }
        guard let killSentAt else { return now.timeIntervalSince(termSentAt) >= grace ? .kill : .wait }
        return now.timeIntervalSince(killSentAt) >= killWait ? .finished : .wait
    }
}
