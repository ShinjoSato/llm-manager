import AppKit
import SwiftTerm
import MonitorKit

extension ClaudeTerminalView {
    /// 生の出力は TUI がカーソル移動で語を並べるので照合できない。描画後の実画面の末尾を間引いて見る。
    func scan() {
        guard !limitCheckPending else { return }
        limitCheckPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.limitCheckPending = false
            if LimitGuard.screenLimitLine(self.limitScreenLines()) != nil { self.reachLimit() }
        }
    }

    /// 上限到達として 1 回だけ終了を流す（画面の表示からも、公式の残量からも呼ばれる）。
    func reachLimit() {
        guard !limitHandled, process?.running == true else { return }
        limitHandled = true
        let pid = process.shellPid
        // 起動直後に呼ばれても受け手が pid を取り終えてから止めるよう、次の周回に回す。
        DispatchQueue.main.async { [weak self] in self?.onLimitReached?() }
        // 対話 zsh は SIGTERM を無視するので、claude に exec する前に止めると生き残る。残っていれば強制終了する。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if Self.isLiveChild(pid) { kill(pid, SIGKILL) }
        }
    }

    /// 自分の子で、まだ終わっていない（ゾンビでない）プロセスか。pid の再利用で他人を殺さないため親を確かめる。
    private static func isLiveChild(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_ppid == UInt32(getpid()) && info.pbi_status != UInt32(SZOMB)
    }
}
