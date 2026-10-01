import SwiftUI
import AppKit

/// ホスト中の端末を SwiftUI に差し込む。端末ビューはセッションが持ち続け、ここでは付け外しだけする（プロセスは止めない）。
struct TerminalHost: NSViewRepresentable {
    let terminal: ClaudeTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        guard terminal.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        terminal.removeFromSuperview()
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        DispatchQueue.main.async { [weak terminal] in
            guard let terminal, terminal.window != nil else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
    }
}

/// GitHub ボード（既存の AppKit ビュー）を差し込む。
struct BoardHost: NSViewRepresentable {
    let board: GitHubBoardView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        guard board.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        board.removeFromSuperview()
        board.translatesAutoresizingMaskIntoConstraints = true
        board.frame = container.bounds
        board.autoresizingMask = [.width, .height]
        container.addSubview(board)
    }
}
