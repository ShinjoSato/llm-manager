import Foundation
import MonitorKit
import Observation

/// 要対応になったルームを iCloud（CloudKit のプライベート DB）に短く書き、解消したら消す。iPhone はその作成を購読して通知を出す。
@MainActor
@Observable
final class AttentionNotifier {
    static let shared = AttentionNotifier()

    enum State: Equatable {
        /// 設定で切っている。
        case off
        /// この起動では使えない（エンタイトルメントが無い等）。
        case unavailable(String)
        case active(AttentionNoticeSync.Status)
    }

    private(set) var enabled: Bool
    private(set) var state: State = .off

    @ObservationIgnored private var model: ChatModel?
    @ObservationIgnored private var planner = AttentionNoticePlanner(macName: RemoteAccessController.computerName())
    @ObservationIgnored private var sync: AttentionNoticeSync?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let availability: CloudKitAvailability

    private static let enabledKey = "attentionNotice.enabled"
    /// 要対応の移り変わりを見る間隔（待ち時間の数え方の細かさ）。
    static let interval: Duration = .seconds(1)

    private init() {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        availability = CloudKitAvailability.current()
    }

    func start(_ model: ChatModel) {
        self.model = model
        guard timer == nil else { return }
        if case .available = availability {
            sync = AttentionNoticeSync(store: CloudKitNoticeStore(), ledger: UserDefaultsNoticeLedger())
        }
        refreshState()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if !on {
            // 切ったら、置いてある知らせも引き上げる（次に入れた時に古い要対応を知らせ直さないよう数え直す）。
            planner = AttentionNoticePlanner(macName: planner.macName)
            sync?.withdrawAll()
        }
        refreshState()
    }

    private func tick() async {
        guard let sync else { return }
        // 監視が止まっている間の一覧は古いので、要対応の移り変わりとして読まない。
        if enabled, let model, model.store.connection.isConnected {
            sync.submit(planner.update(candidates(model), now: Date().timeIntervalSince1970 * 1000))
        }
        await sync.tick()
        refreshState()
    }

    private func candidates(_ model: ChatModel) -> [AttentionCandidate] {
        model.rooms.compactMap { room in
            AttentionNoticeSource.candidate(roomId: room.id.string, sessionId: room.sessionId, name: room.name, status: room.status,
                                            ended: room.hosted?.end != nil, statusDetail: room.snapshot?.statusDetail,
                                            permissionToolNames: model.monitorPermissions(for: room).map(\.toolName))
        }
    }

    private func refreshState() {
        let next: State
        if case .unavailable(let reason) = availability {
            next = .unavailable(reason)
        } else if !enabled {
            next = .off
        } else {
            next = .active(sync?.status ?? .idle)
        }
        if next != state { state = next }
    }
}
