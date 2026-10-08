import AppKit
import SwiftTerm
import MonitorKit

extension ClaudeTerminalView {
    /// `directory` で claude を起動する。`resumeSessionId` があれば `--resume=<id>` で再開し、使えない形なら起動せず false。
    func launchClaude(in directory: String, resumeSessionId: String? = nil) -> Bool {
        var command = "\(ChildEnvironment.unsetCommand); exec claude"
        if let resumeSessionId {
            // シェルのコマンド行に埋め込むので UUID の形のものだけを `--resume=<id>` で渡す。
            guard let argument = SessionHandover.resumeArgument(resumeSessionId) else { return false }
            command += " \(argument)"
        }
        let env = Self.buildSafeEnvironment()
        startProcess(
            executable: "/bin/zsh",
            // -l で PATH を得る。環境から抜いた API キーをシェルの設定が戻しても効かないよう、unset してから exec。
            args: ["-lic", command],
            environment: env,
            execName: nil,
            currentDirectory: directory
        )
        startStatusMonitoring()
        LimitWatch.shared.register(self)
        return true
    }

    /// 親の環境から課金経路になる API キーと子セッションの印を除いた環境。
    private static func buildSafeEnvironment() -> [String] {
        var dict = ChildEnvironment.sanitized(ProcessInfo.processInfo.environment)
        dict["TERM"] = "xterm-256color"
        dict["COLORTERM"] = "truecolor"
        return dict.map { "\($0.key)=\($0.value)" }
    }
}
