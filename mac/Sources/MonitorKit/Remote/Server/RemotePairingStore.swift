import CryptoKit
import Foundation
import Security

/// QR に出す一時トークン。
public struct PairingTicket: Sendable, Equatable {
    public let token: String
    public let expiresAt: Date
}

/// ペアリング済みの端末の記録。トークンは SHA-256 のハッシュだけを持つ。
struct StoredDevice: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var pairedAt: Double
    var lastUsedAt: Double?
    var tokenHash: String

    var publicValue: RemoteDevice { RemoteDevice(id: id, name: name, pairedAt: pairedAt, lastUsedAt: lastUsedAt) }
}

/// ペアリング（一時トークン → 端末ごとの長期トークン）と端末一覧。どのスレッドからでも呼べる。
/// 一覧は `devices.json`（0600）に置く。
public final class RemotePairingStore: @unchecked Sendable {
    /// 一時トークンの寿命。
    public static let ticketLifetime: TimeInterval = 5 * 60
    /// 持てる端末の数。
    public static let maxDevices = 20
    /// 最後に使った時刻を書き出す間隔（毎リクエスト書かないため）。
    static let lastUsedWriteInterval: TimeInterval = 60

    private let lock = NSLock()
    private let fileURL: URL
    private let now: @Sendable () -> Date
    private var devicesById: [String: StoredDevice] = [:]
    private var ticket: (hash: Data, expiresAt: Date)?
    private var lastWrite: Date = .distantPast
    /// 最後の書き出しの失敗（成功すれば nil）。取り消しが保存されていないと再起動で端末が戻るので、書き直しを続ける。
    private var writeFailure: String?
    /// 一覧が変わった時（ペアリング・取り消し・最後に使った時刻・書き出しの失敗）に呼ぶ。錠の外で呼ぶ。
    private var changeHandler: (@Sendable () -> Void)?

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        fileURL = directory.appendingPathComponent("devices.json")
        self.now = now
        if let list = JSONFile.read([StoredDevice].self, from: fileURL) {
            devicesById = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    public func setChangeHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { changeHandler = handler }
    }

    /// 新しい一時トークンを出す（前のものは使えなくなる）。
    public func startPairing(lifetime: TimeInterval = RemotePairingStore.ticketLifetime) -> PairingTicket {
        let token = Self.randomToken()
        let expiresAt = now().addingTimeInterval(lifetime)
        lock.withLock { ticket = (Self.hash(token), expiresAt) }
        return PairingTicket(token: token, expiresAt: expiresAt)
    }

    public func cancelPairing() {
        lock.withLock { ticket = nil }
    }

    /// 一時トークンを待っているか（期限内か）。
    public var isPairingOpen: Bool {
        lock.withLock { ticket.map { $0.expiresAt > now() } ?? false }
    }

    public enum PairOutcome: Sendable, Equatable {
        case paired(RemoteDevice, token: String)
        /// 一時トークンが違う・期限切れ・使用済み。
        case rejected
        /// 端末が多すぎる。
        case full
    }

    /// 一時トークンを長期トークンに引き換える。当たれば使い切る。外れでは消さず、総当たりは `RemoteAuthThrottle` の回数制限で止める。
    public func pair(token: String, deviceName: String) -> PairOutcome {
        let presented = Self.hash(token)
        let result: PairOutcome = lock.withLock {
            guard let current = ticket, current.expiresAt > now(), RemotePinning.constantTimeEqual(current.hash, presented) else {
                if let current = ticket, current.expiresAt <= now() { ticket = nil }
                return .rejected
            }
            ticket = nil
            guard devicesById.count < Self.maxDevices else { return .full }
            let deviceToken = Self.randomToken()
            let device = StoredDevice(id: UUID().uuidString.lowercased(), name: Self.sanitizedName(deviceName),
                                      pairedAt: now().timeIntervalSince1970 * 1000, lastUsedAt: nil,
                                      tokenHash: Self.hash(deviceToken).hexString)
            devicesById[device.id] = device
            try? persistLocked()
            return .paired(device.publicValue, token: deviceToken)
        }
        if case .paired = result { notifyChange() }
        return result
    }

    /// 端末トークンを確かめる。通れば最後に使った時刻を進める。
    public func authenticate(token: String) -> RemoteDevice? {
        guard !token.isEmpty, token.utf8.count <= 128 else { return nil }
        let hash = Self.hash(token).hexString
        var changed = false
        let device: RemoteDevice? = lock.withLock {
            guard var device = devicesById.values.first(where: { RemotePinning.constantTimeEqual(Data($0.tokenHash.utf8), Data(hash.utf8)) }) else {
                return nil
            }
            let at = now()
            let previous = device.lastUsedAt
            device.lastUsedAt = at.timeIntervalSince1970 * 1000
            devicesById[device.id] = device
            // 一覧の「最後に使った時刻」は分単位で足りる。
            if previous.map({ at.timeIntervalSince1970 * 1000 - $0 >= Self.lastUsedWriteInterval * 1000 }) ?? true {
                changed = true
                if at.timeIntervalSince(lastWrite) >= Self.lastUsedWriteInterval { try? persistLocked() }
            }
            return device.publicValue
        }
        if changed { notifyChange() }
        return device
    }

    public func devices() -> [RemoteDevice] {
        lock.withLock { devicesById.values.map(\.publicValue) }.sorted { $0.pairedAt < $1.pairedAt }
    }

    public func device(id: String) -> RemoteDevice? {
        lock.withLock { devicesById[id]?.publicValue }
    }

    /// 端末を取り消す。以降そのトークンは通らない（書き出しに失敗しても、メモリ上の取り消しは保ったままエラーを投げる）。
    @discardableResult
    public func revoke(id: String) throws -> Bool {
        var failure: Error?
        let removed = lock.withLock {
            guard devicesById.removeValue(forKey: id) != nil else { return false }
            do { try persistLocked() } catch { failure = error }
            return true
        }
        if removed { notifyChange() }
        if let failure { throw failure }
        return removed
    }

    /// 書き出しに失敗したままなら（nil でなければ）その理由。
    public var persistFailure: String? {
        lock.withLock { writeFailure }
    }

    /// 失敗した書き出しをやり直す。書けていれば（やり直す必要が無ければ）true。
    @discardableResult
    public func retryPersist() -> Bool {
        let (ok, changed): (Bool, Bool) = lock.withLock {
            guard writeFailure != nil else { return (true, false) }
            do {
                try persistLocked()
                return (true, true)
            } catch {
                return (false, false)
            }
        }
        if changed { notifyChange() }
        return ok
    }

    /// 終了時に最後に使った時刻を書き残す。
    public func flush() {
        lock.withLock { try? persistLocked() }
    }

    private func persistLocked() throws {
        let list = devicesById.values.sorted { $0.pairedAt < $1.pairedAt }
        do {
            try SecureFile.writeJSON(list, to: fileURL, restrictDirectory: true, formatting: [])
            writeFailure = nil
            lastWrite = now()
        } catch {
            writeFailure = String(describing: error)
            throw error
        }
    }

    private func notifyChange() {
        let handler = lock.withLock { changeHandler }
        handler?()
    }

    // MARK: - 補助

    /// 256 bit の乱数を URL に載せられる base64（`+/=` を使わない）で。
    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "乱数を取れない")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ token: String) -> Data { Data(SHA256.hash(data: Data(token.utf8))) }

    /// 一覧に出す名前。制御文字を落とし、長すぎれば切る。
    static func sanitizedName(_ raw: String) -> String {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(cleaned.prefix(64))
        return limited.isEmpty ? "iPhone" : limited
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
