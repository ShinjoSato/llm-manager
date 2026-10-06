import SwiftUI
import MonitorKit

/// ウィンドウ左端の細いバー。左の一覧を「ルーム」（状態別）と「ディレクトリ」（登録プロジェクト）で切り替える。
struct ListModeBar: View {
    @Bindable var model: ChatModel

    static let width: CGFloat = 48

    var body: some View {
        VStack(spacing: 6) {
            ForEach(RoomListMode.allCases, id: \.self) { mode in
                button(for: mode)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(ChatTheme.background)
    }

    private func button(for mode: RoomListMode) -> some View {
        let selected = model.listMode == mode
        let badge = mode == .rooms ? model.attentionCount : 0
        return Button { model.listMode = mode } label: {
            Image(systemName: mode.symbol)
                .font(.system(size: 16, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? ChatTheme.selectionInk : ChatTheme.tertiary)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? ChatTheme.selectedRow : Color.clear))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 { AttentionBadge(count: badge).offset(x: 3, y: -3) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HeaderTooltipModifier(name: mode.title, details: [], leadingOffset: 42))
        .accessibilityLabel(badge > 0 ? "\(mode.title)（要対応 \(badge) 件）" : mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 要対応の件数。2 桁を超えたら丸める（バーの幅に収めるため）。
private struct AttentionBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(ChatTheme.onPermission)
            .padding(.horizontal, 4)
            .frame(minWidth: 15, minHeight: 15)
            .background(Capsule().fill(ChatTheme.permission))
            .accessibilityHidden(true)
    }
}
