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
/// - 各ペイン**左上の小さな掴み（grip）**を TileView 自身が重ねて配置し、その上の
///   mouseDown/Dragged/Up でドラッグを受ける。grip はヘッダー左端の小領域だけを占有するので、
///   見出し右側のボタン（スクショ/閉じる/トグル等）を塞がない。
/// - 並び替えは insert 方式: ドラッグ元を抜き、ドロップ座標から算出した index に挿入して再レイアウト。
/// - 子プロセスには一切触れず、`panes` 配列の順序を入れ替えるだけ。
private final class TileView: NSView {
    private(set) var panes: [NSView] = []
    private let gap: CGFloat = 6
    private let handleWidth: CGFloat = 26    // 掴みの幅（ヘッダー左端の小領域）
    private let handleHeight: CGFloat = 28   // ヘッダー帯に収まる高さ

    // 各ペインに対応するドラッグハンドル（grip）。panes と同じ index で対応させる。
    private var grips: [GripView] = []

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

        // 対応するドラッグハンドルを生成。grip 自身がマウスイベントを受ける。
        let grip = GripView()
        grip.onMouseDown = { [weak self, weak grip] event in self?.beginDrag(from: grip, event: event) }
        grip.onMouseDragged = { [weak self] event in self?.updateDrag(event: event) }
        grip.onMouseUp = { [weak self] event in self?.endDrag(event: event) }
        addSubview(grip)
        grips.append(grip)

        bringGripsToFront()
        needsLayout = true
    }

    func removePane(_ view: NSView) {
        // 並び替え中のペインが消えた場合に備えて状態を確実にリセット。
        resetDragState()
        if let idx = panes.firstIndex(where: { $0 === view }) {
            grips[idx].removeFromSuperview()
            grips.remove(at: idx)
        }
        view.removeFromSuperview()
        panes.removeAll { $0 === view }
        needsLayout = true
    }

    /// すべての grip を最前面へ。reorder 後も grip が常にペインより前面でイベントを受けられるようにする。
    private func bringGripsToFront() {
        for grip in grips { addSubview(grip, positioned: .above, relativeTo: nil) }
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
            // 掴みはセル左上の小領域。ヘッダー右側のボタンは覆わない。
            // ドラッグ中も grip を隠さない（隠すと mouseUp が届かず後始末できなくなるため）。
            if i < grips.count {
                grips[i].frame = NSRect(x: rect.minX, y: rect.minY,
                                        width: min(handleWidth, rect.width),
                                        height: min(handleHeight, rect.height))
            }
        }
    }

    // MARK: - ドラッグ処理（insert 方式）

    private func beginDrag(from grip: GripView?, event: NSEvent) {
        // 直前のドラッグが何らかの理由で終わっていなければ確実に後始末してから開始（ゴースト残留防止）。
        resetDragState()
        guard let grip = grip, let idx = grips.firstIndex(where: { $0 === grip }) else { return }
        draggingIndex = idx
        let pane = panes[idx]
        let pt = convert(event.locationInWindow, from: nil)
        dragOffset = NSPoint(x: pt.x - pane.frame.minX, y: pt.y - pane.frame.minY)

        // ドラッグ中ゴースト（半透明）を最前面に作成し、元ペインは薄く見せる。
        let ghost = NSView(frame: pane.frame)
        ghost.wantsLayer = true
        ghost.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        ghost.layer?.borderColor = NSColor.controlAccentColor.cgColor
        ghost.layer?.borderWidth = 2
        ghost.layer?.cornerRadius = 6
        addSubview(ghost, positioned: .above, relativeTo: nil)
        dragGhost = ghost
        pane.alphaValue = 0.5
    }

    private func updateDrag(event: NSEvent) {
        guard draggingIndex != nil, let ghost = dragGhost else { return }
        let pt = convert(event.locationInWindow, from: nil)
        ghost.frame.origin = NSPoint(x: pt.x - dragOffset.x, y: pt.y - dragOffset.y)
    }

    private func endDrag(event: NSEvent) {
        guard let from = draggingIndex else { resetDragState(); return }
        let pt = convert(event.locationInWindow, from: nil)
        let to = dropIndex(at: pt)

        // ゴースト除去・減光復帰・draggingIndex クリアは必ずこの一経路で行う。
        resetDragState()

        // insert 方式: from を抜いて to に挿入（panes と grips を同期して並べ替え）。
        if to != from {
            let pane = panes.remove(at: from)
            let grip = grips.remove(at: from)
            let clamped = min(max(to, 0), panes.count)
            panes.insert(pane, at: clamped)
            grips.insert(grip, at: clamped)
            bringGripsToFront()
        }
        needsLayout = true
    }

    /// ドラッグ状態を完全に解消する（ゴースト除去・全ペインの減光復帰・index クリア）。
    /// これを通さない終了経路を作らないことで「青い選択が残って消えない」不具合を防ぐ。
    private func resetDragState() {
        dragGhost?.removeFromSuperview()
        dragGhost = nil
        for pane in panes { pane.alphaValue = 1.0 }
        draggingIndex = nil
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

/// ヘッダー左端に置く小さなドラッグハンドル。2×3 のドットで「掴み」を示し、
/// マウスイベントをクロージャで TileView に橋渡しする。
private final class GripView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "ドラッグしてペインを並べ替え"
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // ウィンドウが非アクティブでも最初のクリックでドラッグを開始できるようにする。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        let r: CGFloat = 1.5
        let (cols, rows) = (2, 3)
        let (spacingX, spacingY): (CGFloat, CGFloat) = (5, 5)
        let startX = bounds.midX - CGFloat(cols - 1) * spacingX / 2
        let startY = bounds.midY - CGFloat(rows - 1) * spacingY / 2
        for cx in 0..<cols {
            for cy in 0..<rows {
                let x = startX + CGFloat(cx) * spacingX - r
                let y = startY + CGFloat(cy) * spacingY - r
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: r * 2, height: r * 2)).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
}
