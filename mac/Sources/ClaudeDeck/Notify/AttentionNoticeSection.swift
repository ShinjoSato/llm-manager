import MonitorKit
import SwiftUI

/// 「iPhone 連携」ウィンドウの、iCloud 経由の通知の設定と状態（小さく出すだけ）。
struct AttentionNoticeSection: View {
    let notifier: AttentionNotifier

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("要対応を iCloud 経由で iPhone に知らせる",
                   isOn: Binding(get: { notifier.enabled }, set: { notifier.setEnabled($0) }))
                .toggleStyle(.switch)
                .font(.headline)
                .disabled(isUnavailable)
            Text("権限待ち・入力待ち・エラーが 5 秒続いたら、自分の iCloud（プライベート DB）にルーム名と「何を待っているか」の定型文だけを書き、"
                 + "解消したら消します。会話の本文やツールの入力は載せません。同じ Wi-Fi にいなくても届きます。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(Self.statusText(notifier.state), systemImage: Self.symbol(notifier.state))
                .font(.caption)
                .foregroundStyle(Self.isProblem(notifier.state) ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var isUnavailable: Bool {
        if case .unavailable = notifier.state { return true }
        return false
    }

    static func statusText(_ state: AttentionNotifier.State) -> String {
        switch state {
        case .off: return "切っています"
        case .unavailable(let reason): return reason
        case .active(.idle): return "有効（まだ書いた知らせはありません）"
        case .active(.synced(let at)): return "有効・最後に iCloud へ書いた時刻 \(ChatTime.dayTime(at))"
        case .active(.retrying(let failures, let retryAt, let message)):
            return "\(message)。\(ChatTime.dayTime(retryAt)) に送り直します（\(failures) 回目の失敗）"
        }
    }

    static func symbol(_ state: AttentionNotifier.State) -> String {
        switch state {
        case .off: return "bell.slash"
        case .unavailable: return "icloud.slash"
        case .active(.retrying): return "exclamationmark.icloud"
        case .active: return "icloud"
        }
    }

    static func isProblem(_ state: AttentionNotifier.State) -> Bool {
        switch state {
        case .unavailable, .active(.retrying): return true
        default: return false
        }
    }
}
