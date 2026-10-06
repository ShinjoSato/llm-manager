import MonitorKit
import SwiftUI

/// 外観: カラーテーマ（ナイト / ライト）を選ぶ。選んだ時点で全画面に映る。
struct AppearanceSettingsTab: View {
    @Bindable var appearance: AppearanceSettings

    var body: some View {
        Form {
            Section {
                Picker("テーマ", selection: $appearance.theme) {
                    ForEach(DeckTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(appearance.theme.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ThemePreview(theme: appearance.theme)
            } header: {
                Text("カラーテーマ")
            } footer: {
                Text("システムの外観（ダーク / ライト）には合わせず、ここで選んだテーマを使います。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// 選んだテーマの色見本（吹き出しと状態色）。
private struct ThemePreview: View {
    let theme: DeckTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Claude の返答")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(ChatTheme.claudeBubble))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(ChatTheme.claudeBubbleBorder))
                Spacer()
                Text("あなたの発言")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.userBubbleText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(ChatTheme.userBubble))
            }
            HStack(spacing: 12) {
                ForEach([SessionStatus.permission, .waiting, .working, .error], id: \.self) { status in
                    HStack(spacing: 4) {
                        Circle().fill(ChatTheme.color(for: status)).frame(width: 7, height: 7)
                        Text(ChatTheme.label(for: status))
                            .font(ChatTheme.caption)
                            .foregroundStyle(ChatTheme.color(for: status))
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(ChatTheme.background))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ChatTheme.border))
        .environment(\.colorScheme, ChatTheme.colorScheme(for: theme))
        .accessibilityHidden(true)
    }
}
