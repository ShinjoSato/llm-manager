import SwiftUI
import AppKit
import MonitorKit

/// NSTextView で Return を横取りする（SwiftUI の TextEditor では ⇧⏎ と ⏎ を分けられないため）。
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let isEnabled: Bool
    /// 空欄の案内（送れない理由があればそれ）。
    var placeholder = ""
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
        textView.placeholderColor = ChatTheme.nsTertiary
        textView.placeholder = placeholder
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
        textView.placeholder = placeholder
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
    /// 空欄の案内。下書きではなく表示内容で判定して自前で描くので、変換中（marked text）も重ならない。
    var placeholder = "" {
        didSet {
            guard placeholder != oldValue else { return }
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }
    var placeholderColor: NSColor = .placeholderTextColor {
        didSet { needsDisplay = true }
    }

    override var string: String {
        get { super.string }
        set {
            super.string = newValue
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !placeholder.isEmpty, ComposerPlaceholder.isShown(shown: string, hasMarkedText: hasMarkedText()) else { return }
        let inset = textContainerInset
        let padding = textContainer?.lineFragmentPadding ?? 0
        let rect = NSRect(x: inset.width + padding, y: inset.height,
                          width: max(0, bounds.width - (inset.width + padding) * 2), height: max(0, bounds.height - inset.height))
        // 空欄の高さは 1 行分なので、幅に入りきらない案内は折り返さず末尾を省略する。
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (placeholder as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
            .font: font ?? .systemFont(ofSize: 14), .foregroundColor: placeholderColor, .paragraphStyle: style,
        ])
    }

    // 変換の開始・終了と確定後の変更は textDidChange だけでは拾えないので、ここで描き直しを立てる。
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

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
