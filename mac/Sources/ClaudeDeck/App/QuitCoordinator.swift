import AppKit
import Observation
import MonitorKit

/// 終了の確認。稼働中・権限待ちのホスト中ルームがあれば確かめ、「作業が終わったら終了」なら稼働中が無くなるまで待つ。
@MainActor
@Observable
final class QuitCoordinator {
    static let shared = QuitCoordinator()

    /// 「作業が終わったら終了」で待っている間。
    private(set) var isWaiting = false
    /// 待っている間の稼働中の件数（帯に出す）。
    private(set) var waitingBusyCount = 0
    /// 終了の確認ダイアログを出している間。
    private(set) var isConfirming = false

    @ObservationIgnored weak var model: ChatModel?
    /// シグナル・OS の終了。確認を出さずに記録だけ書き切る。
    @ObservationIgnored private var forced = false
    /// 確認を取り消した時に、閉じていたメインウィンドウを出し直す。
    @ObservationIgnored var showMainWindow: () -> Void = {}
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wait = QuitWait()

    /// 終わるつもりの間（確認中・保留中）。続きの頼みなど新しい作業を始めさせない。
    var isHolding: Bool { isConfirming || isWaiting }

    func shouldTerminate() -> NSApplication.TerminateReply {
        if forced || Self.isSystemQuit() {
            stopWaiting()
            return .terminateNow
        }
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
        // Return で中断しないよう、既定（最初のボタン）はキャンセルにする。
        alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "作業が終わったら終了")
        alert.addButton(withTitle: "終了する")
        isConfirming = true
        let response = alert.runModal()
        isConfirming = false
        // 確認中にシグナルが届いたら、どのボタンでもなく終える。
        if forced { return .terminateNow }
        switch response {
        case .alertThirdButtonReturn:
            return .terminateNow
        case .alertSecondButtonReturn:
            startWaiting()
            return .terminateLater
        default:
            showMainWindow()
            return .terminateCancel
        }
    }

    /// SIGTERM / SIGINT。確認中なら閉じ、保留中ならそのまま終える（必ず終わる）。
    func terminateBySignal() {
        forced = true
        if isWaiting {
            stopWaiting()
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        if isConfirming {
            NSApp.abortModal()
            return
        }
        // 上限の知らせなど別のダイアログが出ていると terminate が進まないので閉じてから終える。
        if NSApp.modalWindow != nil { NSApp.abortModal() }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// 帯の「取り消す」。
    func cancelWaiting() {
        guard isWaiting else { return }
        stopWaiting()
        NSApp.reply(toApplicationShouldTerminate: false)
    }

    /// ログアウト・再起動・シャットダウンの quit（確認で止めると OS の終了を妨げる）。
    private static func isSystemQuit() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication else { return false }
        let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue
        return QuitConfirmation.isSystemQuit(reason: reason)
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
        waitingBusyCount = QuitConfirmation.working(rooms).count
        guard wait.step(rooms, now: Date()) else { return }
        stopWaiting()
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
