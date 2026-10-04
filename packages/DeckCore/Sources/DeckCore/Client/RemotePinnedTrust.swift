import Foundation
import Security

/// サーバー証明書を指紋でピン留めする URLSession の delegate。CA の検証はしない（自己署名のため）。
public final class RemotePinnedSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    public let pin: String
    private let lock = NSLock()
    private var mismatched = false

    public init(pin: String) {
        self.pin = RemotePinning.normalize(pin)
        super.init()
    }

    public enum Verdict: Equatable, Sendable {
        /// サーバー証明書の確認ではない（既定の処理に任せる）。
        case notServerTrust
        case trusted
        case mismatch
    }

    /// 認証の求めに対する判定。指紋が一致した時だけ信頼する。
    public static func verdict(authenticationMethod: String, serverTrust: SecTrust?, pin: String) -> Verdict {
        guard authenticationMethod == NSURLAuthenticationMethodServerTrust else { return .notServerTrust }
        guard let serverTrust, RemotePinning.matches(serverTrust, pinned: pin) else { return .mismatch }
        return .trusted
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch Self.verdict(authenticationMethod: space.authenticationMethod, serverTrust: space.serverTrust, pin: pin) {
        case .notServerTrust:
            completionHandler(.performDefaultHandling, nil)
        case .trusted:
            completionHandler(.useCredential, space.serverTrust.map(URLCredential.init(trust:)))
        case .mismatch:
            lock.withLock { mismatched = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// 指紋の不一致があったか（取り消しの理由を見分けるため）。URLSession は不一致を覚えて次から delegate を呼ばないことがあるので消さない。
    public var hasMismatched: Bool {
        lock.withLock { mismatched }
    }
}
