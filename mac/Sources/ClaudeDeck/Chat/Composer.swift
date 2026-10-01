import SwiftUI
import AppKit
import MonitorKit

/// 入力欄。⏎ 送信・⇧⏎ 改行。`disabledReason` があれば送れない理由を出して無効にする。
struct Composer: View {
    @Binding var text: String
    let disabledReason: String?
    /// 外部セッション向けの「伝言」モード。本人の入力ではなく別セッションからのメッセージとして届く。
    var relay = false
    /// 送れたら true（入力欄を空にする）。
    let onSend: (String) -> Bool
    @State private var height: CGFloat = 20

    var body: some View {
        let enabled = disabledReason == nil
        VStack(alignment: .leading, spacing: 6) {
            if relay {
                HStack(spacing: 6) {
                    Text("伝言")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ChatTheme.background)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(ChatTheme.permission))
                    Text("受け手には別セッションからのメッセージとして届きます")
                        .font(ChatTheme.caption)
                        .foregroundStyle(ChatTheme.secondary)
                    if let disabledReason, !text.isEmpty {
                        Text(disabledReason).font(ChatTheme.caption).foregroundStyle(ChatTheme.permission)
                    }
                }
                .padding(.leading, 4)
            }
            field(enabled: enabled)
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    private func field(enabled: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(disabledReason ?? (relay ? "伝言を送信（⏎ 送信 / ⇧⏎ 改行）" : "メッセージを送信（⏎ 送信 / ⇧⏎ 改行）"))
                        .font(ChatTheme.body)
                        .foregroundStyle(ChatTheme.tertiary)
                        .allowsHitTesting(false)
                }
                ComposerTextView(text: $text, height: $height, isEnabled: enabled, onSubmit: submit)
                    .frame(height: height)
            }
            .padding(.vertical, 6)
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ChatTheme.onAccent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(relay ? ChatTheme.permission : ChatTheme.accent))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.4)
            .help("送信（⏎）")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14).fill(ChatTheme.inputSurface))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(relay ? ChatTheme.permission.opacity(0.6) : ChatTheme.inputBorder,
                    style: StrokeStyle(lineWidth: 1, dash: relay ? [5, 4] : [])))
        .opacity(enabled ? 1 : 0.7)
        .overlay(alignment: .topLeading) {
            // 書きかけがあると欄内の案内が隠れるので、無効の理由を欄の上にも出す（伝言モードは見出し行に出す）。
            if !relay, let disabledReason, !text.isEmpty {
                Text(disabledReason)
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.permission)
                    .offset(x: 4, y: -18)
            }
        }
    }

    private var canSend: Bool {
        disabledReason == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        // 変換中の文字は `text` に入っていないので、送ると確定前の部分を落としたうえで欄を空にしてしまう。
        if let field = NSApp.keyWindow?.firstResponder as? SubmitTextView, field.hasMarkedText() { return }
        guard canSend else { return }
        if onSend(text) { text = "" }
    }
}

/// NSTextView で Return を横取りする（SwiftUI の TextEditor では ⇧⏎ と ⏎ を分けられないため）。
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let isEnabled: Bool
    let onSubmit: () -> Void

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
        textView.textColor = NSColor(hex: 0xe6ebf2)
        textView.insertionPointColor = NSColor(hex: 0xe6ebf2)
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

final class SubmitTextView: NSTextView {
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
