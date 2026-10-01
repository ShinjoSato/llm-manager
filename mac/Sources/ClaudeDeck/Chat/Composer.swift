import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MonitorKit

/// 入力欄。⏎ 送信・⇧⏎ 改行。`disabledReason` があれば送れない理由を出して無効にする。
struct Composer: View {
    @Binding var text: String
    let disabledReason: String?
    /// 書けるが今は送れない理由（送信中・添付の読み込み中）。
    var sendBlockedReason: String?
    /// 外部セッション向けの「伝言」モード。本人の入力ではなく別セッションからのメッセージとして届く。
    var relay = false
    /// 送る前の添付（入力欄の上にチップで出す）。
    var attachments: [Attachment] = []
    /// 取り込み中の添付の数（「読み込み中」のチップを出す）。
    var importingCount = 0
    var thumbnail: (Attachment) -> NSImage? = { _ in nil }
    var onAttach: ([AttachmentSource]) -> Void = { _ in }
    var onRemoveAttachment: (Attachment) -> Void = { _ in }
    /// 送れたら true（入力欄を空にする）。
    let onSend: (String) -> Bool
    @State private var height: CGFloat = 20
    @State private var dropTargeted = false

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
                    if let reason = disabledReason ?? sendBlockedReason, hasContent {
                        Text(reason).font(ChatTheme.caption).foregroundStyle(ChatTheme.permission)
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
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty || importingCount > 0 {
                AttachmentStrip(attachments: attachments, importingCount: importingCount, thumbnail: thumbnail, onRemove: onRemoveAttachment)
                    .padding(.top, 4)
                    .padding(.trailing, 6)
            }
            inputRow(enabled: enabled)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14).fill(ChatTheme.inputSurface))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(dropTargeted ? ChatTheme.accent : (relay ? ChatTheme.permission.opacity(0.6) : ChatTheme.inputBorder),
                    style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: relay && !dropTargeted ? [5, 4] : [])))
        .opacity(enabled ? 1 : 0.7)
        .overlay(alignment: .topLeading) {
            // 書きかけがあると欄内の案内が隠れるので、無効の理由を欄の上にも出す（伝言モードは見出し行に出す）。
            if !relay, let reason = disabledReason ?? sendBlockedReason, hasContent {
                Text(reason)
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.permission)
                    .offset(x: 4, y: -18)
            }
        }
        .onDrop(of: AttachmentDrop.types, isTargeted: $dropTargeted) { providers in
            guard enabled else { return false }
            return AttachmentDrop.load(providers) { onAttach($0) }
        }
    }

    private func inputRow(enabled: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button(action: chooseFiles) {
                Image(systemName: "paperclip")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ChatTheme.secondary)
                    .frame(width: 26, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .help("画像・ファイルを添付（⌘V で画像の貼り付け・ドラッグ＆ドロップも可）")
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(disabledReason ?? placeholder)
                        .font(ChatTheme.body)
                        .foregroundStyle(ChatTheme.tertiary)
                        .allowsHitTesting(false)
                }
                ComposerTextView(text: $text, height: $height, isEnabled: enabled, onSubmit: submit, onAttach: onAttach)
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
    }

    private var placeholder: String {
        relay ? "伝言を送信（⏎ 送信 / ⇧⏎ 改行）" : "メッセージを送信（⏎ 送信 / ⇧⏎ 改行）"
    }

    private var hasContent: Bool { !text.isEmpty || !attachments.isEmpty || importingCount > 0 }

    private var canSend: Bool {
        disabledReason == nil && sendBlockedReason == nil
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func submit() {
        // 変換中の文字は `text` に入っていないので、送ると確定前の部分を落としたうえで欄を空にしてしまう。
        if let field = NSApp.keyWindow?.firstResponder as? SubmitTextView, field.hasMarkedText() { return }
        guard canSend else { return }
        if onSend(text) { text = "" }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添付"
        panel.message = "添付する画像・ファイルを選んでください"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        onAttach(panel.urls.map { .file($0) })
    }
}

/// 入力欄の上に並べる添付のチップ。
struct AttachmentStrip: View {
    let attachments: [Attachment]
    var importingCount = 0
    let thumbnail: (Attachment) -> NSImage?
    let onRemove: (Attachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    chip(attachment)
                }
                if importingCount > 0 { loadingChip }
            }
        }
    }

    private var loadingChip: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 32, height: 32)
            Text(importingCount > 1 ? "読み込み中…（\(importingCount) 件）" : "読み込み中…")
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.secondary)
        }
        .padding(4)
        .padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(ChatTheme.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.inputBorder))
    }

    private func chip(_ attachment: Attachment) -> some View {
        HStack(spacing: 6) {
            Group {
                if let image = thumbnail(attachment) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: attachment.kind == .image ? "photo" : "doc")
                        .font(.system(size: 14))
                        .foregroundStyle(ChatTheme.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(attachment.name)
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
            Button { onRemove(attachment) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ChatTheme.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(ChatTheme.selectedRow))
            }
            .buttonStyle(.plain)
            .help("添付を外す")
        }
        .padding(4)
        .padding(.trailing, 2)
        .background(RoundedRectangle(cornerRadius: 9).fill(ChatTheme.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.inputBorder))
        .help(attachment.path)
    }
}

/// SwiftUI のドロップ（入力欄の枠全体）から添付を拾う。
enum AttachmentDrop {
    /// ファイルと、画像のデータ表現（JPEG / HEIC / TIFF 等。ブラウザや写真からのドラッグ）。ファイルプロミスは受けない。
    static let types: [UTType] = [.fileURL, .image]

    /// 読み込みは非同期なので、揃ったらメインで `completion` に渡す。受け取れるものが無ければ false。
    /// 画像のデータは元の形式のまま渡し、変換は取り込み（バックグラウンド）に任せる。
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([AttachmentSource]) -> Void) -> Bool {
        let usable = providers.filter { provider in types.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) } }
        guard !usable.isEmpty else { return false }
        let collector = DropCollector(count: usable.count)
        for (index, provider) in usable.enumerated() {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    collector.set(index, url.map { .file($0) }, completion: completion)
                }
            } else if let type = imageType(of: provider) {
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    collector.set(index, data.map { .imageData($0, name: "ドロップした画像") }, completion: completion)
                }
            } else {
                collector.set(index, nil, completion: completion)
            }
        }
        return true
    }

    /// 載っている画像の型。PNG を優先し、無ければ最初の画像の型。
    private static func imageType(of provider: NSItemProvider) -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) { return UTType.png.identifier }
        return provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
    }
}

/// ドロップの各項目の読み込み結果を並び順のまま集める。
private final class DropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [AttachmentSource?]
    private var remaining: Int

    init(count: Int) {
        results = Array(repeating: nil, count: count)
        remaining = count
    }

    func set(_ index: Int, _ source: AttachmentSource?, completion: @escaping @MainActor ([AttachmentSource]) -> Void) {
        lock.lock()
        results[index] = source
        remaining -= 1
        let done = remaining == 0 ? results.compactMap { $0 } : nil
        lock.unlock()
        guard let done, !done.isEmpty else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(done) } }
    }
}

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

final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onAttach: (([AttachmentSource]) -> Void)?

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL] + AttachmentPasteboard.imageTypes
    }

    /// ⌘V: ファイルや画像だけのクリップボードは添付にし、文字を含むものは従来どおり文字として貼る。
    override func paste(_ sender: Any?) {
        if isEditable, attach(from: .general) { return }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isEditable, AttachmentPasteboard.canAttach(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isEditable, AttachmentPasteboard.canAttach(sender.draggingPasteboard) { return .copy }
        return super.draggingUpdated(sender)
    }

    /// 文字欄に落としたファイルもパスの文字ではなく添付にする。
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isEditable, attach(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    private func attach(from pasteboard: NSPasteboard) -> Bool {
        let sources = AttachmentPasteboard.sources(in: pasteboard)
        guard !sources.isEmpty, let onAttach else { return false }
        onAttach(sources)
        return true
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
