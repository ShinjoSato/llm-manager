import SwiftUI
import MonitorKit

/// 会話を上へ読み返している間に右下へ出す「最新へ」のボタン。新着があれば数を添える。
struct JumpToLatestButton: View {
    let newCount: Int
    let action: () -> Void
    @State private var hovering = false

    private static let size: CGFloat = 34
    /// 欄の右端からボタンまで（重ね表示のスクロールバーを避ける）。
    static let trailingInset: CGFloat = 14
    /// 会話の列の右に空けておく幅（ボタンと、列との間の 6pt）。
    static let reservedGutter: CGFloat = trailingInset + size + 6

    var body: some View {
        let badge = LatestJump.badge(for: newCount)
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(hovering ? ChatTheme.heading : ChatTheme.text)
                .frame(width: Self.size, height: Self.size)
                .background(Circle().fill(ChatTheme.claudeBubble))
                .overlay(Circle().stroke(ChatTheme.claudeBubbleBorder, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(ChatTheme.onAccent)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(ChatTheme.accent))
                            .overlay(Capsule().stroke(ChatTheme.background, lineWidth: 1.5))
                            .offset(x: 6, y: -6)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(HeaderTooltipModifier(name: "最新へ移る", details: badge.map { ["新着 \($0) 件"] } ?? [], above: true))
        .accessibilityLabel("最新へ移る")
        .accessibilityValue(badge.map { "新着 \($0) 件" } ?? "")
        .trackHover($hovering)
    }
}
