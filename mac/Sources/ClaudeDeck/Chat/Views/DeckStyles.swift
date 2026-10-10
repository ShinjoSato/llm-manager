import SwiftUI

/// 画面のあちこちで繰り返す面・枠・帯の組み合わせ。
extension View {
    /// 角丸の面と、同じ形の枠線。
    func roundedSurface(_ radius: CGFloat, fill: some ShapeStyle, stroke: some ShapeStyle, lineWidth: CGFloat = 1) -> some View {
        background(RoundedRectangle(cornerRadius: radius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(stroke, lineWidth: lineWidth))
    }

    /// 入力欄と同じ地と枠（検索欄・切り替え・控えめなボタン）。
    func inputFieldSurface(_ radius: CGFloat) -> some View {
        roundedSurface(radius, fill: ChatTheme.inputSurface, stroke: ChatTheme.inputBorder)
    }

    /// 詳細・リンク一覧の節の枠（Claude の吹き出しと同じ地と枠）。
    func detailCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .roundedSurface(12, fill: ChatTheme.claudeBubble, stroke: ChatTheme.claudeBubbleBorder)
    }

    /// 中央の見出しの地と下線。下線を背景側に置き、ボタンの吹き出しが線の下に潜らないようにする。
    func headerBackground() -> some View {
        background {
            ChatTheme.background.overlay(alignment: .bottom) { Rectangle().fill(ChatTheme.border).frame(height: 1) }
        }
    }

    /// 節の見出しの小さな文字（詳細の節・一覧の段）。
    func sectionLabelStyle() -> some View {
        font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ChatTheme.tertiary)
    }

    /// 状態を色の地の小さなカプセルで出す（会話の見出しの状態・プロジェクトの状態）。
    func statusCapsule(_ color: Color) -> some View {
        font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    /// 一覧の上に出す帯（監視・フック・再開・終了待ちの知らせ）。
    func listNoticeBand() -> some View {
        font(ChatTheme.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
    }
}

/// 中央・パネルの空きに出す案内（アイコンと一文）。
struct CenterPlaceholder: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(ChatTheme.tertiary)
            Text(text)
                .font(ChatTheme.body)
                .foregroundStyle(ChatTheme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 畳める見出しの向きの印（開いていれば下、畳んでいれば右）。
struct DisclosureChevron: View {
    let collapsed: Bool

    var body: some View {
        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(ChatTheme.tertiary)
            .frame(width: 10)
    }
}

/// 詳細の節の見出し（名前と、分かっていれば件数）。
struct SectionTitle: View {
    let name: String
    var count: Int? = nil

    var body: some View {
        Text(count.map { "\(name)  \($0)" } ?? name)
            .sectionLabelStyle()
    }
}

/// 節の中の控えめな案内（空・打ち切りの知らせ）。
struct SectionNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(ChatTheme.caption)
            .foregroundStyle(ChatTheme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// グリッドの 1 枠（縦横比を保った入力欄の地と角丸の枠線）。
struct GridTile<Content: View>: View {
    let aspectRatio: CGFloat
    let content: Content

    init(aspectRatio: CGFloat = 1, @ViewBuilder content: () -> Content) {
        self.aspectRatio = aspectRatio
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(shape.fill(ChatTheme.inputSurface))
            .overlay { content }
            .clipShape(shape)
            .overlay(shape.stroke(ChatTheme.border))
            .contentShape(shape)
    }
}
