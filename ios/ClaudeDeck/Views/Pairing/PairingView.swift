import DeckCore
import SwiftUI

/// まだペアリングしていない時の画面。Mac の QR を読ませる。
struct PairingView: View {
    @Bindable var model: AppModel
    @State private var scanning = false
    @State private var scanned: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    PixelAvatar(status: .waiting, size: 64, hidesFromAccessibility: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("claude-deck")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(DeckTheme.heading)
                        Text("Mac の Claude Code を iPhone から")
                            .font(DeckTheme.body)
                            .foregroundStyle(DeckTheme.secondary)
                    }
                }
                .padding(.top, 36)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Mac とペアリング")
                        .font(DeckTheme.headline)
                        .foregroundStyle(DeckTheme.heading)
                    step(1, "Mac の claude-deck でメニュー「claude-deck → iPhone 連携…」を開き、有効にします。")
                    step(2, "「QR を出す」を押します（5 分で失効・1 回限り）。")
                    step(3, "下のボタンで QR を読み取り、表示された Mac の名前を確かめてペアリングします。")
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(DeckTheme.inputSurface))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(DeckTheme.border))

                Button { scanning = true } label: {
                    Label("QR を読み取る", systemImage: "qrcode.viewfinder")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DeckTheme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(RoundedRectangle(cornerRadius: 12).fill(DeckTheme.accent))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("scan-qr")

                VStack(alignment: .leading, spacing: 8) {
                    Text("カメラが使えない時は、QR の内容（claude-deck://pair?…）をコピーして貼り付けられます。")
                        .font(DeckTheme.caption)
                        .foregroundStyle(DeckTheme.tertiary)
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        Task { @MainActor in model.offerLink(text, source: .pasted) }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.roundedRectangle(radius: 10))
                    .tint(DeckTheme.inputBorder)
                }

                if let error = model.pairingError, model.pendingOffer == nil {
                    ErrorNote(text: error.text, opensSettings: error.needsSettings)
                }

                Text("通信は同じ Wi-Fi の中だけで、Mac の証明書を QR の指紋で確かめて暗号化します。外部のサーバーは使いません。")
                    .font(DeckTheme.caption)
                    .foregroundStyle(DeckTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.never)
        .background(DeckTheme.background.ignoresSafeArea())
        // カメラ画面を閉じる途中に確認のシートを出すと iOS が表示を断るので、閉じ終わってから渡す。
        .fullScreenCover(isPresented: $scanning, onDismiss: {
            guard let text = scanned else { return }
            scanned = nil
            model.offerLink(text, source: .camera)
        }) {
            QRScannerScreen { text in
                scanned = text
                scanning = false
            } onCancel: {
                scanning = false
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(DeckTheme.onAccent)
                .frame(width: 20, height: 20)
                .background(Circle().fill(DeckTheme.accent))
            Text(text)
                .font(DeckTheme.body)
                .foregroundStyle(DeckTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ErrorNote: View {
    let text: String
    var opensSettings = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DeckTheme.error)
            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .font(DeckTheme.caption)
                    .foregroundStyle(DeckTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if opensSettings {
                    Button { ConnectionBanner.openSettings() } label: {
                        Text("設定を開く")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DeckTheme.text)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 9).fill(DeckTheme.inputSurface))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(DeckTheme.inputBorder))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("open-settings")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DeckTheme.error.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DeckTheme.error.opacity(0.4)))
    }
}

/// 読み取った・開かれたリンクの確認。ここで「ペアリングする」を押すまで何も送らない。
struct PairingConfirmView: View {
    @Bindable var model: AppModel
    let offer: PairingOffer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let payload = offer.payload
        let problem = payload.addressProblem ?? payload.problem(now: Date().timeIntervalSince1970 * 1000)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let warning = offer.originWarning {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(DeckTheme.permission)
                            Text(warning)
                                .font(DeckTheme.caption)
                                .foregroundStyle(DeckTheme.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(DeckTheme.permission.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DeckTheme.permission.opacity(0.5)))
                    }
                    if model.pairing != nil {
                        Text("今のペアリング（\(model.serverName)）は、この Mac とのペアリングに置き換わります。")
                            .font(DeckTheme.caption)
                            .foregroundStyle(DeckTheme.permission)
                    }
                    field("Mac の名前", payload.name.isEmpty ? "（名前なし）" : payload.name, mono: false)
                    field("接続先", "\(payload.host):\(payload.port)" + (payload.localHostName.map { "\n予備: \($0)" } ?? ""), mono: true)
                    field("証明書の指紋（SHA-256）", RemotePinning.display(payload.fingerprint), mono: true)
                    Text("Mac の「iPhone 連携」ウィンドウに出ている指紋と同じか確かめてください。")
                        .font(DeckTheme.caption)
                        .foregroundStyle(DeckTheme.tertiary)
                    if let problem { ErrorNote(text: problem) }
                    if let error = model.pairingError {
                        ErrorNote(text: error.text + (error.needsSettings ? "\nオンにしたら、もう一度「ペアリングする」を押してください。" : ""),
                                  opensSettings: error.needsSettings)
                    }
                    Button {
                        Task { await model.confirmPairing(offer) }
                    } label: {
                        HStack(spacing: 8) {
                            if model.pairingInProgress { ProgressView().tint(DeckTheme.onAccent) }
                            Text(model.pairingInProgress ? "ペアリングしています…" : "ペアリングする")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DeckTheme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(RoundedRectangle(cornerRadius: 12).fill(DeckTheme.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(problem != nil || model.pairingInProgress)
                    .opacity(problem != nil ? 0.4 : 1)
                    .accessibilityIdentifier("confirm-pairing")
                }
                .padding(20)
            }
            .background(DeckTheme.background.ignoresSafeArea())
            .navigationTitle("この Mac とペアリング")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") {
                        model.pairingError = nil
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.pairingInProgress)
    }

    private func field(_ label: String, _ value: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(DeckTheme.caption).foregroundStyle(DeckTheme.secondary)
            Text(value)
                .font(mono ? DeckTheme.mono : .system(size: 17, weight: .semibold))
                .foregroundStyle(DeckTheme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(DeckTheme.inputSurface))
    }
}
