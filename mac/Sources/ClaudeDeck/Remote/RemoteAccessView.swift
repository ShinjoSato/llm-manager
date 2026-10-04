import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MonitorKit
import SwiftUI

/// 「iPhone 連携」ウィンドウ。1 つだけ持つ。
@MainActor
enum RemoteAccessWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingView(rootView: RemoteAccessView(controller: .shared))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "iPhone 連携"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ClaudeDeckRemoteAccessWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

struct RemoteAccessView: View {
    let controller: RemoteAccessController
    @State private var portText = ""
    @State private var portError: String?
    @State private var revoking: RemoteDevice?

    private var service: RemoteAccessService { controller.service }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settings
                Divider()
                pairingSection
                Divider()
                devicesSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 420)
        .onAppear {
            portText = String(controller.port)
            controller.refreshInterfaces()
        }
        .confirmationDialog("「\(revoking?.name ?? "")」を取り消しますか？", isPresented: Binding(get: { revoking != nil },
                                                                                  set: { if !$0 { revoking = nil } })) {
            Button("取り消す", role: .destructive) {
                if let device = revoking { service.revoke(device.id) }
                revoking = nil
            }
            Button("キャンセル", role: .cancel) { revoking = nil }
        } message: {
            Text("この端末からは繋がらなくなります。使うにはもう一度ペアリングしてください。")
        }
    }

    // MARK: - 設定

    @ViewBuilder
    private var settings: some View {
        Toggle("同じ Wi-Fi の iPhone から使えるようにする", isOn: Binding(get: { controller.enabled }, set: { controller.setEnabled($0) }))
            .toggleStyle(.switch)
            .font(.headline)
        Text("TLS で暗号化し、ペアリングした iPhone だけが繋がれます。フック・チャネルの口（127.0.0.1:8766）は LAN に出しません。"
             + "初めて有効にした時に macOS が「受信接続を許可しますか？」と尋ねたら「許可」を選んでください。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("待ち受ける口").foregroundStyle(.secondary)
                HStack {
                    Picker("", selection: Binding(get: { controller.interfaceName ?? "" },
                                                  set: { controller.setInterface($0.isEmpty ? nil : $0) })) {
                        Text("自動（\(LANInterfaces.choose(nil, from: controller.interfaces).map { "\($0.name) \($0.address)" } ?? "見つかりません")）")
                            .tag("")
                        ForEach(controller.interfaces) { interface in
                            Text("\(interface.name)（\(interface.address)）").tag(interface.name)
                        }
                        if let name = controller.interfaceName, !controller.interfaces.contains(where: { $0.name == name }) {
                            Text("\(name)（見つかりません）").tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300)
                    Button("再読み込み") { controller.refreshInterfaces() }
                }
            }
            GridRow {
                Text("ポート").foregroundStyle(.secondary)
                HStack {
                    TextField("\(RemoteAPI.defaultPort)", text: $portText)
                        .frame(width: 80)
                        .onSubmit(applyPort)
                    Button("適用", action: applyPort)
                        .disabled(portText == String(controller.port))
                    if let portError { Text(portError).font(.caption).foregroundStyle(.red) }
                }
            }
            GridRow {
                Text("状態").foregroundStyle(.secondary)
                Text(controller.statusText)
                    .foregroundStyle(service.boundPort != nil ? Color.green : Color.primary)
                    .textSelection(.enabled)
            }
            if let fingerprint = service.fingerprint {
                GridRow(alignment: .top) {
                    Text("証明書の指紋").foregroundStyle(.secondary)
                    Text("SHA-256 \(RemotePinning.display(fingerprint))")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func applyPort() {
        guard let value = Int(portText.trimmingCharacters(in: .whitespaces)), controller.setPort(value) else {
            portError = "1024〜65535（8766 以外）で指定してください"
            return
        }
        portError = nil
    }

    // MARK: - ペアリング

    @ViewBuilder
    private var pairingSection: some View {
        HStack {
            Text("iPhone を追加").font(.headline)
            Spacer()
            if service.pairingOffer == nil {
                Button("QR を出す") { service.beginPairing() }
                    .disabled(service.boundPort == nil)
            } else {
                Button("閉じる") { service.cancelPairing() }
            }
        }
        if let offer = service.pairingOffer {
            HStack(alignment: .top, spacing: 16) {
                if let image = QRCodeImage.make(offer.url.absoluteString) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .background(Color.white)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("iPhone の claude-deck アプリで読み取ってください。")
                    Text("接続先: \(offer.host):\(offer.port)").font(.callout).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(offer.expiresAt / 1000 - context.date.timeIntervalSince1970))
                        Text(left > 0 ? "あと \(left / 60):\(String(format: "%02d", left % 60)) で無効になります（1 回限り）" : "期限が切れました")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text("QR には一時的なコードと証明書の指紋が入っています。他の人に見せないでください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if service.boundPort == nil {
            Text("口を有効にすると QR を出せます。").font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - 端末一覧

    @ViewBuilder
    private var devicesSection: some View {
        Text("ペアリング済みの端末").font(.headline)
        if service.devices.isEmpty {
            Text("まだありません。").font(.callout).foregroundStyle(.secondary)
        }
        ForEach(service.devices) { device in
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "iphone")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(device.name)
                        if (service.connections[device.id] ?? 0) > 0 {
                            Text("接続中")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.green.opacity(0.25)))
                        }
                    }
                    Text("最後に使った時刻: \(Self.describe(device.lastUsedAt))・ペアリング: \(Self.describe(device.pairedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取り消す") { revoking = device }
            }
            .padding(.vertical, 4)
        }
    }

    private static func describe(_ millis: Double?) -> String {
        guard let millis else { return "未使用" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: Date(epochMillis: millis))
    }
}

/// QR の画像（拡大してもぼけないよう整数倍で描く）。
enum QRCodeImage {
    static func make(_ text: String, modulePixels: CGFloat = 8) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: modulePixels, y: modulePixels))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
