import SwiftUI
import MonitorKit

/// 権限待ちのカード（会話の末尾）。
struct PermissionCard: View {
    let toolName: String
    let description: String
    let lines: [String]
    let busy: Bool
    let onDecide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CardTitle(symbol: "exclamationmark.shield.fill", title: "権限の確認")
                Text(toolName)
                    .font(ChatTheme.mono.weight(.semibold))
                    .foregroundStyle(ChatTheme.permission)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(ChatTheme.permissionChip))
            }
            if !description.isEmpty, description != toolName {
                Text(description).font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
            }
            if !lines.isEmpty {
                CardCode(text: lines.prefix(10).joined(separator: "\n"))
            }
            HStack(spacing: 8) {
                Button { onDecide(true) } label: {
                    Text("許可")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ChatTheme.onAccent)
                        .frame(width: 84, height: 30)
                        .background(RoundedRectangle(cornerRadius: 9).fill(ChatTheme.accent))
                }
                .buttonStyle(.plain)
                Button { onDecide(false) } label: {
                    CardButtonLabel(title: "拒否", width: 84)
                }
                .buttonStyle(.plain)
                if busy { SendingIndicator() }
            }
            .disabled(busy)
            .opacity(busy ? 0.6 : 1)
        }
        .cardFrame()
    }
}
