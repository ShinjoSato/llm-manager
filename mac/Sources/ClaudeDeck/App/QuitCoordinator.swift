import AppKit
import Observation
import MonitorKit

/// 終了の確認。稼働中・要対応のホスト中ルームがあれば確かめ、「作業が終わったら終了」なら全部が待機になるまで待つ。
@MainActor
@Observable
final class QuitCoordinator {
    static let shared = QuitCoordinator()

    /// 「作業が終わったら終了」で待っている間。
    private(set) var isWaiting = false
    /// 待っている間の作業中の件数（帯に出す）。
    private(set) var waitingBusyCount = 0

    @ObservationIgnored weak var model: ChatModel?
    /// シグナルでの終了。確認を出さずに記録だけ書き切る。
    @ObservationIgnored var terminatingBySignal = false
    /// 確認を取り消した時に、閉じていたメインウィンドウを出し直す。
    @ObservationIgnored var showMainWindow: () -> Void = {}
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wait = QuitWait()

    func shouldTerminate() -> NSApplication.TerminateReply {
        if terminatingBySignal { return .terminateNow }
        // 待っている間にもう一度終了を求められたら、すぐ終える。
        if isWaiting {
            stopWaiting()
            return .terminateNow
        }
        guard let model else { return .terminateNow }
        let busy = QuitConfirmation.busy(model.runningHostedRooms)
        guard !busy.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "作業中のセッションがあります"
        alert.informativeText = QuitConfirmation.message(busy: busy, resumesOnLaunch: LaunchSettings.shared.resumeOnLaunch)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "終了する")
        let cancel = alert.addButton(withTitle: "キャンセル")
        cancel.keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "作業が終わったら終了")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .terminateNow
        case .alertThirdButtonReturn:
            startWaiting()
            return .terminateLater
        default:
            showMainWindow()
            return .terminateCancel
        }
    }

    /// 帯の「取り消す」。
    func cancelWaiting() {
        guard isWaiting else { return }
        stopWaiting()
        NSApp.reply(toApplicationShouldTerminate: false)
    }

    private func startWaiting() {
        isWaiting = true
        wait = QuitWait()
        showMainWindow()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // 終了の保留中は run loop がモーダルの mode で回るので、common に載せる。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func stopWaiting() {
        isWaiting = false
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isWaiting else { return }
        let rooms = model?.runningHostedRooms ?? []
        waitingBusyCount = QuitConfirmation.busy(rooms).count
        guard wait.step(rooms, now: Date()) else { return }
        stopWaiting()
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
