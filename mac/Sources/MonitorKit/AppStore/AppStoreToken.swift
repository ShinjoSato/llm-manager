import CryptoKit
import Foundation

/// App Store Connect API の ES256 の JWT。
public enum AppStoreJWT {
    public static let audience = "appstoreconnect-v1"
    /// Apple の上限（20 分）より短くする。
    public static let lifetime: TimeInterval = 15 * 60
    public static let maxLifetime: TimeInterval = 20 * 60

    /// `lifetime` は 20 分を超えない。署名は raw（r||s）表現。
    public static func make(credentials: AppStoreCredentials, now: Date = Date(), lifetime: TimeInterval = lifetime) throws -> String {
        let issuedAt = Int(now.timeIntervalSince1970)
        let span = Int(min(max(lifetime, 1), maxLifetime))
        let header = try canonicalJSON(["alg": "ES256", "kid": credentials.keyID, "typ": "JWT"])
        let payload = try canonicalJSON(["iss": credentials.issuerID, "iat": issuedAt, "exp": issuedAt + span, "aud": audience])
        let signingInput = base64URL(header) + "." + base64URL(payload)
        let signature = try credentials.privateKey.signature(for: Data(signingInput.utf8))
        return signingInput + "." + base64URL(signature.rawRepresentation)
    }

    static func canonicalJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decodeBase64URL(_ text: String) -> Data? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        return Data(base64Encoded: base)
    }
}

/// 発行した JWT を期限の少し前まで使い回す（要求ごとに署名し直さない）。
public struct AppStoreTokenCache: Sendable {
    /// 期限のこれだけ前に作り直す（時計のずれと通信の時間の分）。
    static let margin: TimeInterval = 60

    private var token: String?
    private var expires: Date = .distantPast

    public init() {}

    public mutating func token(credentials: AppStoreCredentials, now: Date = Date()) throws -> String {
        if let token, now < expires.addingTimeInterval(-Self.margin) { return token }
        let made = try AppStoreJWT.make(credentials: credentials, now: now)
        token = made
        expires = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970)).addingTimeInterval(AppStoreJWT.lifetime)
        return made
    }

    public mutating func clear() {
        token = nil
        expires = .distantPast
    }
}
