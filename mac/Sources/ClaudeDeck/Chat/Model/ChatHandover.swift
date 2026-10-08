import AppKit
import Observation
import MonitorKit

/// 外部セッション（ターミナル起動）の claude を止めて、同じ会話をこのアプリで再開する。
@MainActor
@Observable
final class ChatHandover {
    private let alerts: ChatAlerts

    /// 引き継ぎ中の sessionId（終了待ち〜再開まで）。
    private(set) var inProgress: Set<String> = []
    /// 終了を確認できた後の再開（HostedSession の起動と一覧への追加は ChatModel が持つ）。
    @ObservationIgnored var onResume: (_ project: ManagedProject, _ sessionId: String, _ from: RoomID) -> Void = { _, _, _ in assertionFailure("onResume 未設定") }

    init(alerts: ChatAlerts) {
        self.alerts = alerts
    }

    /// 起動元（VS Code 拡張等）のせいで引き継げない理由。nil ならターミナルの対話セッション。
    func sourceReason(for room: Room) -> String? {
        guard let snapshot = room.snapshot else { return "このルームは引き継げません" }
        let record = ClaudeSessionRegistry().record(forPid: snapshot.pid).flatMap { $0.sessionId == snapshot.sessionId ? $0 : nil }
        return SessionHandover.unsupportedSourceReason(entrypoint: record?.entrypoint ?? snapshot.entrypoint, kind: record?.kind)
    }

    /// 引き継げない理由。nil なら引き継げる。
    func disabledReason(for room: Room) -> String? {
        guard room.hosted == nil, let snapshot = room.snapshot, let sessionId = room.sessionId else {
            return "このルームは引き継げません"
        }
        if inProgress.contains(sessionId) { return "引き継ぎ中…" }
        if !snapshot.alive || room.status == .stopped { return "このセッションは終了しています" }
        if !SessionHandover.isResumableSessionId(sessionId) { return "sessionId の形式が想定外のため引き継げません" }
        if let reason = sourceReason(for: room) { return reason }
        if LimitWatch.shared.isLimitReached { return "Max 枠の上限に達しているため引き継げません（リセット後に試してください）" }
        return nil
    }

    /// 確認ダイアログを出し、了承されたら外部の claude を止めてこのアプリで再開する。キャンセルなら何もしない。
    func request(_ room: Room) {
        if let reason = disabledReason(for: room) {
            alerts.message = reason
            return
        }
        guard let snapshot = room.snapshot, let sessionId = room.sessionId else { return }
        let alert = NSAlert()
        alert.messageText = "「\(room.name)」をアプリに引き継ぎますか？"
        alert.informativeText = """
            1. ターミナルで動いている claude（pid \(snapshot.pid)）を終了します（Ctrl-C と同じ SIGINT。数秒で終わらなければ SIGTERM）。作業中なら中断されます。
            2. 終了を確認できたら、同じフォルダでこのアプリから claude --resume を起動し、同じ会話を続きから再開します。

            元のターミナルのウィンドウは閉じません。終了を確認できなかった場合は再開しません。
            フォルダ: \(room.cwd)
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "引き継ぐ")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        handOver(room: room, pid: snapshot.pid, sessionId: sessionId)
    }

    private func handOver(room: Room, pid: Int32, sessionId: String) {
        guard !inProgress.contains(sessionId) else { return }
        // 確認ダイアログを出している間に上限到達・終了などが起きうるので、止める前に判定し直す。
        if let reason = disabledReason(for: room) {
            alerts.message = "引き継ぎを中止しました（何も終了していません）: \(reason)"
            return
        }
        inProgress.insert(sessionId)
        let project = SettingsStore.shared.project(atPath: room.cwd, orNamed: room.name)
        let roomId = room.id
        Task {
            let outcome = await SessionTerminator().terminate(pid: pid, sessionId: sessionId)
            defer { inProgress.remove(sessionId) }
            switch outcome {
            case .exited:
                // 待っている間に上限へ達したら起動しない（起動してもすぐ止められる）。
                if LimitWatch.shared.isLimitReached {
                    alerts.message = "ターミナルの claude は終了しましたが、Max 枠の上限に達しているため再開しませんでした。"
                    return
                }
                onResume(project, sessionId, roomId)
            case .refused(let reason):
                alerts.message = "引き継ぎを中止しました（何も終了していません）: \(reason)"
            case .runningElsewhere(let other):
                alerts.message = "同じ会話が別の claude（pid \(other)）で動いているため、再開していません（二重起動を避けるため）。"
            case .stillRunning:
                alerts.message = "ターミナルの claude が終了しなかったため、再開していません（同じ会話の二重起動を避けるため）。"
                    + "ターミナルで終了してからもう一度お試しください。"
            }
        }
    }
}
