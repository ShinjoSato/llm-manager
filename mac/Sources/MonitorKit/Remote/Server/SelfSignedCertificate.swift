import CryptoKit
import Foundation
import Security

/// 最小限の DER（X.509 を組むのに要る分だけ）。
enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        out.append(length(content.count))
        out.append(content)
        return out
    }

    static func length(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 {
            bytes.insert(UInt8(v & 0xff), at: 0)
            v >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func sequence(_ parts: Data...) -> Data { tlv(0x30, parts.reduce(Data(), +)) }
    static func set(_ parts: Data...) -> Data { tlv(0x31, parts.reduce(Data(), +)) }

    /// 正の整数（先頭ビットが立っていれば 0 を足して負に読まれないようにする）。
    static func integer(_ bytes: Data) -> Data {
        var trimmed = Data(bytes.drop { $0 == 0 })
        if trimmed.isEmpty { trimmed = Data([0]) }
        if trimmed.first! & 0x80 != 0 { trimmed.insert(0, at: 0) }
        return tlv(0x02, trimmed)
    }

    static func integer(_ value: Int) -> Data {
        var bytes: [UInt8] = []
        var v = value
        repeat {
            bytes.insert(UInt8(v & 0xff), at: 0)
            v >>= 8
        } while v > 0
        return integer(Data(bytes))
    }

    static func oid(_ arcs: [UInt]) -> Data {
        var body = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7f)]
            var v = arc >> 7
            while v > 0 {
                chunk.insert(UInt8(v & 0x7f) | 0x80, at: 0)
                v >>= 7
            }
            body.append(contentsOf: chunk)
        }
        return tlv(0x06, body)
    }

    static func utf8String(_ s: String) -> Data { tlv(0x0c, Data(s.utf8)) }
    static func bitString(_ bytes: Data) -> Data { tlv(0x03, Data([0]) + bytes) }
    static func octetString(_ bytes: Data) -> Data { tlv(0x04, bytes) }
    static func boolean(_ v: Bool) -> Data { tlv(0x01, Data([v ? 0xff : 0x00])) }
    static func explicit(_ tag: UInt8, _ content: Data) -> Data { tlv(0xa0 | tag, content) }

    /// 2049 年までは UTCTime、それ以降は GeneralizedTime（RFC 5280 の決まり）。
    static func time(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year!
        let rest = String(format: "%02d%02d%02d%02d%02dZ", c.month!, c.day!, c.hour!, c.minute!, c.second!)
        if year < 2050 { return tlv(0x17, Data((String(format: "%02d", year % 100) + rest).utf8)) }
        return tlv(0x18, Data((String(format: "%04d", year) + rest).utf8))
    }
}

/// mac アプリが自分で作る TLS の証明書（P-256 / ECDSA-SHA256 の自己署名）。iPhone は指紋でピン留めする。
public enum SelfSignedCertificate {
    static let ecPublicKey: [UInt] = [1, 2, 840, 10045, 2, 1]
    static let prime256v1: [UInt] = [1, 2, 840, 10045, 3, 1, 7]
    static let ecdsaWithSHA256: [UInt] = [1, 2, 840, 10045, 4, 3, 2]
    static let commonName: [UInt] = [2, 5, 4, 3]
    static let basicConstraints: [UInt] = [2, 5, 29, 19]
    static let keyUsage: [UInt] = [2, 5, 29, 15]
    static let extKeyUsage: [UInt] = [2, 5, 29, 37]
    static let serverAuth: [UInt] = [1, 3, 6, 1, 5, 5, 7, 3, 1]

    /// 証明書（DER）を作る。期限切れで繋がらなくなるのを避けるため長めにする（信頼は指紋で決めるので期限には頼らない）。
    public static func make(key: P256.Signing.PrivateKey, commonName: String, notBefore: Date = Date(),
                            validity: TimeInterval = 20 * 365 * 24 * 3600) throws -> Data {
        var serial = Data(count: 16)
        _ = serial.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        serial[0] &= 0x7f
        let algorithm = DER.sequence(DER.oid(ecdsaWithSHA256))
        let name = DER.sequence(DER.set(DER.sequence(DER.oid(Self.commonName), DER.utf8String(commonName))))
        let spki = DER.sequence(DER.sequence(DER.oid(ecPublicKey), DER.oid(prime256v1)),
                                DER.bitString(key.publicKey.x963Representation))
        let extensions = DER.sequence(
            DER.sequence(DER.oid(basicConstraints), DER.boolean(true), DER.octetString(DER.sequence())),
            // digitalSignature だけ（使わない 7 ビットを示す 0x07 + 0x80）。
            DER.sequence(DER.oid(keyUsage), DER.boolean(true), DER.octetString(DER.tlv(0x03, Data([0x07, 0x80])))),
            DER.sequence(DER.oid(extKeyUsage), DER.octetString(DER.sequence(DER.oid(serverAuth))))
        )
        let tbs = DER.sequence(
            DER.explicit(0, DER.integer(2)),
            DER.integer(serial),
            algorithm,
            name,
            DER.sequence(DER.time(notBefore.addingTimeInterval(-3600)), DER.time(notBefore.addingTimeInterval(validity))),
            name,
            spki,
            DER.explicit(3, extensions)
        )
        let signature = try key.signature(for: tbs).derRepresentation
        return DER.sequence(tbs, algorithm, DER.bitString(signature))
    }
}

/// TLS の鍵と証明書。ファイル（0600）に置き、読み込む時に SecIdentity を手元で組む（キーチェーンは使わない）。
public struct TLSIdentityFiles: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    var keyURL: URL { directory.appendingPathComponent("tls-key.bin") }
    var certificateURL: URL { directory.appendingPathComponent("tls-cert.der") }

    public struct Loaded: @unchecked Sendable {
        public let identity: SecIdentity
        public let certificateDER: Data
        public var fingerprint: String { RemotePinning.fingerprint(of: certificateDER) }
        public var serverIdentity: TLSServerIdentity { TLSServerIdentity(identity) }
    }

    public enum Failure: Error, Equatable {
        case invalidFiles
    }

    /// 読み込む。無ければ作って保存する。読めない・鍵と証明書が合わない時は作り直す（ペアリング済みの端末は繋がらなくなる）。
    public func loadOrCreate(commonName: String = "claude-deck") throws -> Loaded {
        if let loaded = try? load() { return loaded }
        return try create(commonName: commonName)
    }

    public func load() throws -> Loaded {
        let keyData = try Data(contentsOf: keyURL)
        let der = try Data(contentsOf: certificateURL)
        guard let identity = Self.identity(keyX963: keyData, certificateDER: der) else { throw Failure.invalidFiles }
        return Loaded(identity: identity, certificateDER: der)
    }

    /// 新しく作って保存する（作り直すと指紋が変わり、端末はペアリングし直しになる）。
    public func create(commonName: String = "claude-deck") throws -> Loaded {
        let key = P256.Signing.PrivateKey()
        let der = try SelfSignedCertificate.make(key: key, commonName: commonName)
        guard let identity = Self.identity(keyX963: key.x963Representation, certificateDER: der) else { throw Failure.invalidFiles }
        try SecureFile.write(key.x963Representation, to: keyURL)
        try SecureFile.write(der, to: certificateURL)
        return Loaded(identity: identity, certificateDER: der)
    }

    static func identity(keyX963: Data, certificateDER: Data) -> SecIdentity? {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                                           kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                                           kSecAttrKeySizeInBits: 256]
        guard let key = SecKeyCreateWithData(keyX963 as CFData, attributes as CFDictionary, nil),
              let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else { return nil }
        // 鍵が証明書の公開鍵と合わなければ nil。
        return SecIdentityCreate(nil, certificate, key)
    }
}
