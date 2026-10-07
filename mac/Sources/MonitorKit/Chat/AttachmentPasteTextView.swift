import AppKit

/// 添付を受ける文字欄。⌘V・ドロップで、ファイルや画像だけのクリップボードを文字ではなく添付にする。
open class AttachmentPasteTextView: NSTextView {
    public var onAttach: (([AttachmentSource]) -> Void)?
    /// ⌘V で読むペーストボード（テストでは専用のものに差し替える）。
    public var pasteSource: NSPasteboard = .general

    static let pasteActions: Set<Selector> = [
        #selector(NSText.paste(_:)), #selector(NSTextView.pasteAsPlainText(_:)), #selector(NSTextView.pasteAsRichText(_:)),
    ]

    /// 文字用の NSTextView は読める型（文字列・RTF・ファイル名）が無いとペーストを無効にし、⌘V のメニューごと効かなくなる。
    /// 画像だけのクリップボード（スクリーンショット等）でも押せるよう、添付にできる時は有効にする。
    open override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        enablesAttachPaste(item.action) || super.validateUserInterfaceItem(item)
    }

    open override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        enablesAttachPaste(menuItem.action) || super.validateMenuItem(menuItem)
    }

    private func enablesAttachPaste(_ action: Selector?) -> Bool {
        guard let action, Self.pasteActions.contains(action) else { return false }
        return canAttachPaste
    }

    /// 今のクリップボードを添付にできるか（型だけで見る）。
    public var canAttachPaste: Bool {
        isEditable && onAttach != nil && AttachmentPasteboard.canAttach(pasteSource)
    }

    open override func paste(_ sender: Any?) {
        if attachPaste() { return }
        super.paste(sender)
    }

    open override func pasteAsPlainText(_ sender: Any?) {
        if attachPaste() { return }
        super.pasteAsPlainText(sender)
    }

    open override func pasteAsRichText(_ sender: Any?) {
        if attachPaste() { return }
        super.pasteAsRichText(sender)
    }

    /// ファイルや画像だけのクリップボードなら添付にして true。文字を含むものは false（文字として貼る）。
    @discardableResult
    public func attachPaste() -> Bool {
        isEditable && attach(from: pasteSource)
    }

    open override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL] + AttachmentPasteboard.imageTypes
    }

    open override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAttachDrop(sender) ? .copy : super.draggingEntered(sender)
    }

    open override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAttachDrop(sender) ? .copy : super.draggingUpdated(sender)
    }

    private func canAttachDrop(_ sender: NSDraggingInfo) -> Bool {
        isEditable && AttachmentPasteboard.canAttach(sender.draggingPasteboard)
    }

    /// 文字欄に落としたファイルもパスの文字ではなく添付にする。
    open override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isEditable, attach(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    private func attach(from pasteboard: NSPasteboard) -> Bool {
        guard let onAttach else { return false }
        let sources = AttachmentPasteboard.sources(in: pasteboard)
        guard !sources.isEmpty else { return false }
        onAttach(sources)
        return true
    }
}
