import Foundation

/// 動いている Xcode 1 つ（プロセスとアプリの場所）。
public struct RunningXcode: Equatable, Sendable {
    public var pid: Int32
    public var bundlePath: String

    public init(pid: Int32, bundlePath: String) {
        self.pid = pid
        self.bundlePath = bundlePath
    }

    /// その Xcode の Developer フォルダ（mcpbridge と xcrun の版をこの Xcode にそろえる）。
    public var developerDir: String {
        (XcodeSelection.normalized(bundlePath) as NSString).appendingPathComponent("Contents/Developer")
    }
}

/// mcpbridge をどの Xcode につなぐか（起動のたびに動いている Xcode を数え直して決める）。
public struct XcodeBridgeTarget: Equatable, Sendable {
    /// 選んだ Xcode の PID（変わったら mcpbridge を作り直すための印）。nil なら決められなかった。
    public var pid: Int32?
    /// `DEVELOPER_DIR`。nil なら xcode-select のまま。
    public var developerDir: String?
    /// 画面に出す案内（どれにつなぐか決められなかった時）。
    public var notice: String?

    public init(pid: Int32?, developerDir: String?, notice: String? = nil) {
        self.pid = pid
        self.developerDir = developerDir
        self.notice = notice
    }

    /// 子の環境に、選んだ Xcode の Developer フォルダを入れる（xcrun と mcpbridge の版をそろえる）。
    /// `MCP_XCODE_PID` は渡さない: 渡すと GUI の Xcode へ直につなぐ形になり、ウィンドウが 1 つも開いていないと Xcode が接続を断る（Xcode 27 で確認）。
    public func environment(base: [String: String]) -> [String: String] {
        var environment = base
        environment["MCP_XCODE_PID"] = nil
        if let developerDir { environment["DEVELOPER_DIR"] = developerDir }
        return environment
    }

    /// 同じ mcpbridge を使い回せるか（PID と Developer フォルダが同じ時だけ）。
    public func sameConnection(as other: XcodeBridgeTarget) -> Bool {
        pid == other.pid && developerDir == other.developerDir
    }
}

public enum XcodeSelection {
    public static let ambiguousNotice =
        "Xcode が複数動いていて、xcode-select の Xcode はその中にありません。どの Xcode で描くかは mcpbridge に任せます（使う Xcode だけを残すと確実です）"

    /// 動いている Xcode が 0 なら nil。1 つならそれ、複数なら xcode-select の Xcode、それも無ければ PID を渡さず案内を出す。
    public static func target(running: [RunningXcode], selectedDeveloperDir: String?) -> XcodeBridgeTarget? {
        guard let first = running.first else { return nil }
        if running.count == 1 { return XcodeBridgeTarget(pid: first.pid, developerDir: first.developerDir) }
        if let selected = selectedDeveloperDir.map(normalized),
           let match = running.filter({ normalized($0.developerDir) == selected }).min(by: { $0.pid < $1.pid }) {
            return XcodeBridgeTarget(pid: match.pid, developerDir: match.developerDir)
        }
        return XcodeBridgeTarget(pid: nil, developerDir: nil, notice: ambiguousNotice)
    }

    /// 末尾の `/` とシンボリックリンクをそろえる（`/Applications/Xcode.app` と同じものを指す別名を同じとみなす）。
    static func normalized(_ path: String) -> String {
        XcodeWorkspaceList.normalized((path as NSString).resolvingSymlinksInPath)
    }

    /// xcode-select の Developer フォルダ（`DEVELOPER_DIR` があればそれが優先される）。
    public static func selectedDeveloperDir(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let dir = environment["DEVELOPER_DIR"], !dir.isEmpty { return dir }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
