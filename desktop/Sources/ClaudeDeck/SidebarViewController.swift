import AppKit

/// 左サイドバー: ユーザー管理のプロジェクト一覧。
/// - 下部の「+」でフォルダを追加、「−」で選択行を削除、取り込みボタンで registry.tsv を取り込む。
/// - 一覧は `ProjectStore`（JSON）に永続化される。
/// - Claude Code の起動は「ダブルクリック / Enter」のみ（選択だけでは起動しない＝削除操作の邪魔をしない）。
final class SidebarViewController: NSViewController {

    private var projects: [ManagedProject] = []
    private let tableView = KeyTableView()

    /// プロジェクトが「起動」されたとき（ダブルクリック / Enter）に呼ばれる。
    var onSelect: ((ManagedProject) -> Void)?

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let column = NSTableColumn(identifier: .init("project"))
        column.title = "Projects"
        column.width = 220
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.style = .sourceList
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowActivated)
        tableView.onActivate = { [weak self] in self?.rowActivated() }
        tableView.onDelete = { [weak self] in self?.removeSelected() }
        scroll.documentView = tableView

        // 右クリックメニュー
        let menu = NSMenu()
        menu.addItem(withTitle: "GitHub Project を設定…", action: #selector(configureGitHub), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "削除", action: #selector(removeClicked), keyEquivalent: "")
        tableView.menu = menu

        // 下部のボタンバー
        let addButton = makeButton(symbol: "plus", action: #selector(addFolder), tip: "フォルダを追加")
        let removeButton = makeButton(symbol: "minus", action: #selector(removeSelected), tip: "選択を削除")
        let importButton = makeButton(symbol: "square.and.arrow.down", action: #selector(importRegistry), tip: "registry.tsv を取り込む")
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSStackView(views: [addButton, removeButton, spacer, importButton])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 4
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        let container = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),

            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 30)
        ])
        container.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        self.view = container
    }

    private func makeButton(symbol: String, action: Selector, tip: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    func reload() {
        projects = ProjectStore.load().sorted { lhs, rhs in
            if (lhs.status == "active") != (rhs.status == "active") {
                return lhs.status == "active"
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        tableView.reloadData()
    }

    fileprivate func project(at row: Int) -> ManagedProject? {
        guard row >= 0, row < projects.count else { return nil }
        return projects[row]
    }

    // MARK: - アクション

    @objc private func rowActivated() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        if let p = project(at: row) { onSelect?(p) }
    }

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "追加"
        panel.message = "Claude Code を起動するプロジェクトフォルダを選択"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls { ProjectStore.add(path: url.path) }
            self?.reload()
        }
    }

    @objc private func removeSelected() {
        guard let p = project(at: tableView.selectedRow) else { return }
        ProjectStore.remove(path: p.path)
        reload()
    }

    @objc private func removeClicked() {
        guard let p = project(at: tableView.clickedRow) else { return }
        ProjectStore.remove(path: p.path)
        reload()
    }

    @objc private func importRegistry() {
        ProjectStore.importFromRegistry()
        reload()
    }

    @objc private func configureGitHub() {
        guard let p = project(at: tableView.clickedRow) else { return }
        let alert = NSAlert()
        alert.messageText = "GitHub Project を設定"
        alert.informativeText = """
        「\(p.name)」に紐づける GitHub Project を入力してください。
        ・URL 例: https://github.com/users/ShinjoSato/projects/5
        ・owner/番号 例: ShinjoSato/5
        ・番号のみ（owner は git remote から補完）
        空欄で「設定」を押すと解除します。
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        if let o = p.ghOwner, let n = p.ghNumber { field.stringValue = "\(o)/\(n)" }
        alert.accessoryView = field
        alert.addButton(withTitle: "設定")
        alert.addButton(withTitle: "キャンセル")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty {
            ProjectStore.setGitHub(path: p.path, owner: nil, number: nil)   // 解除
            reload()
            return
        }
        let ownerFallback = GitHubBoard.gitRemoteOwner(forPath: p.path)
        if let ref = GitHubBoard.parseProjectRef(input, ownerFallback: ownerFallback) {
            ProjectStore.setGitHub(path: p.path, owner: ref.owner, number: ref.number)
            reload()
        } else {
            NSSound.beep()
            let err = NSAlert()
            err.messageText = "入力を認識できませんでした"
            err.informativeText = "Project の URL、または owner/番号 の形式で入力してください。"
            err.runModal()
        }
    }
}

extension SidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { projects.count }
}

extension SidebarViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let p = project(at: row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ProjectCellView)
            ?? ProjectCellView(identifier: id)
        cell.configure(with: p)
        return cell
    }
}

// MARK: - Delete / Enter を拾うテーブル

private final class KeyTableView: NSTableView {
    var onDelete: (() -> Void)?
    var onActivate: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:           // delete / forward-delete
            onDelete?()
        case 36, 76:            // return / keypad enter
            onActivate?()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - 行セル

private final class ProjectCellView: NSTableCellView {
    private let dot = NSTextField(labelWithString: "●")
    private let nameLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byTruncatingMiddle
        dot.font = .systemFont(ofSize: 9)

        let text = NSStackView(views: [nameLabel, noteLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [dot, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with p: ManagedProject) {
        nameLabel.stringValue = p.name
        // ディレクトリパスを常に表示（長い場合は中央省略・ホバーで全文）
        // GitHub Project が紐づいていれば「· GH #番号」を付与
        if let m = GitHubBoard.mapping(forProject: p) {
            noteLabel.stringValue = "\(p.path)  ·  GH #\(m.number)"
        } else {
            noteLabel.stringValue = p.path
        }
        toolTip = p.path
        switch p.status {
        case "active":   dot.textColor = .systemGreen
        case "paused":   dot.textColor = .systemYellow
        case "archived": dot.textColor = .systemGray
        default:         dot.textColor = .systemGray
        }
    }
}
