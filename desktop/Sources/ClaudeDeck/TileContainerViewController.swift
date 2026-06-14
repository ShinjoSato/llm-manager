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
///
/// 並び替え（Issue #10）:
/// - 各ペインの上端に薄い「ドラッグハンドル」オーバーレイ（grip）を TileView 自身が重ねて配置し、
///   そのグリップ上の mouseDown/Dragged/Up でドラッグを受ける。
///   （ペイン root にサブビューがあるとイベントが TileView 本体に届かないため、
///    確実に開始点を取れるオーバーレイ方式を採用。ヘッダーのボタンはボタンが消費するので住み分く。）
/// - 並び替えは insert 方式: ドラッグ元を抜き、ドロップ座標から算出した index に挿入して再レイアウト。
/// - 子プロセスには一切触れず、`panes` 配列の順序を入れ替えるだけ。
private final class TileView: NSView {
    private(set) var panes: [NSView] = []
    private let gap: CGFloat = 6
    private let handleHeight: CGFloat = 30   // ヘッダーのタイトル/余白帯に相当する高さ

    // 各ペインに対応するドラッグハンドル（grip）。panes と同じ index で対応させる。
    private var grips: [NSView] = []

    // ドラッグ中の状態
    private var draggingIndex: Int? = nil
    private var dragGhost: NSView? = nil       // ドラッグ中ペインの半透明スナップショット
    private var dragOffset: NSPoint = .zero     // ペイン原点からマウスまでのオフセット

    override var isFlipped: Bool { true }   // 左上原点で考える

    func addPane(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        addSubview(view)
        panes.append(view)

        // 対応するドラッグハンドルを生成（透明。grip 自身がマウスイベントを受ける）。
        let grip = GripView()
        grip.onMouseDown = { [weak self, weak grip] event in self?.beginDrag(from: grip, event: event) }
        grip.onMouseDragged = { [weak self] event in self?.updateDrag(event: event) }
        grip.onMouseUp = { [weak self] event in self?.endDrag(event: event) }
        addSubview(grip)
        grips.append(grip)

        needsLayout = true
    }

    func removePane(_ view: NSView) {
        if let idx = panes.firstIndex(where: { $0 === view }) {
            grips[idx].removeFromSuperview()
            grips.remove(at: idx)
        }
        view.removeFromSuperview()
        panes.removeAll { $0 === view }
        needsLayout = true
    }

    // MARK: - グリッド計算（layout とドロップ index 算出で共有）

    private struct Grid { let cols: Int; let rows: Int; let cellH: CGFloat }

    private func grid(for n: Int) -> Grid {
        let cols = Int(ceil(Double(n).squareRoot()))
        let rows = Int(ceil(Double(n) / Double(cols)))
        let cellH = (bounds.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
        return Grid(cols: cols, rows: rows, cellH: cellH)
    }

    /// index i のセル矩形を返す（layout と同じ計算）。
    private func cellRect(_ i: Int, n: Int, _ g: Grid) -> NSRect {
        let r = i / g.cols
        let c = i % g.cols
        let itemsInRow = min(g.cols, n - r * g.cols)
        let rowCellW = (bounds.width - gap * CGFloat(itemsInRow + 1)) / CGFloat(itemsInRow)
        let x = gap + CGFloat(c) * (rowCellW + gap)
        let y = gap + CGFloat(r) * (g.cellH + gap)
        return NSRect(x: x, y: y, width: max(rowCellW, 1), height: max(g.cellH, 1))
    }

    override func layout() {
        super.layout()
        let n = panes.count
        guard n > 0 else { return }
        let g = grid(for: n)
        for (i, pane) in panes.enumerated() {
            let rect = cellRect(i, n: n, g)
            pane.frame = rect
            // ハンドルはセル上端の帯。ペインより前面に出して確実にイベントを受ける。
            if i < grips.count {
                let grip = grips[i]
                grip.frame = NSRect(x: rect.minX, y: rect.minY,
                                    width: rect.width, height: min(handleHeight, rect.height))
                grip.isHidden = (draggingIndex == i)   // ドラッグ中の元グリップは隠す
            }
        }
    }

    // MARK: - ドラッグ処理（insert 方式）

    private func beginDrag(from grip: NSView?, event: NSEvent) {
        guard let grip = grip, let idx = grips.firstIndex(where: { $0 === grip }) else { return }
        draggingIndex = idx
        let pane = panes[idx]
        let pt = convert(event.locationInWindow, from: nil)
        dragOffset = NSPoint(x: pt.x - pane.frame.minX, y: pt.y - pane.frame.minY)

        // ドラッグ中ゴースト（半透明）を最前面に作成し、元ペインは薄く見せる。
        let ghost = NSView(frame: pane.frame)
        ghost.wantsLayer = true
        ghost.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        ghost.layer?.borderColor = NSColor.controlAccentColor.cgColor
        ghost.layer?.borderWidth = 2
        ghost.layer?.cornerRadius = 4
        addSubview(ghost, positioned: .above, relativeTo: nil)
        dragGhost = ghost
        pane.alphaValue = 0.4
        // 元グリップを隠してゴーストが前面で動けるようにする。
        needsLayout = true
    }

    private func updateDrag(event: NSEvent) {
        guard draggingIndex != nil, let ghost = dragGhost else { return }
        let pt = convert(event.locationInWindow, from: nil)
        ghost.frame.origin = NSPoint(x: pt.x - dragOffset.x, y: pt.y - dragOffset.y)
    }

    private func endDrag(event: NSEvent) {
        guard let from = draggingIndex else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let to = dropIndex(at: pt)

        // 後片付け
        dragGhost?.removeFromSuperview()
        dragGhost = nil
        panes[from].alphaValue = 1.0
        draggingIndex = nil

        // insert 方式: from を抜いて to に挿入（panes と grips を同期して並べ替え）。
        if to != from {
            let pane = panes.remove(at: from)
            let grip = grips.remove(at: from)
            let clamped = min(max(to, 0), panes.count)
            panes.insert(pane, at: clamped)
            grips.insert(grip, at: clamped)
        }
        needsLayout = true
    }

    /// ドロップ座標がどのスロット（挿入先 index）に当たるかをグリッドから算出。
    private func dropIndex(at pt: NSPoint) -> Int {
        let n = panes.count
        guard n > 0 else { return 0 }
        let g = grid(for: n)
        // 各セル矩形の中心との距離が最小のセルを採用（範囲外でも最近傍に寄せる）。
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for i in 0..<n {
            let rect = cellRect(i, n: n, g)
            let cx = rect.midX, cy = rect.midY
            let d = (pt.x - cx) * (pt.x - cx) + (pt.y - cy) * (pt.y - cy)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }
}

/// 透明なドラッグハンドル。マウスイベントをクロージャで TileView に橋渡しする。
private final class GripView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
}
