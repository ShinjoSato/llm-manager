import DeckCore
import Foundation
import Security

/// ペアリング（接続先・ピン留めした指紋・端末トークン）をキーチェーンに置く。
/// この端末だけ・起動後に一度ロック解除した後なら読める（裏から戻った時に画面ロック中でも張り直すため。iCloud やバックアップで他の端末へ渡さない）。
struct PairingKeychain {
    var service = PairingKeychain.serviceName(suffix: "pairing")
    var account = "default"

    enum Failure: Error, Equatable {
        case status(OSStatus)
    }

    /// バンドル ID から作る（バンドル ID が同じなら保存済みのペアリングを読める）。
    static func serviceName(suffix: String, bundle: Bundle = .main) -> String {
        "\(bundle.bundleIdentifier ?? "claude-deck.ios").\(suffix)"
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() -> RemotePairing? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(RemotePairing.self, from: data)
    }

    func save(_ pairing: RemotePairing) throws {
        let data = try JSONEncoder().encode(pairing)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { $1 }
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.status(added) }
        } else if status != errSecSuccess {
            throw Failure.status(status)
        }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
