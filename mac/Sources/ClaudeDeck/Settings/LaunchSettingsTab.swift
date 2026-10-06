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
                     + "同じ会話が別の claude で動いている時と、Max 枠の上限に達している時は再開しません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("稼働中・要対応のルームがある時は、終了（⌘Q・ウィンドウを閉じる）の前に確認します。待機だけなら確認しません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("終了時")
            }
        }
        .formStyle(.grouped)
    }
}
