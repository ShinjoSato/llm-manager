import AppKit

/// GitHub Projects 風のカンバン表示。
/// 列 = ステータス（Todo / In Progress / Debug / Review / Done / その他）、カード = Issue。
/// ダークテーマで、列は横スクロール・各列は縦スクロール、カードはクリックで GitHub を開く。
final class GitHubBoardView: NSView {

    private let mapping: BoardMapping
    private let summaryLabel = NSTextField(labelWithString: "読み込み中…")
    private let columnsScroll = NSScrollView()
    private let columnsStack = NSStackView()

    // MARK: - 配色（GitHub ダーク準拠・固定 sRGB）
    private enum Palette {
        static let background = NSColor(srgbRed: 0.051, green: 0.067, blue: 0.090, alpha: 1) // #0d1117
        static let card       = NSColor(srgbRed: 0.086, green: 0.106, blue: 0.133, alpha: 1) // #161b22
        static let border     = NSColor(srgbRed: 0.188, green: 0.212, blue: 0.239, alpha: 1) // #30363d
        static let primary    = NSColor(srgbRed: 0.902, green: 0.929, blue: 0.953, alpha: 1) // #e6edf3
        static let secondary  = NSColor(srgbRed: 0.545, green: 0.580, blue: 0.620, alpha: 1) // #8b949e
    }

    private static let statusOrder = ["Todo", "In Progress", "Debug", "Review", "Done"]

    private static func color(for status: String) -> NSColor {
        switch status {
        case "Todo":        return NSColor(srgbRed: 0.545, green: 0.580, blue: 0.620, alpha: 1) // gray
        case "In Progress": return NSColor(srgbRed: 0.823, green: 0.600, blue: 0.137, alpha: 1) // gold
        case "Debug":       return NSColor(srgbRed: 0.972, green: 0.318, blue: 0.286, alpha: 1) // red
        case "Review":      return NSColor(srgbRed: 0.639, green: 0.443, blue: 0.968, alpha: 1) // purple
        case "Done":        return NSColor(srgbRed: 0.639, green: 0.443, blue: 0.968, alpha: 1) // purple
        default:            return NSColor(srgbRed: 0.545, green: 0.580, blue: 0.620, alpha: 1)
        }
    }

    private static func symbol(for status: String) -> String {
        switch status {
        case "Todo":        return "circle"
        case "In Progress": return "circle.righthalf.filled"
        case "Debug":       return "circle"
        case "Review":      return "circle.righthalf.filled"
        case "Done":        return "checkmark.circle.fill"
        default:            return "circle.dashed"
        }
    }

    init(mapping: BoardMapping) {
        self.mapping = mapping
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = Palette.background.cgColor
        setup()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        // 細い上部バー（サマリ + 更新）
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = Palette.secondary
        summaryLabel.lineBreakMode = .byTruncatingTail

        let refresh = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "更新") ?? NSImage(),
            target: self, action: #selector(reload))
        refresh.isBordered = false
        refresh.contentTintColor = Palette.secondary
        refresh.toolTip = "ボードを再取得"

        let topBar = NSStackView(views: [summaryLabel, NSView(), refresh])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        topBar.translatesAutoresizingMaskIntoConstraints = false

        // 列の横スクロール
        columnsScroll.hasHorizontalScroller = true
        columnsScroll.hasVerticalScroller = false
        columnsScroll.drawsBackground = false
        columnsScroll.translatesAutoresizingMaskIntoConstraints = false

        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        columnsStack.orientation = .horizontal
        columnsStack.alignment = .height   // 各列を同じ高さに伸ばす
        columnsStack.spacing = 10
        columnsStack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 10, right: 10)
        columnsStack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(columnsStack)
        columnsScroll.documentView = doc

        addSubview(topBar)
        addSubview(columnsScroll)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),

            columnsScroll.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            columnsScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            columnsScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            columnsScroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            // documentView: 高さは表示領域に合わせ（縦は各列内でスクロール）、幅は内容で伸びる
            doc.topAnchor.constraint(equalTo: columnsScroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: columnsScroll.contentView.leadingAnchor),
            doc.heightAnchor.constraint(equalTo: columnsScroll.contentView.heightAnchor),

            columnsStack.topAnchor.constraint(equalTo: doc.topAnchor),
            columnsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            columnsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            columnsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor)
        ])
    }

    // MARK: - 読み込み

    @objc func reload() {
        summaryLabel.stringValue = "読み込み中…"
        clearColumns()
        GitHubBoard.fetchItems(for: mapping) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let items): self.render(items)
            case .failure(let error): self.renderError(error)
            }
        }
    }

    private func clearColumns() {
        for v in columnsStack.arrangedSubviews {
            columnsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    private func render(_ items: [BoardItem]) {
        clearColumns()

        var groups: [String: [BoardItem]] = [:]
        for it in items { groups[it.status, default: []].append(it) }
        // Done はこの用途では表示しない
        let extras = groups.keys.filter { !Self.statusOrder.contains($0) && $0 != "Done" }.sorted()
        let order = Self.statusOrder.filter { $0 != "Done" && groups[$0] != nil } + extras

        let shownCount = order.reduce(0) { $0 + (groups[$1]?.count ?? 0) }
        let parts = order.map { "\($0):\(groups[$0]?.count ?? 0)" }
        summaryLabel.stringValue = "未完了 \(shownCount) 件  [" + parts.joined(separator: " / ") + "]"

        for status in order {
            let arr = groups[status] ?? []
            columnsStack.addArrangedSubview(makeColumn(status: status, items: arr))
        }
    }

    private func renderError(_ error: GitHubBoardError) {
        clearColumns()
        let message: String
        switch error {
        case .ghFailed(let m): message = "取得に失敗しました（gh の認証/スコープを確認）\n\(m)"
        case .parseFailed:     message = "応答の解析に失敗しました。"
        }
        summaryLabel.stringValue = "エラー"
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = NSColor(srgbRed: 0.972, green: 0.318, blue: 0.286, alpha: 1)
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        columnsStack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalToConstant: 360).isActive = true
    }

    // MARK: - 列

    private func makeColumn(status: String, items: [BoardItem]) -> NSView {
        let accent = Self.color(for: status)
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: 300).isActive = true

        // ── ヘッダ ──
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: Self.symbol(for: status), accessibilityDescription: status)
        icon.contentTintColor = accent
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)

        let name = NSTextField(labelWithString: status)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = Palette.primary

        let count = NSTextField(labelWithString: "\(items.count)")
        count.font = .systemFont(ofSize: 12, weight: .medium)
        count.textColor = Palette.secondary

        let dots = decorIcon("ellipsis")
        let plus = decorIcon("plus")

        let headerTop = NSStackView(views: [icon, name, count, NSView(), dots, plus])
        headerTop.orientation = .horizontal
        headerTop.alignment = .centerY
        headerTop.spacing = 6

        let header = NSStackView(views: [headerTop])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3
        header.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 6, right: 4)
        header.translatesAutoresizingMaskIntoConstraints = false

        // ── カード（縦スクロール）──
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let cardsDoc = FlippedView()
        cardsDoc.translatesAutoresizingMaskIntoConstraints = false
        let cards = NSStackView(views: items.map { makeCard($0, accent: accent) })
        cards.orientation = .vertical
        cards.alignment = .width
        cards.spacing = 8
        cards.translatesAutoresizingMaskIntoConstraints = false
        cardsDoc.addSubview(cards)
        scroll.documentView = cardsDoc

        column.addSubview(header)
        column.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: column.topAnchor),
            header.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: column.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: column.bottomAnchor),

            cardsDoc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            cardsDoc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            cardsDoc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            cardsDoc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            cards.topAnchor.constraint(equalTo: cardsDoc.topAnchor),
            cards.leadingAnchor.constraint(equalTo: cardsDoc.leadingAnchor),
            cards.trailingAnchor.constraint(equalTo: cardsDoc.trailingAnchor),
            cards.bottomAnchor.constraint(equalTo: cardsDoc.bottomAnchor)
        ])
        return column
    }

    private func decorIcon(_ symbol: String) -> NSImageView {
        let v = NSImageView()
        v.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        v.contentTintColor = Palette.secondary
        v.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        return v
    }

    // MARK: - カード

    private func makeCard(_ item: BoardItem, accent: NSColor) -> NSView {
        let card = ClickableCard(url: item.url)
        card.wantsLayer = true
        card.layer?.backgroundColor = Palette.card.cgColor
        card.layer?.cornerRadius = 6
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Palette.border.cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: Self.symbol(for: item.status), accessibilityDescription: nil)
        icon.contentTintColor = accent
        icon.symbolConfiguration = .init(pointSize: 10, weight: .regular)

        let ref = item.number.map { "#\($0)" } ?? ""
        let repoText = item.repo.isEmpty ? ref : "\(item.repo) \(ref)"
        let meta = NSTextField(labelWithString: repoText)
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = Palette.secondary
        meta.lineBreakMode = .byTruncatingTail

        let metaRow = NSStackView(views: [icon, meta])
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 5

        let titleText = item.assignee.isEmpty ? item.title : "\(item.title)  @\(item.assignee)"
        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = Palette.primary
        title.isSelectable = false
        // 2 行で固定し、はみ出しは末尾「…」で省略
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.cell?.wraps = true
        title.cell?.truncatesLastVisibleLine = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = NSStackView(views: [metaRow, title])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 5
        content.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        // カードの高さを全カードで統一（メタ1行 + タイトル2行 + 余白）
        card.heightAnchor.constraint(equalToConstant: 82).isActive = true
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor)
        ])
        return card
    }
}

/// 上から下へ並べるための反転ビュー（スクロール内容用）。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// クリックで GitHub を開くカード。
private final class ClickableCard: NSView {
    private let url: String?
    init(url: String?) {
        self.url = url
        super.init(frame: .zero)
        if url != nil {
            toolTip = "クリックで GitHub を開く"
            addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(open)))
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    @objc private func open() {
        if let s = url, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
}
