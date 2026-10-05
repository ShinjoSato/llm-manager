import DeckCore
import SwiftUI
import UIKit

/// つながっていない間だけ、一覧と会話の上に出す。理由と、してほしいことを書く。
struct ConnectionBanner: View {
    @Bindable var model: AppModel
    @State private var expanded = false

    var body: some View {
        switch model.connection {
        case .connected, .unpaired:
            EmptyView()
        case .connecting, .paused:
            if model.onWiFi == false { wifiNotice }
            banner(color: DeckTheme.waiting, symbol: nil, title: "\(model.serverName) に接続しています…", detail: nil, action: nil)
        case .waiting(let issue, let retryAt):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(retryAt.timeIntervalSince(context.date).rounded(.up)))
                let reconnect = ("今すぐ再接続", { model.connect() })
                banner(color: DeckTheme.permission, symbol: issue.needsSettings ? "network.slash" : "wifi.exclamationmark",
                       title: issue.title + (seconds > 0 ? "（\(seconds) 秒後につなぎ直します）" : "（つなぎ直しています）"),
                       detail: Self.wifiNote(for: issue, onWiFi: model.onWiFi) + issue.detail + staleNote,
                       action: issue.needsSettings ? ("設定を開く", { Self.openSettings() }) : reconnect,
                       secondary: issue.needsSettings ? reconnect : nil,
                       expandedByDefault: issue.needsSettings)
            }
        case .failed(let issue):
            banner(color: DeckTheme.error, symbol: "lock.trianglebadge.exclamationmark", title: issue.title, detail: issue.detail,
                   action: ("ペアリングし直す", { model.forget() }))
        }
    }

    /// 理由が Wi-Fi か許可と分かっている時は、Wi-Fi の補足を重ねない（許可が無い時に Wi-Fi のせいにしない）。
    static func wifiNote(for issue: RemoteIssue, onWiFi: Bool?) -> String {
        guard onWiFi == false, issue.kind != .offline, issue.kind != .localNetworkDenied else { return "" }
        return "iPhone が Wi-Fi につながっていません。\n"
    }

    /// このアプリの設定画面（ローカルネットワークの許可がある）を開く。戻ると前に出た時の再接続が走る。
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var staleNote: String {
        guard let at = model.stateUpdatedAt else { return "" }
        return "\n\n表示している一覧は \(DeckTime.dayTime(at)) 時点のものです。"
    }

    private var wifiNotice: some View {
        InlineNotice(symbol: "wifi.slash", text: "iPhone が Wi-Fi につながっていません。Mac と同じ Wi-Fi につないでください。")
    }

    private func banner(color: Color, symbol: String?, title: String, detail: String?,
                        action: (String, () -> Void)?, secondary: (String, () -> Void)? = nil,
                        expandedByDefault: Bool = false) -> some View {
        // 設定で直すものは、何をすればよいかを最初から見せる。
        let expanded = self.expanded != expandedByDefault
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if detail != nil { withAnimation(.easeOut(duration: 0.15)) { self.expanded.toggle() } }
            } label: {
                HStack(spacing: 8) {
                    if let symbol { Image(systemName: symbol) } else { ProgressView().controlSize(.small).tint(color) }
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if detail != nil {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .bold))
                    }
                }
                .foregroundStyle(color)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded, let detail {
                Text(detail)
                    .font(DeckTheme.caption)
                    .foregroundStyle(DeckTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let action { actionButton(action) }
                if let secondary { actionButton(secondary) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.45)))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityIdentifier("connection-banner")
    }

    private func actionButton(_ action: (String, () -> Void)) -> some View {
        Button(action: action.1) {
            Text(action.0)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DeckTheme.text)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(DeckTheme.inputSurface))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(DeckTheme.inputBorder))
        }
        .buttonStyle(.plain)
    }
}

/// 接続先の確かめと、ペアリングの解除。
struct SettingsScreen: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnpair = false
    @State private var unpairNote: String?
    @State private var unpairing = false

    var body: some View {
        NavigationStack {
            List {
                if let pairing = model.pairing {
                    Section("ペアリングしている Mac") {
                        row("名前", pairing.serverName)
                        row("接続先", "\(pairing.host):\(pairing.port)", mono: true)
                        if let local = pairing.localHostName { row("予備の接続先", local, mono: true) }
                        row("証明書の指紋", RemotePinning.display(pairing.fingerprint), mono: true)
                        row("ペアリングした日時", DeckTime.dayTime(Date(epochMillis: pairing.pairedAt)))
                    }
                    Section {
                        Button("今すぐ再接続") {
                            model.connect()
                            dismiss()
                        }
                    }
                    Section {
                        Button(role: .destructive) { confirmingUnpair = true } label: {
                            HStack {
                                Text("ペアリングを解除")
                                if unpairing { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(unpairing)
                    } footer: {
                        Text("Mac の端末一覧からこの iPhone を取り消し、iPhone に残した鍵も消します。")
                    }
                }
                if let note = unpairNote {
                    Section { Text(note).foregroundStyle(DeckTheme.permission) }
                }
                Section("このアプリ") {
                    row("版", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                    Text("同じ Wi-Fi の中だけで Mac とやり取りします。外部のサーバーや API キーは使いません。")
                        .font(DeckTheme.caption)
                        .foregroundStyle(DeckTheme.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DeckTheme.background.ignoresSafeArea())
            .navigationTitle("接続")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
            .confirmationDialog("ペアリングを解除しますか？", isPresented: $confirmingUnpair, titleVisibility: .visible) {
                Button("解除する", role: .destructive) {
                    unpairing = true
                    Task {
                        let note = await model.unpair()
                        unpairing = false
                        if let note { unpairNote = note } else { dismiss() }
                    }
                }
                Button("やめる", role: .cancel) {}
            } message: {
                Text("もう一度使うには、Mac で QR を出してペアリングし直します。")
            }
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(DeckTheme.caption).foregroundStyle(DeckTheme.secondary)
            Text(value)
                .font(mono ? DeckTheme.mono : DeckTheme.body)
                .foregroundStyle(DeckTheme.text)
                .textSelection(.enabled)
        }
    }
}
