import AppKit

/// ペイン内の「App Store」表示。server の HTTP API（/api/appstore/:name）を叩き、
/// Web の AppStoreCard 相当のサマリ（審査・提出・最新ビルド・評価・指標）を表示する。
/// ダークテーマは GitHubBoardView と揃える。server 未起動・エラー時は安全に文言表示でフォールバックする。
final class AppStoreView: NSView {

    private let projectName: String
    private let summaryLabel = NSTextField(labelWithString: "読み込み中…")
    private let scroll = NSScrollView()
    private let rowsStack = NSStackView()

    // MARK: - 配色（GitHubBoardView と同じ GitHub ダーク準拠）
    private enum Palette {
        static let background = NSColor(srgbRed: 0.051, green: 0.067, blue: 0.090, alpha: 1) // #0d1117
        static let card       = NSColor(srgbRed: 0.086, green: 0.106, blue: 0.133, alpha: 1) // #161b22
        static let border     = NSColor(srgbRed: 0.188, green: 0.212, blue: 0.239, alpha: 1) // #30363d
        static let primary    = NSColor(srgbRed: 0.902, green: 0.929, blue: 0.953, alpha: 1) // #e6edf3
        static let secondary  = NSColor(srgbRed: 0.545, green: 0.580, blue: 0.620, alpha: 1) // #8b949e
        static let danger     = NSColor(srgbRed: 0.972, green: 0.318, blue: 0.286, alpha: 1) // red
        static let ok         = NSColor(srgbRed: 0.220, green: 0.737, blue: 0.408, alpha: 1) // green
        static let amber      = NSColor(srgbRed: 0.901, green: 0.706, blue: 0.227, alpha: 1) // amber
    }

    private enum Tone { case danger, ok, neutral }

    /// Web の AppStoreCard と同じ色基準。
    /// danger: REJECT/UNRESOLVED/FAILED/INVALID、ok: 配信可/完了/利用可、その他は neutral。
    private static func tone(for state: String) -> Tone {
        let s = state.uppercased()
        if s.contains("REJECT") || s.contains("UNRESOLVED") || s.contains("FAILED") || s.contains("INVALID") {
            return .danger
        }
        if ["READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "COMPLETE", "VALID"].contains(s) {
            return .ok
        }
        return .neutral
    }

    private static func color(for tone: Tone) -> NSColor {
        switch tone {
        case .danger:  return Palette.danger
        case .ok:      return Palette.ok
        case .neutral: return Palette.secondary
        }
    }

    init(projectName: String) {
        self.projectName = projectName
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
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = Palette.secondary
        summaryLabel.lineBreakMode = .byTruncatingTail

        let refresh = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "更新") ?? NSImage(),
            target: self, action: #selector(reload))
        refresh.isBordered = false
        refresh.contentTintColor = Palette.secondary
        refresh.toolTip = "App Store 状況を再取得"

        let topBar = NSStackView(views: [summaryLabel, NSView(), refresh])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        topBar.translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedDocView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8
        rowsStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rowsStack)
        scroll.documentView = doc

        addSubview(topBar)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),

            scroll.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            rowsStack.topAnchor.constraint(equalTo: doc.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor)
        ])
    }

    // MARK: - 読み込み

    @objc func reload() {
        summaryLabel.stringValue = "読み込み中…"
        clearRows()
        AppStoreClient.fetch(projectNamed: projectName) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let record): self.render(record)
            case .failure(let error):  self.renderError(error)
            }
        }
    }

    private func clearRows() {
        for v in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    private func render(_ r: AppStoreRecord) {
        clearRows()

        // アプリ単位の取得失敗（権限不足など）。
        if let err = r.error, !err.isEmpty {
            summaryLabel.stringValue = "取得エラー"
            addWrappedLabel("⚠ \(err)", color: Palette.danger)
            return
        }

        // 見出し（アプリ名 + bundleId）
        let titleText = r.appName.isEmpty ? projectName : r.appName
        addHeaderRow(title: titleText, bundleId: r.bundleId)

        var rowCount = 0

        // 審査ステータス（最新 + REJECT を含むもの）
        let shownVersions = Array(r.versions.prefix(1))
            + r.versions.dropFirst().filter { $0.state.uppercased().contains("REJECT") }
        for v in shownVersions {
            let meta = "\(v.platform) v\(v.version)\(v.createdDate.isEmpty ? "" : " · \(v.createdDate)")"
            addStatusRow(icon: "iphone", label: "審査", stateLabel: v.stateLabel, state: v.state, meta: meta)
            rowCount += 1
        }

        // 審査提出（最新1件）
        if let sub = r.submissions.first {
            let meta = sub.submittedDate.isEmpty ? "" : sub.submittedDate
            addStatusRow(icon: "checklist", label: "提出", stateLabel: sub.stateLabel, state: sub.state, meta: meta)
            rowCount += 1
        }

        // 最新 TestFlight ビルド
        if let b = r.builds.first {
            var meta = "#\(b.build)"
            if !b.uploadedDate.isEmpty { meta += " · \(b.uploadedDate)" }
            if b.expired { meta += " · 期限切れ" }
            addStatusRow(icon: "hammer", label: "Build", stateLabel: b.stateLabel, state: b.state, meta: meta)
            rowCount += 1
        }

        // レビュー件数 / 平均★
        if let rv = r.reviews, (rv.total ?? 0) > 0 || rv.itemCount > 0 {
            addReviewRow(rv)
            rowCount += 1
        }

        // パフォーマンス指標カテゴリ
        if !r.metricCategories.isEmpty {
            let cats = r.metricCategories.prefix(6).joined(separator: ", ")
            addStatusRow(icon: "waveform.path.ecg", label: "指標", stateLabel: nil, state: nil, meta: cats)
            rowCount += 1
        }

        if rowCount == 0 {
            addWrappedLabel("表示できる App Store 情報がありません（未提出 / 未リリースの可能性）。", color: Palette.secondary)
        }

        summaryLabel.stringValue = "App Store · \(titleText)"
    }

    private func renderError(_ error: AppStoreError) {
        clearRows()
        let message: String
        switch error {
        case .fetchFailed(let m): message = "取得に失敗しました\n\(m)"
        case .parseFailed:        message = "応答の解析に失敗しました。"
        case .empty:
            message = "App Store 認証が未設定です（server の secrets/appstore-credentials.json を確認）。"
        }
        summaryLabel.stringValue = "エラー"
        addWrappedLabel(message, color: Palette.danger)
    }

    // MARK: - 行ビルダー

    private func addHeaderRow(title: String, bundleId: String) {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.textColor = Palette.primary

        let row = NSStackView(views: [name])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8

        if !bundleId.isEmpty {
            let bid = NSTextField(labelWithString: bundleId)
            bid.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            bid.textColor = Palette.secondary
            bid.lineBreakMode = .byTruncatingTail
            row.addArrangedSubview(bid)
        }
        rowsStack.addArrangedSubview(row)
    }

    /// アイコン + ラベル + バッジ + メタ の1行。badge を出さない行（指標）は stateLabel=nil。
    private func addStatusRow(icon: String, label: String, stateLabel: String?, state: String?, meta: String) {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)
        iconView.contentTintColor = Palette.secondary
        iconView.symbolConfiguration = .init(pointSize: 11, weight: .regular)

        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 11)
        labelView.textColor = Palette.secondary
        labelView.setContentHuggingPriority(.required, for: .horizontal)

        let labelBox = NSView()
        labelBox.translatesAutoresizingMaskIntoConstraints = false
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelBox.addSubview(labelView)
        NSLayoutConstraint.activate([
            labelBox.widthAnchor.constraint(equalToConstant: 44),
            labelView.leadingAnchor.constraint(equalTo: labelBox.leadingAnchor),
            labelView.centerYAnchor.constraint(equalTo: labelBox.centerYAnchor),
            labelView.trailingAnchor.constraint(lessThanOrEqualTo: labelBox.trailingAnchor)
        ])

        let row = NSStackView(views: [iconView, labelBox])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6

        if let stateLabel, let state {
            row.addArrangedSubview(makeBadge(text: stateLabel, tone: Self.tone(for: state)))
        }
        if !meta.isEmpty {
            let metaView = NSTextField(labelWithString: meta)
            metaView.font = .systemFont(ofSize: 12)
            metaView.textColor = Palette.secondary
            metaView.lineBreakMode = .byTruncatingTail
            row.addArrangedSubview(metaView)
        }
        rowsStack.addArrangedSubview(row)
    }

    private func addReviewRow(_ rv: AppStoreReviews) {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "star", accessibilityDescription: "評価")
        iconView.contentTintColor = Palette.secondary
        iconView.symbolConfiguration = .init(pointSize: 11, weight: .regular)

        let labelView = NSTextField(labelWithString: "評価")
        labelView.font = .systemFont(ofSize: 11)
        labelView.textColor = Palette.secondary

        let totalText = "総 \(rv.total.map(String.init) ?? "?") 件"
        let total = NSTextField(labelWithString: totalText)
        total.font = .systemFont(ofSize: 12)
        total.textColor = Palette.primary

        let row = NSStackView(views: [iconView, labelView, total])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6

        if let avg = rv.avgOfRecent {
            let star = NSTextField(labelWithString: "★ \(String(format: "%.1f", avg))")
            star.font = .systemFont(ofSize: 12, weight: .medium)
            star.textColor = Palette.amber
            row.addArrangedSubview(star)
        }
        rowsStack.addArrangedSubview(row)
    }

    private func makeBadge(text: String, tone: Tone) -> NSView {
        let color = Self.color(for: tone)
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 9
        pill.layer?.masksToBounds = true
        pill.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = color.withAlphaComponent(0.5).cgColor
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false

        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -2),
            pill.heightAnchor.constraint(equalToConstant: 18)
        ])
        return pill
    }

    private func addWrappedLabel(_ text: String, color: NSColor) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = color
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.addArrangedSubview(label)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
    }
}

/// 上から下へ並べるための反転ドキュメントビュー（スクロール内容用）。
private final class FlippedDocView: NSView {
    override var isFlipped: Bool { true }
}
