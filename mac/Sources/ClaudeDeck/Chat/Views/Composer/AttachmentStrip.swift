import SwiftUI
import AppKit
import MonitorKit

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
        .roundedSurface(9, fill: ChatTheme.background.opacity(0.6), stroke: ChatTheme.inputBorder)
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
        .roundedSurface(9, fill: ChatTheme.background.opacity(0.6), stroke: ChatTheme.inputBorder)
        .help(attachment.path)
    }
}
