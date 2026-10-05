import SwiftUI
import UIKit

/// 設定画面の「要対応の通知」。
struct AttentionNotificationSection: View {
    let notifications: AttentionNotifications

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { notifications.enabled },
                                 set: { on in Task { await notifications.setEnabled(on) } })) {
                HStack {
                    Text("要対応を通知する")
                    if notifications.state == .working { Spacer(); ProgressView() }
                }
            }
            .accessibilityIdentifier("attention-notifications-toggle")
            if case .problem(let text, let needsSettings) = notifications.state {
                Text(text)
                    .font(DeckTheme.caption)
                    .foregroundStyle(DeckTheme.permission)
                if needsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("設定を開く") { UIApplication.shared.open(url) }
                }
            }
        } header: {
            Text("通知")
        } footer: {
            Text("Mac で権限待ち・入力待ち・エラーが続いたら、自分の iCloud を経由して知らせます（アプリを閉じていても・外出先でも届きます）。"
                 + "載るのはルーム名と何を待っているかだけで、会話の本文は載りません。通知を開くとそのルームへ進みます（操作は Mac と同じ Wi-Fi の時だけ）。")
        }
    }
}
