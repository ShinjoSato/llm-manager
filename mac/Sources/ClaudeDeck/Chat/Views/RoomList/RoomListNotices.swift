import SwiftUI
import MonitorKit

/// 監視が動いていない・受け口が開けない間だけ、検索欄の下に出す。
struct ConnectionNotice: View {
    let connection: MonitorConnectionState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.circle")
            Text(text)
        }
        .font(ChatTheme.caption)
        .foregroundStyle(ChatTheme.permission)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }

    private var text: String {
        switch connection {
        case .starting: return "セッションの監視を始めています…"
        case .idle, .connected: return "セッションを監視していません"
        }
    }
}

/// フックの受け口（:8766）を開けていない時の注意。権限待ち・入力待ちはフックでしか分からない。
struct HookServerNotice: View {
    let text: String

    static func text(for state: HTTPServerState) -> String? {
        switch state {
        case .portInUse(let port):
            return "ポート \(port) を別のプロセスが使っているため、フック（権限待ち・入力待ち）が届きません。そのプロセスを止めると自動で引き継ぎます。"
        case .failed(let reason):
            return "フックの受け口を開けません（\(reason)）。権限待ち・入力待ちが届きません。"
        case .stopped, .starting, .listening:
            return nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(ChatTheme.caption)
        .foregroundStyle(ChatTheme.permission)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .accessibilityIdentifier("hook-server-notice")
    }
}

/// 起動時に前回のセッションを再開した結果と、見送った分の再開。
struct RestoreNotice: View {
    let restorer: SessionRestorer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = restorer.notice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.clockwise.circle")
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { restorer.dismissNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help("閉じる")
                }
                .foregroundStyle(ChatTheme.working)
            }
            if let summary = restorer.deferredSummary {
                HStack(spacing: 8) {
                    Text(summary)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(ChatTheme.permission)
                    Spacer(minLength: 0)
                    Button("再開する") { restorer.resumeDeferred() }
                    Button("破棄") { restorer.discardDeferred() }
                }
                .controlSize(.small)
            }
        }
        .font(ChatTheme.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .accessibilityIdentifier("restore-notice")
    }
}

/// 「作業が終わったら終了」で待っている間の帯。
struct QuitWaitNotice: View {
    let coordinator: QuitCoordinator

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "power.circle")
            Text(coordinator.waitingBusyCount > 0
                 ? "作業が終わったら終了します（稼働中 \(coordinator.waitingBusyCount) 件）"
                 : "まもなく終了します")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("取り消す") { coordinator.cancelWaiting() }
                .controlSize(.small)
        }
        .font(ChatTheme.caption)
        .foregroundStyle(ChatTheme.permission)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .accessibilityIdentifier("quit-wait-notice")
    }
}
