import SwiftUI
import MonitorKit

struct EntryView: View {
    let entry: ChatEntry
    let runningToolId: String?
    let imageSource: ChatImageSource

    var body: some View {
        let trailing = entry.role == .user || entry.role == .relay || entry.role == .outgoing
        VStack(alignment: trailing ? .trailing : .leading, spacing: 6) {
            switch entry.role {
            case .user:
                HStack {
                    Spacer(minLength: 96)
                    UserBubble(text: entry.text, images: entry.images, imageSource: imageSource)
                }
            case .outgoing:
                HStack {
                    Spacer(minLength: 96)
                    UserBubble(text: entry.text, images: entry.images, imageSource: imageSource, pending: true)
                }
            case .assistant:
                HStack {
                    ClaudeBubble(text: entry.text, images: entry.images, imageSource: imageSource)
                    Spacer(minLength: 96)
                }
            case .relay:
                HStack {
                    Spacer(minLength: 96)
                    RelayBubble(text: entry.text, state: entry.relay?.state ?? .sent, images: entry.images, imageSource: imageSource)
                }
            case .toolsOnly:
                EmptyView()
            }
            if !entry.tools.isEmpty {
                ToolsRow(tools: entry.tools, runningToolId: runningToolId)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
}

struct UserBubble: View {
    let text: String
    var images: [ChatImage] = []
    var imageSource: ChatImageSource?
    /// 画像を添えて送り、まだ transcript に記録されていない発話。
    var pending = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty, let imageSource {
                ChatImageGrid(images: images, source: imageSource)
            }
            if !text.isEmpty {
                Text(ChatMarkdown.inline(text))
                    .font(ChatTheme.body)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16,
                                                       bottomTrailingRadius: 4, topTrailingRadius: 16)
                        .fill(ChatTheme.userBubble))
            }
            if pending {
                Text("送信しました（記録を待っています）").font(.system(size: 11)).foregroundStyle(ChatTheme.tertiary)
            }
        }
        .opacity(pending ? 0.75 : 1)
    }
}

struct ClaudeBubble: View {
    let text: String
    var images: [ChatImage] = []
    var imageSource: ChatImageSource?

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 4,
                                           bottomTrailingRadius: 16, topTrailingRadius: 16)
        VStack(alignment: .leading, spacing: 6) {
            if !images.isEmpty, let imageSource {
                ChatImageGrid(images: images, source: imageSource)
            }
            if !text.isEmpty {
                MarkdownView(text: text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(shape.fill(ChatTheme.claudeBubble))
                .overlay(shape.stroke(ChatTheme.claudeBubbleBorder))
            }
        }
    }
}
