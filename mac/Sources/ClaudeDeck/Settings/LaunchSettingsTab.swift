import MonitorKit
import SwiftUI

/// 起動と終了: 前回のセッションの再開と、作業中だったものへの頼み。
struct LaunchSettingsTab: View {
    @Bindable var settings: LaunchSettings

    var body: some View {
        Form {
            Section {
                Toggle("起動時に前回のセッションを再開する", isOn: $settings.resumeOnLaunch)
                Toggle("作業中だったものに続きを頼む", isOn: $settings.askToContinue)
                    .disabled(!settings.resumeOnLaunch)
                Text("頼む文: 「\(SessionRestore.continueMessage)」")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("起動時")
            } footer: {
                Text("アプリでホストしていたセッションを記録し（\(HostedSessionsFile.defaultURL().path)）、次の起動で同じフォルダから claude --resume で再開します。"
                     + "同じ会話が別の claude で動いている時・Max 枠の上限に達している時・前回の再開の直後にアプリが落ちた時は自動では再開せず、一覧の上の帯から再開できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("稼働中・権限待ちのルームがある時は、終了（⌘Q・ウィンドウを閉じる）の前に確認します。待機・入力待ちだけなら確認しません。"
                     + "ログアウト・再起動・シャットダウンでは確認せず、記録だけ書いて終了します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("終了時")
            }
        }
        .formStyle(.grouped)
    }
}
