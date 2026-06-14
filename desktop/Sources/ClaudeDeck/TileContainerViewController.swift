import AppKit

/// 右ペイン: 開いた Claude Code セッションを**タイル状に並べて同時表示**する。
/// 同じプロジェクトは1ペインに集約（既に開いていればフォーカスのみ）。
final class TileContainerViewController: NSViewController {

    private let tileView = TileView()
    private var panes: [String: TerminalPaneViewController] = [:]   // path → pane
    private let placeholder = NSTextField(labelWithString: "← 左のプロジェクトをダブルクリックして Claude Code を起動")
    private let orientationControl = NSSegmentedControl()

    private let orientationDefaultsKey = "TileOrientation"   // "row" / "column"

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 600))

        // 上部ツールバー: 並びの縦/横トグルを右端に置く。
        let toolbar = NSView()
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)

        configureOrientationControl()
        orientationControl.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(orientationControl)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(divider)

        tileView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tileView)

        placeholder.font = .systemFont(ofSize: 14)
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(placeholder)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 38),

            orientationControl.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -10),
            orientationControl.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            divider.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),

            tileView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            tileView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tileView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tileView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            placeholder.centerXAnchor.constraint(equalTo: tileView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: tileView.centerYAnchor)
        ])
        self.view = root
        updatePlaceholder()
    }

    /// 並び向きトグル（横長=行優先 / 縦長=列優先）を構成する。保存値があれば復元する。
    private func configureOrientationControl() {
        orientationControl.segmentCount = 2
        orientationControl.trackingMode = .selectOne
        let wide = NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: "横長（行優先）")
        let tall = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "縦長（列優先）")
        if let wide { orientationControl.setImage(wide, forSegment: 0) } else { orientationControl.setLabel("横", forSegment: 0) }
        if let tall { orientationControl.setImage(tall, forSegment: 1) } else { orientationControl.setLabel("縦", forSegment: 1) }
        orientationControl.setToolTip("横長（上下に積む・行優先）", forSegment: 0)
        orientationControl.setToolTip("縦長（左右に並べる・列優先）", forSegment: 1)
        orientationControl.target = self
        orientationControl.action = #selector(orientationChanged)

        let saved = UserDefaults.standard.string(forKey: orientationDefaultsKey)
        let orientation: TileView.Orientation = (saved == "column") ? .columnMajor : .rowMajor
        tileView.orientation = orientation
        orientationControl.selectedSegment = (orientation == .columnMajor) ? 1 : 0
    }

    @objc private func orientationChanged() {
        let orientation: TileView.Orientation = (orientationControl.selectedSegment == 1) ? .columnMajor : .rowMajor
        tileView.orientation = orientation
        UserDefaults.standard.set(orientation == .columnMajor ? "column" : "row", forKey: orientationDefaultsKey)
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
    /// 並びの向き。行優先=横長（上下に積む）/ 列優先=縦長（左右に並べる）。
    enum Orientation { case rowMajor, columnMajor }
    var orientation: Orientation = .rowMajor { didSet { needsLayout = true } }

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

    // MARK: - レイアウト計算（layout とドロップ index 算出で共有）

    /// 現在の向きで、各ペイン（index 0..<n）のセル矩形を一括算出する。
    /// 行優先（横長）: cols=⌈√n⌉ の行に詰め、最終行を実ペイン数で横いっぱいに等分（#11 の自動フィル）。
    /// 列優先（縦長）: cols=⌈√n⌉ の列に詰め、早い列ほど少なく（＝背の高い単独ペイン）し余りを後ろの列へ。
    ///   各列を実ペイン数で縦いっぱいに等分。3枚なら「左1/右2」になる。
    private func cellRects(_ n: Int) -> [NSRect] {
        guard n > 0 else { return [] }
        let W = bounds.width, H = bounds.height
        var rects = [NSRect](repeating: .zero, count: n)
        let cols = Int(ceil(Double(n).squareRoot()))
        switch orientation {
        case .rowMajor:
            let rows = Int(ceil(Double(n) / Double(cols)))
            let cellH = (H - gap * CGFloat(rows + 1)) / CGFloat(rows)
            for i in 0..<n {
                let r = i / cols
                let c = i % cols
                let itemsInRow = min(cols, n - r * cols)
                let cellW = (W - gap * CGFloat(itemsInRow + 1)) / CGFloat(itemsInRow)
                let x = gap + CGFloat(c) * (cellW + gap)
                let y = gap + CGFloat(r) * (cellH + gap)
                rects[i] = NSRect(x: x, y: y, width: max(cellW, 1), height: max(cellH, 1))
            }
        case .columnMajor:
            let base = n / cols
            let rem = n % cols          // 後ろ rem 列が +1 個（＝早い列ほど少なく背が高い）
            let cellW = (W - gap * CGFloat(cols + 1)) / CGFloat(cols)
            var i = 0
            for c in 0..<cols {
                let itemsInCol = base + (c >= cols - rem ? 1 : 0)
                guard itemsInCol > 0 else { continue }
                let cellH = (H - gap * CGFloat(itemsInCol + 1)) / CGFloat(itemsInCol)
                let x = gap + CGFloat(c) * (cellW + gap)
                for r in 0..<itemsInCol {
                    let y = gap + CGFloat(r) * (cellH + gap)
                    rects[i] = NSRect(x: x, y: y, width: max(cellW, 1), height: max(cellH, 1))
                    i += 1
                }
            }
        }
        return rects
    }

    override func layout() {
        super.layout()
        let n = panes.count
        guard n > 0 else { return }
        let rects = cellRects(n)
        for (i, pane) in panes.enumerated() {
            pane.frame = rects[i]
            // 掴みはセル左上の小領域。ヘッダー右側のボタンは覆わない。
            // ドラッグ中も grip を隠さない（隠すと mouseUp が届かず後始末できなくなるため）。
            if i < grips.count {
                grips[i].frame = NSRect(x: rects[i].minX, y: rects[i].minY,
                                        width: min(handleWidth, rects[i].width),
                                        height: min(handleHeight, rects[i].height))
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

    /// ドロップ座標がどのスロット（挿入先 index）に当たるかを現在の向きのグリッドから算出。
    private func dropIndex(at pt: NSPoint) -> Int {
        let n = panes.count
        guard n > 0 else { return 0 }
        let rects = cellRects(n)
        // 各セル矩形の中心との距離が最小のセルを採用（範囲外でも最近傍に寄せる）。
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for i in 0..<n {
            let cx = rects[i].midX, cy = rects[i].midY
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
