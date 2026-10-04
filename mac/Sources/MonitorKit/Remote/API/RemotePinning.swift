import CryptoKit
import Foundation
import Security

/// 自己署名の証明書を QR の指紋でピン留めする（iPhone 側の検証にも使う）。
/// CA の検証はしない（自己署名なので通らない）。指紋が一致した時だけ信頼する。
public enum RemotePinning {
    /// 証明書（DER）の SHA-256 を小文字 16 進で。
    public static func fingerprint(of certificateDER: Data) -> String {
        SHA256.hash(data: certificateDER).map { String(format: "%02x", $0) }.joined()
    }

    /// 相手が出した末端の証明書の指紋。
    public static func leafFingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        return fingerprint(of: SecCertificateCopyData(leaf) as Data)
    }

    /// 末端の証明書がピン留めした指紋と一致するか（大文字小文字・`:` 区切りは無視）。
    public static func matches(_ trust: SecTrust, pinned: String) -> Bool {
        guard let actual = leafFingerprint(of: trust) else { return false }
        return constantTimeEqual(Data(actual.utf8), Data(normalize(pinned).utf8))
    }

    /// 表示用（`AB:CD:...`）の指紋も受け付ける。
    public static func normalize(_ fingerprint: String) -> String {
        fingerprint.lowercased().filter { $0 != ":" && !$0.isWhitespace }
    }

    /// 表示用に 2 桁ずつ `:` で区切る。
    public static func display(_ fingerprint: String) -> String {
        let hex = Array(normalize(fingerprint).uppercased())
        return stride(from: 0, to: hex.count, by: 2).map { String(hex[$0..<min($0 + 2, hex.count)]) }.joined(separator: ":")
    }

    /// 中身によらず同じ時間で比べる（一致した桁数を時間から推測させない）。
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
