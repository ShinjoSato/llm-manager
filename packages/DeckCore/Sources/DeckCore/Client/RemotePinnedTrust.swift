import Foundation
import Security

/// サーバー証明書を指紋でピン留めし、リダイレクトは追わない URLSession の delegate。CA の検証はしない（自己署名のため）。
/// セッションにも要求ごと（`data(for:delegate:)`）にも付けられる。要求ごとに付けると、その要求の不一致だけが分かる。
public final class RemotePinnedSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public let pin: String
    private let lock = NSLock()
    private var mismatched = false
    /// 不一致を伝える先（要求ごとの delegate から、セッションの delegate へ）。
    private let parent: RemotePinnedSessionDelegate?

    public init(pin: String, reportingTo parent: RemotePinnedSessionDelegate? = nil) {
        self.pin = RemotePinning.normalize(pin)
        self.parent = parent
        super.init()
    }

    private func markMismatched() {
        lock.withLock { mismatched = true }
        parent?.markMismatched()
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

    // セッション単位の版を持たないので、証明書の確認も要求ごとの版に来る（要求に付けた delegate が先に受ける）。
    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch Self.verdict(authenticationMethod: space.authenticationMethod, serverTrust: space.serverTrust, pin: pin) {
        case .notServerTrust:
            completionHandler(.performDefaultHandling, nil)
        case .trusted:
            completionHandler(.useCredential, space.serverTrust.map(URLCredential.init(trust:)))
        case .mismatch:
            markMismatched()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// トークンを他所へ運ばせないため、リダイレクトは追わずに 30x をそのまま返す。
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    /// この delegate が受けた確認で指紋の不一致があったか（取り消しの理由を見分けるため）。
    public var hasMismatched: Bool {
        lock.withLock { mismatched }
    }
}
