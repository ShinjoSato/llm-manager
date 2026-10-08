import AVFoundation
import SwiftUI
import UIKit

/// カメラで QR を読む画面。読めた文字列をそのまま返す（中身の検証と確認は呼び出し側）。
struct QRScannerScreen: View {
    let onScan: (String) -> Void
    let onCancel: () -> Void
    @State private var access: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var unavailable = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if access == .authorized && !unavailable {
                QRCameraView(onScan: onScan, onUnavailable: { unavailable = true })
                    .ignoresSafeArea()
                RoundedRectangle(cornerRadius: 20)
                    .stroke(DeckTheme.accent, lineWidth: 3)
                    .frame(width: 240, height: 240)
                    .accessibilityHidden(true)
            } else {
                message
            }
            VStack {
                HStack {
                    Spacer()
                    Button("閉じる", action: onCancel)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.55)))
                }
                Spacer()
                Text("Mac の「iPhone 連携」に出ている QR を枠に入れてください")
                    .font(DeckTheme.body)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.55)))
            }
            .padding(20)
        }
        .task {
            if access == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                access = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    @ViewBuilder
    private var message: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 34)).foregroundStyle(DeckTheme.secondary)
            switch access {
            case .denied, .restricted:
                Text("カメラの使用が許可されていません。設定でカメラを許可するか、QR の内容を貼り付けてください。")
                    .multilineTextAlignment(.center)
                Button("設定を開く") { UIApplication.openAppSettings() }
                .foregroundStyle(DeckTheme.accent)
            case .notDetermined:
                ProgressView()
            default:
                Text("この端末ではカメラを使えません。QR の内容を貼り付けてください。").multilineTextAlignment(.center)
            }
        }
        .font(DeckTheme.body)
        .foregroundStyle(DeckTheme.text)
        .padding(32)
    }
}

/// AVCaptureSession で QR だけを拾う。
struct QRCameraView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> QRCameraController {
        let controller = QRCameraController()
        controller.onScan = onScan
        controller.onUnavailable = onUnavailable
        return controller
    }

    func updateUIViewController(_ controller: QRCameraController, context: Context) {}
}

final class QRCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onUnavailable: (() -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        #if targetEnvironment(simulator)
        // シミュレータのカメラは映像が来ず黒いままになるので、貼り付けに回す。
        onUnavailable?()
        return
        #else
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onUnavailable?()
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onUnavailable?()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
        NotificationCenter.default.addObserver(self, selector: #selector(sessionFailed), name: AVCaptureSession.runtimeErrorNotification, object: session)
        #endif
    }

    @objc private func sessionFailed(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in self?.onUnavailable?() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = session
        // startRunning は待たされるので主スレッドの外で呼ぶ。
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first?.stringValue else { return }
        delivered = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScan?(code)
    }
}
