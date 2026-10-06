import AppKit
import SwiftTerm
import MonitorKit

extension ClaudeTerminalView {
    /// `directory` で `claude` を起動する（ログインシェルで PATH を得て、API キーは環境とシェルの二重で外す）。
    /// `resumeSessionId` があれば `--resume=<id>` で再開する。不正な id なら起動せず false。
    func launchClaude(in directory: String, resumeSessionId: String? = nil) -> Bool {
        var command = "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; exec claude"
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

    /// 親プロセスの環境を引き継ぎつつ、課金経路となる API キーを除去した環境を作る。
    private static func buildSafeEnvironment() -> [String] {
        var dict = ProcessInfo.processInfo.environment
        dict.removeValue(forKey: "ANTHROPIC_API_KEY")
        dict.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        // Claude Code の中から起動された時の子セッション印（transcript 保存オフ・SDK 扱い等）を持ち込まないため。
        for key in dict.keys where key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_SDK")
            || ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "AI_AGENT"].contains(key) {
            dict.removeValue(forKey: key)
        }
        dict["TERM"] = "xterm-256color"
        dict["COLORTERM"] = "truecolor"
        return dict.map { "\($0.key)=\($0.value)" }
    }
}
