import SwiftUI
import MonitorKit

/// 吹き出しの別ウィンドウの中身: 開いた時点の本文を会話と同じ Markdown で描き、縦にスクロールして読む。
struct BubbleWindowView: View {
    let snapshot: BubbleSnapshot
    /// 開いた時に決めた時刻の表記（タイトルと揃える）。
    let time: String
    /// 見本の描画で外観を固定する時だけ渡す（既定は設定のテーマに追従）。
    var theme: DeckTheme? = nil

    var body: some View {
        VStack(spacing: 0) {
            // コピーのボタンの吹き出しを本文の上に重ねるため、見出しを前に出す。
            header.zIndex(1)
            ScrollView {
                MarkdownView(text: snapshot.text)
                    .textSelection(.enabled)
                    .environment(\.chatTypeScale, .reply)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
        .background(ChatTheme.background)
        .environment(\.colorScheme, ChatTheme.colorScheme(for: theme ?? AppearanceSettings.shared.theme))
        // 本文は外部由来なので、会話と同じく http / https 以外のリンクは開かない。
        .environment(\.openURL, OpenURLAction { url in
            ChatMarkdown.isOpenableLink(url) ? .systemAction : .discarded
        })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left").font(.system(size: 11)).foregroundStyle(ChatTheme.tertiary)
            Text(snapshot.roomName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ChatTheme.heading)
                .lineLimit(1)
                .truncationMode(.middle)
            if !time.isEmpty {
                Text(time).font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            CopyAllButton(text: snapshot.text)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .headerBackground()
    }
}

/// 本文全体（Markdown の原文）をクリップボードに写す。写した直後は印をチェックに替えて知らせる。
private struct CopyAllButton: View {
    let text: String
    @State private var hovering = false
    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button {
            SystemActions.copy(text)
            copied = true
            reset?.cancel()
            reset = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            HeaderButtonLabel(symbol: copied ? "checkmark" : "doc.on.doc", busy: false, hovering: hovering)
        }
        .buttonStyle(.plain)
        .modifier(HeaderTooltipModifier(name: "全文をコピー", details: ["Markdown の原文をクリップボードに写す"]))
        .accessibilityLabel("全文をコピー")
        .accessibilityValue(copied ? "コピーしました" : "")
        .trackHover($hovering)
        .onDisappear { reset?.cancel() }
    }
}
