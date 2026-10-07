import SwiftUI
import AppKit
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
            .stroke(dropTargeted ? ChatTheme.working : (relay ? ChatTheme.permission.opacity(0.6) : ChatTheme.inputBorder),
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
            // 案内は端末ビューが表示内容で出し分ける（下書きが空のままの変換中に SwiftUI 側では消せない）。
            ComposerTextView(text: $text, height: $height, isEnabled: enabled, placeholder: disabledReason ?? placeholder,
                             onSubmit: submit, onAttach: onAttach)
                .frame(height: height)
                .padding(.vertical, 6)
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(relay ? ChatTheme.onPermission : ChatTheme.onAccent)
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
