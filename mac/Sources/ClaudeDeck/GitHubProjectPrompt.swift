import AppKit

/// プロジェクトに GitHub Project（owner/number）を紐づける入力ダイアログ。
enum GitHubProjectPrompt {
    /// ダイアログを出して保存する。一覧を書き換えたら true。
    @discardableResult
    static func run(for p: ManagedProject) -> Bool {
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

        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty {
            ProjectStore.setGitHub(path: p.path, owner: nil, number: nil)   // 解除
            return true
        }
        let ownerFallback = GitHubBoard.gitRemoteOwner(forPath: p.path)
        if let ref = GitHubBoard.parseProjectRef(input, ownerFallback: ownerFallback) {
            ProjectStore.setGitHub(path: p.path, owner: ref.owner, number: ref.number)
            return true
        }
        NSSound.beep()
        let err = NSAlert()
        err.messageText = "入力を認識できませんでした"
        err.informativeText = "Project の URL、または owner/番号 の形式で入力してください。"
        err.runModal()
        return false
    }
}
