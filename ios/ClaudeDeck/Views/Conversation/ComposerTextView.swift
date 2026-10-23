import SwiftUI
import UIKit

/// 入力欄の本文。ハードウェアキーボードの ⏎ を、IME が受け取る前に変換中かどうかを見てから送信に使う。
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    let onSubmit: () -> Void

    static let font = UIFont.systemFont(ofSize: 15)
    static let maxLines: CGFloat = 6
    static let verticalInset: CGFloat = 9

    func makeUIView(context: Context) -> SubmitTextView {
        let view = SubmitTextView()
        view.font = Self.font
        view.textColor = UIColor(DeckTheme.text)
        view.tintColor = UIColor(DeckTheme.accent)
        view.backgroundColor = .clear
        view.keyboardAppearance = .dark
        view.textContainerInset = UIEdgeInsets(top: Self.verticalInset, left: 0, bottom: Self.verticalInset, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "composer"
        view.placeholderLabel.font = Self.font
        view.placeholderLabel.textColor = UIColor(DeckTheme.tertiary)
        return view
    }

    func updateUIView(_ view: SubmitTextView, context: Context) {
        context.coordinator.parent = self
        // 変換中に書き戻すと IME の途中の文字が消えるので、確定している時だけ合わせる。
        if view.text != text, view.markedTextRange == nil { view.text = text }
        view.isEditable = isEnabled
        if !isEnabled, view.isFirstResponder { view.resignFirstResponder() }
        view.placeholderLabel.text = placeholder
        view.accessibilityLabel = placeholder
        view.updatePlaceholder()
        view.onSubmit = onSubmit
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SubmitTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let maxHeight = (Self.font.lineHeight * Self.maxLines + Self.verticalInset * 2).rounded(.up)
        return CGSize(width: width, height: min(fitting, maxHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView

        init(parent: ComposerTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? SubmitTextView)?.updatePlaceholder()
            // 行が増減したら高さを測り直させる。
            textView.invalidateIntrinsicContentSize()
        }
    }
}

/// ⏎ の扱い。ソフトウェアキーボードの改行は pressesBegan を通らないので、ここで決めるのはハードウェアキーボードだけ。
enum ComposerKey {
    static func submits(keyCode: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags, composing: Bool) -> Bool {
        guard keyCode == .keyboardReturnOrEnter || keyCode == .keypadEnter else { return false }
        // 変換中の ⏎ は確定、⇧⏎ / ⌥⏎ は改行に使う。
        return !composing && modifiers.isDisjoint(with: [.shift, .alternate, .command, .control])
    }
}

final class SubmitTextView: UITextView {
    var onSubmit: (() -> Void)?
    let placeholderLabel = UILabel()
    private var swallowed: Set<UIKeyboardHIDUsage> = []

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.isAccessibilityElement = false
        placeholderLabel.numberOfLines = 1
        addSubview(placeholderLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = textContainerInset
        placeholderLabel.frame = CGRect(x: inset.left, y: inset.top, width: bounds.width - inset.left - inset.right,
                                        height: placeholderLabel.font.lineHeight)
    }

    func updatePlaceholder() {
        placeholderLabel.isHidden = !text.isEmpty || markedTextRange != nil
    }

    // 変換中かどうかは IME がこのキーを受け取る（super を呼ぶ）前に見る。
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.count == 1, let key = presses.first?.key,
           ComposerKey.submits(keyCode: key.keyCode, modifiers: key.modifierFlags, composing: markedTextRange != nil) {
            swallowed.insert(key.keyCode)
            if isEditable { onSubmit?() }
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = release(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = release(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    /// 送信に使ったキーの離しは IME に渡さない（押しを渡していないため）。
    private func release(_ presses: Set<UIPress>) -> Set<UIPress> {
        presses.filter { press in
            guard let code = press.key?.keyCode, swallowed.contains(code) else { return true }
            swallowed.remove(code)
            return false
        }
    }
}
