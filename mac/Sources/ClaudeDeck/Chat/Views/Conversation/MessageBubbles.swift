import SwiftUI
import MonitorKit

struct EntryView: View {
    let entry: ChatEntry
    let runningToolId: String?
    let imageSource: ChatImageSource
    /// Claude の返答を別ウィンドウで開く（開けない吹き出しでは nil）。
    var openInWindow: (() -> Void)? = nil

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
                    ClaudeBubble(text: entry.text, images: entry.images, imageSource: imageSource, openInWindow: openInWindow)
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

/// 吹き出しの形。話し手の側の下の角だけを小さく丸める。
enum BubbleShape {
    /// 右に寄せる吹き出し（本人の発話・伝言）。
    static let outgoing = UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16,
                                                 bottomTrailingRadius: 4, topTrailingRadius: 16)
    /// 左に寄せる吹き出し（Claude）。
    static let incoming = UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 4,
                                                 bottomTrailingRadius: 16, topTrailingRadius: 16)
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
                    .foregroundStyle(ChatTheme.userBubbleText)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(BubbleShape.outgoing.fill(ChatTheme.userBubble))
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
    var openInWindow: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        let shape = BubbleShape.incoming
        VStack(alignment: .leading, spacing: 6) {
            if !images.isEmpty, let imageSource {
                ChatImageGrid(images: images, source: imageSource)
            }
            if !text.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    MarkdownView(text: text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(shape.fill(ChatTheme.claudeBubble))
                        .overlay(shape.stroke(ChatTheme.claudeBubbleBorder))
                        .contextMenu {
                            if let openInWindow {
                                Button("別ウィンドウで開く", systemImage: BubbleWindowButton.symbol, action: openInWindow)
                            }
                        }
                    if let openInWindow {
                        BubbleWindowButton(visible: hovering, action: openInWindow)
                    }
                }
                .trackHover($hovering)
            }
        }
    }
}

/// 吹き出しの右上の脇に、カーソルを乗せている間だけ出す「別ウィンドウで開く」。場所は常に取っておき、出し入れで本文の幅を揺らさない。
struct BubbleWindowButton: View {
    static let symbol = "macwindow.badge.plus"
    private static let side: CGFloat = 24

    let visible: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: Self.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ChatTheme.text)
                .frame(width: Self.side, height: Self.side)
                .roundedSurface(7, fill: hovering ? ChatTheme.selectedRow : ChatTheme.inputSurface, stroke: ChatTheme.inputBorder)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HeaderTooltipModifier(name: "別ウィンドウで開く", details: [], leadingOffset: Self.side + 6))
        .accessibilityLabel("別ウィンドウで開く")
        .trackHover($hovering)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeOut(duration: 0.12), value: visible)
    }
}
