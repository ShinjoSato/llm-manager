import AppKit
import SwiftTerm

/// 1ペイン = 1プロジェクト。Claude Code（端末）と GitHub Project（ボード）を切り替えて表示する。
/// GitHub ボードのマッピングが無いプロジェクトでは切替を出さず、Claude Code のみ表示する。
final class TerminalPaneViewController: NSViewController, LocalProcessTerminalViewDelegate {

    enum EndReason {
        case limitReached
        case exited(Int32?)
    }

    let project: ManagedProject
    var onSessionEnded: ((EndReason) -> Void)?
    var onClose: (() -> Void)?

    private var terminal: ClaudeTerminalView!
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusBadge = NSTextField(labelWithString: "")
    private let statusPill = NSView()        // ステータスバッジを包むピル状コンテナ
    private var lastStatus: ClaudeStatus?
    private var ended = false
    private var started = false

    // GitHub ボード（マッピングがあるときだけ生成）
    private let boardMapping: BoardMapping?
    private var boardView: GitHubBoardView?
    private let contentContainer = NSView()
    private var claudeButton: NSButton?
    private var githubButton: NSButton?

    // Xcode プロジェクト（プロジェクト直下に見つかったときだけ「Xcodeで開く」ボタンを出す）
    private let xcodeProjectURL: URL?

    init(project: ManagedProject) {
        self.project = project
        self.boardMapping = GitHubBoard.mapping(forProject: project)
        self.xcodeProjectURL = Self.findXcodeProject(in: project.path)
        super.init(nibName: nil, bundle: nil)
        self.title = project.name
    }

    /// プロジェクト配下（浅い範囲）から Xcode プロジェクトを探す。
    /// iOS リポジトリは `ios/` 等のサブディレクトリに `.xcodeproj` を置くことが多いので直下だけでは足りない。
    /// 最も浅い階層のものを選び、同階層なら `.xcworkspace`（CocoaPods/SPM）を `.xcodeproj` より優先する。
    /// 見つからなければ nil（SPM のみ等。ボタンを出さない）。
    private static func findXcodeProject(in directory: String) -> URL? {
        let fm = FileManager.default
        // 探索しても無駄／誤検出のもと（バンドル内含む）になるディレクトリは除外する。
        let skip: Set<String> = [".git", "Pods", "node_modules", ".build", "DerivedData", "build", ".swiftpm"]
        let maxDepth = 3
        var candidates: [(url: URL, depth: Int, isWorkspace: Bool)] = []
        var queue: [(URL, Int)] = [(URL(fileURLWithPath: directory, isDirectory: true), 0)]
        var i = 0
        while i < queue.count {
            let (dir, depth) = queue[i]; i += 1
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for e in entries {
                switch e.pathExtension {
                case "xcworkspace": candidates.append((e, depth, true)); continue
                case "xcodeproj":   candidates.append((e, depth, false)); continue
                default: break
                }
                // `.xcodeproj`/`.xcworkspace` バンドルの中（埋め込み project.xcworkspace 等）には潜らない。
                let name = e.lastPathComponent
                if skip.contains(name) || name.hasPrefix(".") { continue }
                if depth < maxDepth,
                   (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    queue.append((e, depth + 1))
                }
            }
        }
        return candidates.sorted {
            $0.depth != $1.depth ? $0.depth < $1.depth : ($0.isWorkspace && !$1.isWorkspace)
        }.first?.url
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        root.wantsLayer = true
        // ダーク基調のコマンドセンター風。外枠は角丸＋控えめなボーダー。
        root.layer?.cornerRadius = 8
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor

        // 見出しバー
        titleLabel.stringValue = project.name
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.textColor = .labelColor
        titleLabel.toolTip = project.path

        // 作業ステータスのバッジ（ピル化）。NSTextField 単体ではパディングが付けにくいため
        // 小さな角丸コンテナ(statusPill)に入れて、背景色を状態色に連動させる。
        statusBadge.font = .systemFont(ofSize: 11, weight: .semibold)
        statusBadge.setContentHuggingPriority(.required, for: .horizontal)
        statusBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 9
        statusPill.layer?.masksToBounds = true
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        statusPill.setContentHuggingPriority(.required, for: .horizontal)
        statusPill.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusPill.addSubview(statusBadge)
        NSLayoutConstraint.activate([
            statusBadge.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor, constant: 8),
            statusBadge.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor, constant: -8),
            statusBadge.topAnchor.constraint(equalTo: statusPill.topAnchor, constant: 2),
            statusBadge.bottomAnchor.constraint(equalTo: statusPill.bottomAnchor, constant: -2),
            statusPill.heightAnchor.constraint(equalToConstant: 18)
        ])
        updateStatusBadge(.idle)

        let closeButton = makeHeaderButton(
            symbol: "xmark", tooltip: "このペインを閉じる", action: #selector(closeTapped))

        var headerViews: [NSView] = [titleLabel, statusPill, NSView()]
        if boardMapping != nil {
            // テキストセグメントの代わりに円形アイコンの2トグルで切替（横幅をコンパクトに）
            let claude = makeCircleToggle(
                symbol: "terminal", tooltip: "Claude Code", action: #selector(showClaudeTapped))
            let github = makeCircleToggle(
                symbol: "checklist", tooltip: "GitHub Project", action: #selector(showGitHubTapped))
            claudeButton = claude
            githubButton = github
            headerViews.append(claude)
            headerViews.append(github)
            updateToggleSelection(showingBoard: false)
        }
        if xcodeProjectURL != nil {
            let xcodeButton = NSButton(
                image: NSImage(systemSymbolName: "hammer", accessibilityDescription: "Xcodeで開く") ?? NSImage(),
                target: self, action: #selector(openInXcodeTapped))
            xcodeButton.isBordered = false
            xcodeButton.bezelStyle = .regularSquare
            xcodeButton.toolTip = "Xcodeで開く（\(xcodeProjectURL?.lastPathComponent ?? "")）"
            headerViews.append(xcodeButton)
        }
        headerViews.append(closeButton)

        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        header.wantsLayer = true
        // ダーク基調のマテリアル背景＋下端のサブトルな区切り線。
        let headerBG = NSVisualEffectView()
        headerBG.material = .headerView
        headerBG.blendingMode = .withinWindow
        headerBG.state = .active
        headerBG.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerBG, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            headerBG.topAnchor.constraint(equalTo: header.topAnchor),
            headerBG.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerBG.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerBG.bottomAnchor.constraint(equalTo: header.bottomAnchor)
        ])
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1)
        ])

        // 端末
        let term = ClaudeTerminalView(frame: .zero)
        term.processDelegate = self
        term.onLimitReached = { [weak self] in self?.handleLimitReached() }
        term.onStatusChanged = { [weak self] in self?.updateStatusBadge($0) }
        term.translatesAutoresizingMaskIntoConstraints = false
        self.terminal = term

        // コンテンツ領域（端末 / ボードを重ねて切替）
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(term)
        NSLayoutConstraint.activate([
            term.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            term.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            term.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])

        let stack = NSStackView(views: [header, contentContainer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            header.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
        self.view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startIfNeeded()
    }

    /// claude を一度だけ起動する。
    func startIfNeeded() {
        guard !started else { return }
        started = true
        terminal.launchClaude(in: project.path)
    }

    func focusTerminal() {
        view.window?.makeFirstResponder(terminal)
    }

    // MARK: - 表示切替

    /// 円形アイコンのトグルボタンを生成する。
    private func makeCircleToggle(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        let button = HoverButton(image: image ?? NSImage(), target: self, action: action)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.toolTip = tooltip
        button.wantsLayer = true
        button.translatesAutoresizingMaskIntoConstraints = false
        let diameter: CGFloat = 24
        button.layer?.cornerRadius = diameter / 2
        button.layer?.masksToBounds = true
        // 選択中はホバーで色を変えない（塗りつぶし優先）。updateToggleSelection が切替を握る。
        button.hoverEnabled = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: diameter),
            button.heightAnchor.constraint(equalToConstant: diameter)
        ])
        return button
    }

    /// Xcode・閉じる等の単機能アイコンボタンを生成する（ホバーで薄いハイライト）。
    private func makeHeaderButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        let button = HoverButton(image: image ?? NSImage(), target: self, action: action)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.toolTip = tooltip
        button.wantsLayer = true
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        let diameter: CGFloat = 24
        button.layer?.cornerRadius = 6
        button.layer?.masksToBounds = true
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: diameter),
            button.heightAnchor.constraint(equalToConstant: diameter)
        ])
        return button
    }

    /// 選択中のトグルだけを塗りつぶし表示にする。
    /// 非選択側はホバーで薄いハイライトが出るよう hoverEnabled を切り替える。
    private func updateToggleSelection(showingBoard: Bool) {
        let on = NSColor.controlAccentColor.cgColor
        let off = NSColor.clear.cgColor
        claudeButton?.layer?.backgroundColor = showingBoard ? off : on
        githubButton?.layer?.backgroundColor = showingBoard ? on : off
        claudeButton?.contentTintColor = showingBoard ? .secondaryLabelColor : .white
        githubButton?.contentTintColor = showingBoard ? .white : .secondaryLabelColor
        (claudeButton as? HoverButton)?.hoverEnabled = showingBoard
        (githubButton as? HoverButton)?.hoverEnabled = !showingBoard
    }

    @objc private func showClaudeTapped() { showTerminal() }
    @objc private func showGitHubTapped() { showBoard() }

    private func showTerminal() {
        boardView?.isHidden = true
        terminal.isHidden = false
        updateToggleSelection(showingBoard: false)
        focusTerminal()
    }

    private func showBoard() {
        guard let mapping = boardMapping else { return }
        if boardView == nil {
            let bv = GitHubBoardView(mapping: mapping)   // 初回に gh で取得
            bv.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(bv)
            NSLayoutConstraint.activate([
                bv.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                bv.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                bv.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                bv.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
            ])
            boardView = bv
        }
        terminal.isHidden = true
        boardView?.isHidden = false
        updateToggleSelection(showingBoard: true)
    }

    // MARK: - ステータスバッジ

    /// ステータスに応じてバッジの文言・色を更新する。
    /// 終了・上限到達後（ended）は端末由来の状態通知を無視する。
    private func updateStatusBadge(_ status: ClaudeStatus) {
        guard !ended else { return }
        let text: String
        let color: NSColor
        switch status {
        case .working:
            text = "● 作業中"; color = .systemGreen
        case .waitingInput:
            text = "● 入力待ち"; color = .systemOrange
        case .idle:
            // 直前が作業中なら「完了」、それ以外は「待機中」。
            if lastStatus == .working {
                text = "● 完了"; color = .systemBlue
            } else {
                text = "● 待機中"; color = .secondaryLabelColor
            }
        }
        lastStatus = status
        applyBadge(text: text, color: color)
    }

    /// 終了系の固定バッジを表示し、以降のステータス更新を止める。
    private func setTerminalBadge(_ text: String, color: NSColor) {
        ended = true
        terminal.stopStatusMonitoring()
        applyBadge(text: text, color: color)
    }

    /// バッジの文字色とピル背景色（状態色を薄く敷く）をまとめて更新する。
    private func applyBadge(text: String, color: NSColor) {
        statusBadge.stringValue = text
        statusBadge.textColor = color
        statusBadge.toolTip = text
        statusPill.toolTip = text
        statusPill.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
    }

    // MARK: - 終了処理

    private func handleLimitReached() {
        setTerminalBadge("⛔ 上限到達", color: .systemRed)   // ended=true（後続の processTerminated を抑止）
        terminal.terminate()
        let alert = NSAlert()
        alert.messageText = "Max 枠の上限に達しました"
        alert.informativeText = "「\(project.name)」のセッションを強制終了しました。枠がリセットされるまでお待ちください。（API 課金は発生しません）"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        onSessionEnded?(.limitReached)
    }

    /// プロジェクトの `.xcworkspace` / `.xcodeproj` を Xcode の GUI で開く。
    /// 実行（Cmd+R）はユーザーが Xcode 側で行う。
    @objc private func openInXcodeTapped() {
        guard let url = xcodeProjectURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func closeTapped() {
        terminal.stopStatusMonitoring()
        terminal.terminate()
        onClose?()
    }

    // MARK: - LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !ended else { return }   // 上限到達などで既に終了表示済みなら上書きしない
        setTerminalBadge("● 終了", color: .secondaryLabelColor)
        onSessionEnded?(.exited(exitCode))
    }
}

/// ホバーで薄いハイライト背景を出すアイコンボタン。
/// `hoverEnabled` が false の間はハイライトしない（選択中トグルなど塗りつぶし優先のとき用）。
final class HoverButton: NSButton {
    var hoverEnabled: Bool = true {
        didSet { if !hoverEnabled { setHover(false) } }
    }
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if hoverEnabled { setHover(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if hoverEnabled { setHover(false) }
    }

    private func setHover(_ on: Bool) {
        layer?.backgroundColor = on
            ? NSColor.labelColor.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
    }
}
