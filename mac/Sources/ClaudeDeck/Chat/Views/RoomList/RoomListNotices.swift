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
