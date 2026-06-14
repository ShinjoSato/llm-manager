import AppKit

/// 右ペイン: 開いた Claude Code セッションを**タイル状に並べて同時表示**する。
/// 同じプロジェクトは1ペインに集約（既に開いていればフォーカスのみ）。
final class TileContainerViewController: NSViewController {

    private let tileView = TileView()
    private var panes: [String: TerminalPaneViewController] = [:]   // path → pane
    private let placeholder = NSTextField(labelWithString: "← 左のプロジェクトをダブルクリックして Claude Code を起動")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 600))

        placeholder.font = .systemFont(ofSize: 14)
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])

        tileView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tileView)
        NSLayoutConstraint.activate([
            tileView.topAnchor.constraint(equalTo: root.topAnchor),
            tileView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tileView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tileView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        self.view = root
        updatePlaceholder()
    }

    /// プロジェクトのペインを開く（既にあればフォーカスのみ）。
    func openOrFocus(_ project: ManagedProject) {
        if let existing = panes[project.path] {
            existing.focusTerminal()
            return
        }
        let pane = TerminalPaneViewController(project: project)
        pane.onClose = { [weak self] in self?.close(path: project.path) }
        addChild(pane)
        panes[project.path] = pane
        tileView.addPane(pane.view)
        pane.startIfNeeded()
        pane.focusTerminal()
        updatePlaceholder()
    }

    private func close(path: String) {
        guard let pane = panes.removeValue(forKey: path) else { return }
        tileView.removePane(pane.view)
        pane.removeFromParent()
        updatePlaceholder()
    }

    private func updatePlaceholder() {
        placeholder.isHidden = !panes.isEmpty
    }
}

/// パネル群を均等なグリッドに手動レイアウトするビュー。
private final class TileView: NSView {
    private(set) var panes: [NSView] = []
    private let gap: CGFloat = 6

    override var isFlipped: Bool { true }   // 左上原点で考える

    func addPane(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        addSubview(view)
        panes.append(view)
        needsLayout = true
    }

    func removePane(_ view: NSView) {
        view.removeFromSuperview()
        panes.removeAll { $0 === view }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let n = panes.count
        guard n > 0 else { return }
        let cols = Int(ceil(Double(n).squareRoot()))
        let rows = Int(ceil(Double(n) / Double(cols)))
        let cellW = (bounds.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
        let cellH = (bounds.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
        for (i, pane) in panes.enumerated() {
            let r = i / cols
            let c = i % cols
            let x = gap + CGFloat(c) * (cellW + gap)
            let y = gap + CGFloat(r) * (cellH + gap)
            pane.frame = NSRect(x: x, y: y, width: max(cellW, 1), height: max(cellH, 1))
        }
    }
}
