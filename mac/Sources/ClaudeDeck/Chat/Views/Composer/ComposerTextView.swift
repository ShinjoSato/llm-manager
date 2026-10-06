import SwiftUI
import AppKit
import MonitorKit

/// NSTextView で Return を横取りする（SwiftUI の TextEditor では ⇧⏎ と ⏎ を分けられないため）。
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let isEnabled: Bool
    let onSubmit: () -> Void
    var onAttach: ([AttachmentSource]) -> Void = { _ in }

    static let maxHeight: CGFloat = 160

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FocusingScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = SubmitTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = ChatTheme.nsText
        textView.insertionPointColor = ChatTheme.nsText
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // 指示文やコードを書き換えないため自動置換は切る。
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.onSubmit = { context.coordinator.parent.onSubmit() }
        textView.onAttach = { context.coordinator.parent.onAttach($0) }
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? SubmitTextView else { return }
        // 変換中の文字は下書きに入っていないので、再描画のたびに書き戻すと消える。本当の外部変更（送信後の空など）だけ反映する。
        if context.coordinator.sync.shouldApply(external: text, shown: textView.string) {
            if textView.hasMarkedText() { textView.inputContext?.discardMarkedText() }
            textView.string = text
            context.coordinator.recalculateHeight(textView)
        }
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        // 空でも欄全体をクリックで拾えるよう、高さを表示域に合わせておく。
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var sync = ComposerSync()

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            sync.published(textView.string)
            if parent.text != textView.string { parent.text = textView.string }
            recalculateHeight(textView)
        }

        func recalculateHeight(_ textView: NSTextView) {
            guard let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height
            let lineHeight = layout.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 14))
            let target = min(ComposerTextView.maxHeight, max(lineHeight, ceil(used)))
            if abs(parent.height - target) > 0.5 {
                DispatchQueue.main.async { self.parent.height = target }
            }
        }
    }
}

/// 入力欄の余白をクリックしても文字入力に入れるようにする。
final class FocusingScrollView: NSScrollView {
    override func mouseDown(with event: NSEvent) {
        if let textView = documentView as? NSTextView, textView.isEditable {
            window?.makeFirstResponder(textView)
        }
        super.mouseDown(with: event)
    }
}

final class SubmitTextView: AttachmentPasteTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        // 変換中（日本語入力の確定前）の Return は IME に渡す。
        if isReturn, !hasMarkedText() {
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit?()
            }
            return
        }
        super.keyDown(with: event)
    }
}
