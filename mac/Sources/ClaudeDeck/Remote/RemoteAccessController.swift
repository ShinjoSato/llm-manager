import AppKit
import MonitorKit
import Observation
import SystemConfiguration

/// iPhone 連携の設定と口の開け閉め。既定は無効で、設定で有効にした時だけ LAN のアドレスで待ち受ける。
/// 設定は UserDefaults、証明書・端末一覧は `~/Library/Application Support/claude-deck/remote/`（`CLAUDE_DECK_REMOTE_DIR` で差し替え）。
@MainActor
@Observable
final class RemoteAccessController {
    static let shared = RemoteAccessController()

    let service: RemoteAccessService
    private(set) var enabled: Bool
    private(set) var port: Int
    /// 待ち受けるインターフェース（nil は自動: Wi-Fi / 有線を優先）。
    private(set) var interfaceName: String?
    private(set) var interfaces: [LANInterface] = []
    /// 開けない理由（インターフェースが無い等）。
    private(set) var problem: String?
    /// 有効にした時と別のネットワークにいるため止めている（確かめてから開くため）。
    private(set) var networkMismatch: NetworkMismatch?

    struct NetworkMismatch: Equatable {
        let saved: LANNetwork
        let current: LANNetwork
    }

    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// アドレスの変化（DHCP の更新・Wi-Fi の切り替え）を見る間隔。
    static let watchInterval: Duration = .seconds(10)

    private enum Keys {
        static let enabled = "remoteAccess.enabled"
        static let port = "remoteAccess.port"
        static let interface = "remoteAccess.interface"
        static let network = "remoteAccess.network"
    }

    /// 開いてよいと確かめたネットワーク。
    private var savedNetwork: LANNetwork? {
        get {
            UserDefaults.standard.data(forKey: Keys.network).flatMap { try? JSONDecoder().decode(LANNetwork.self, from: $0) }
        }
        set {
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.network)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Keys.enabled)
        let saved = defaults.integer(forKey: Keys.port)
        port = (1024...65535).contains(saved) ? saved : RemoteAPI.defaultPort
        interfaceName = defaults.string(forKey: Keys.interface)
        service = RemoteAccessService(directory: Self.directory(), transcripts: MonitorBridge.store.transcripts, control: nil,
                                      serverName: Self.computerName(), localHostName: Self.localHostName())
        interfaces = LANInterfaces.current()
    }

    static func directory(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = env["CLAUDE_DECK_REMOTE_DIR"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("claude-deck/remote", isDirectory: true)
    }

    /// 操作を受ける画面のモデル（ウィンドウを作った時に渡す）。
    func attach(_ model: ChatModel) {
        service.setControl(model)
    }

    func startIfEnabled() {
        if enabled { apply() }
    }

    func shutdown() {
        watcher?.cancel()
        watcher = nil
        service.stop()
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: Keys.enabled)
        // 有効にした時のネットワークを覚え直す（以後、別のネットワークでは自動で開かない）。
        if on { savedNetwork = nil }
        apply()
    }

    /// 別のネットワークで止めている時に、今のネットワークで開くと決めた。
    func trustCurrentNetwork() {
        guard let mismatch = networkMismatch else { return }
        savedNetwork = mismatch.current
        networkMismatch = nil
        apply()
    }

    /// 1024 未満（特権ポート）と 8766（フック・チャネルの口）は使わない。
    func setPort(_ value: Int) -> Bool {
        guard (1024...65535).contains(value), value != HookServerRoutes.defaultPort else { return false }
        guard value != port else { return true }
        port = value
        UserDefaults.standard.set(value, forKey: Keys.port)
        if enabled { restart() }
        return true
    }

    func setInterface(_ name: String?) {
        guard name != interfaceName else { return }
        interfaceName = name
        UserDefaults.standard.set(name, forKey: Keys.interface)
        // 口を選び直したのは今のネットワークで開くという判断。
        savedNetwork = nil
        if enabled { restart() }
    }

    func refreshInterfaces() {
        interfaces = LANInterfaces.current()
        if enabled { apply() }
    }

    private func restart() {
        service.stop()
        apply()
    }

    /// 設定に合わせて開け閉めする。アドレスが替わっていれば開き直し、開けなかったものは取り直す。
    private func apply() {
        interfaces = LANInterfaces.current()
        guard enabled else {
            watcher?.cancel()
            watcher = nil
            problem = nil
            networkMismatch = nil
            service.stop()
            return
        }
        startWatcher()
        guard let chosen = LANInterfaces.choose(interfaceName, from: interfaces) else {
            problem = interfaceName.map { "\($0) が見つかりません（接続が切れている可能性があります）" }
                ?? "LAN（Wi-Fi・有線）のアドレスが見つかりません"
            networkMismatch = nil
            if service.isRunning { service.stop() }
            return
        }
        let current = LANNetwork.current(for: chosen)
        let saved = savedNetwork
        switch LANNetwork.decide(saved: saved, current: current) {
        case .open:
            networkMismatch = nil
        case .remember(let network):
            savedNetwork = network
            networkMismatch = nil
        case .refuse:
            // 外出先の Wi-Fi 等で勝手に開かない。確かめてから開く。
            networkMismatch = saved.flatMap { saved in current.map { NetworkMismatch(saved: saved, current: $0) } }
            problem = "別のネットワークのため停止中"
            if service.isRunning { service.stop() }
            return
        }
        problem = nil
        let failed: Bool
        switch service.state {
        case .failed, .portInUse, .stopped: failed = true
        case .starting, .listening: failed = false
        }
        if failed || service.listeningAddress != chosen.address {
            service.start(address: chosen.address, port: port)
        }
    }

    private func startWatcher() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchInterval)
                guard let self, !Task.isCancelled, self.enabled else { return }
                self.apply()
            }
        }
    }

    // MARK: - 名前

    static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    static func localHostName() -> String? {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
    }

    // MARK: - 表示用

    var statusText: String {
        if !enabled { return "無効（iPhone からは繋がりません）" }
        if let problem { return problem }
        switch service.state {
        case .stopped: return "停止中"
        case .starting: return "開いています…"
        case .listening(let port): return "待ち受け中: \(service.listeningAddress ?? "?"):\(port)（TLS）"
        case .portInUse(let port): return "ポート \(port) は別のプロセスが使っています。別のポートにしてください"
        case .failed(let reason): return "開けません: \(reason)"
        }
    }
}
