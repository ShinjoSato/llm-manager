import Foundation

/// iPhone から送る操作の種類（結果の言い回しを変えるため）。
public enum RemoteOperationKind: Sendable, Equatable {
    case permission
    case menu
    case menuTab
    case menuDismiss
    case message
    case relay
}

/// 操作の結果を人に見せる言葉にする。
public enum RemoteResultText {
    /// 成功で黙ってよいものは nil（カードが消える・吹き出しが出ることで分かる）。
    public static func text(for result: RemoteActionResult, operation: RemoteOperationKind) -> String? {
        if result.ok {
            switch result.code {
            case "answered": return "既に答えています（同じ確認には送り直していません）。"
            case "toggled": return "チェックを切り替えました。"
            default: return nil
            }
        }
        return failureText(code: result.code, operation: operation) ?? result.message ?? "うまくいきませんでした（\(result.code)）。"
    }

    static func failureText(code: String, operation: RemoteOperationKind) -> String? {
        switch code {
        case "gone":
            return operation == .message || operation == .relay
                ? "送り先のセッションがもうありません。"
                : "この確認はもう出ていません（mac か端末で答えたか、取り下げられました）。"
        case "changed":
            return "mac 側の表示が替わっていました。最新の内容を確かめてからもう一度押してください。"
        case "busy":
            return "直前の操作を mac で送っている最中です。終わってからもう一度。"
        case "timeout":
            return "mac での操作が 30 秒で戻りませんでした。後から反映されることがあるので、送り直す前に画面の様子を確かめてください。"
        case "ended":
            return "claude が終了しています。"
        case "app_unavailable":
            return "mac アプリの準備ができていません（起動直後か終了中）。少し待ってから。"
        case "failed":
            return operation == .relay
                ? "伝言を届けられませんでした（受け手の受信箱が見つかりません）。"
                : "mac から Claude Code に答えを届けられませんでした。"
        case "not_found":
            return "このルームはもうありません。"
        case "invalid":
            return operation == .message || operation == .relay ? "送れない本文です（空か長すぎます）。" : "要求の形が正しくありません。"
        case "unavailable":
            return operation == .menu
                ? "文字を入力する選択肢はここからは選べません。キャンセルしてから入力欄で伝えてください。"
                : "このルームには今は送れません。"
        case "confirm_required":
            return "取り消すと claude が終了します。確認してから押してください。"
        case "blocked_permission":
            return "端末で権限の確認が出ているので送りませんでした。先に許可 / 拒否してください。"
        case "blocked_menu":
            return "端末で選択肢が出ているので送りませんでした（Enter が選択の確定になるため）。先に選択肢に答えてください。"
        case "leftover":
            return "端末の入力欄に前の書きかけが残っているので送りませんでした。mac で入力欄を空にしてください。"
        case "aborted":
            return "送る途中で端末の様子が変わったので、送るのをやめました。"
        case "stuck", "vanished", "settling":
            return "端末の選択肢の動きを確かめられなかったので、途中でやめました。画面の様子を確かめてください。"
        default:
            return nil
        }
    }
}

/// 繋がらない・切れた理由と、ユーザーにしてほしいこと。
public struct RemoteIssue: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// mac に届かない（別の Wi-Fi・スリープ・口が無効・ローカルネットワークの許可）。
        case unreachable
        /// iPhone の「ローカルネットワーク」の許可が無い（経路の判定で確かめた時だけ）。
        case localNetworkDenied
        /// iPhone が Wi-Fi につながっていない（経路の判定で確かめた時だけ）。
        case offline
        /// 回数制限・接続数の上限で切られた。
        case throttled
        /// 証明書の指紋が違う。
        case pinMismatch
        /// 端末の登録が取り消された。
        case revoked
        /// API の版が合わない・応答が読めない。
        case incompatible
        case other
    }

    public var kind: Kind
    public var title: String
    public var detail: String
    /// 再ペアリングしないと直らない。
    public var needsPairing: Bool { kind == .pinMismatch || kind == .revoked }
    /// iPhone の設定を開いてもらうと直る。
    public var needsSettings: Bool { kind == .localNetworkDenied }

    public init(kind: Kind, title: String, detail: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }

    public static let unreachableHelp = """
    ・iPhone と Mac が同じ Wi-Fi につながっているか
    ・Mac がスリープしていないか（蓋を閉じていないか）
    ・Mac の claude-deck で「iPhone 連携」が有効か（別のネットワークでは止まっています）
    ・iPhone の 設定 → プライバシーとセキュリティ → ローカルネットワーク で claude-deck が許可されているか
    """

    public static let localNetworkDenied = RemoteIssue(
        kind: .localNetworkDenied, title: "ローカルネットワークの使用が許可されていません",
        detail: "設定 → アプリ → claude-deck →『ローカルネットワーク』をオンにして、アプリに戻ってください。")

    public static let offline = RemoteIssue(
        kind: .offline, title: "Wi-Fi につながっていません", detail: "iPhone を Mac と同じ Wi-Fi につないでください。")

    /// 許可と Wi-Fi のどちらか確かめられなかった時。
    public static let ambiguousOffline = RemoteIssue(
        kind: .unreachable, title: "Mac に届きません（ローカルネットワークの許可か、Wi-Fi）",
        detail: "iPhone の「設定 → アプリ → claude-deck → ローカルネットワーク」がオンかを確かめてください。"
            + "オフならオンにしてアプリに戻ってください。\nWi-Fi につながっていない時は、Mac と同じ Wi-Fi につないでください。")

    /// 接続先への経路を確かめた結果（Network.framework の `NWPath.UnsatisfiedReason` を写したもの）。
    public enum PathReason: Sendable, Equatable {
        case localNetworkDenied
        /// 使える経路が無い。
        case notAvailable
        /// 経路はある（つながった）・時間切れ・その他の理由。何も言い切れない。
        case inconclusive
    }

    /// このエラーだけでは許可と Wi-Fi のどちらが原因か分からない（iOS はローカルネットワークの許可が無い時も Wi-Fi 上で -1009 を返す）。
    public static func needsPathCheck(_ error: Error) -> Bool {
        guard case .transport(let code)? = error as? RemoteClientError else { return false }
        return [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(code)
    }

    /// エラーと、経路の確かめ（`path`）・端末全体の Wi-Fi の判定（`onWiFi`。分からなければ nil）から理由を決める。
    public static func diagnose(_ error: Error, path: PathReason?, onWiFi: Bool?) -> RemoteIssue {
        guard needsPathCheck(error) else { return from(error) }
        if path == .localNetworkDenied { return localNetworkDenied }
        if path == .notAvailable || onWiFi == false { return offline }
        return ambiguousOffline
    }

    public static func from(_ error: Error) -> RemoteIssue {
        guard let error = error as? RemoteClientError else {
            return RemoteIssue(kind: .other, title: "接続できませんでした", detail: error.localizedDescription)
        }
        switch error {
        case .pinMismatch:
            return RemoteIssue(kind: .pinMismatch, title: "証明書が一致しません",
                               detail: "ペアリングした時と違う証明書が出されました。Mac で証明書が作り直されたか、別の相手です。Mac で新しい QR を出して、もう一度ペアリングしてください。")
        case .http(status: 401, let code, _):
            if code == "pairing_rejected" {
                return RemoteIssue(kind: .other, title: "ペアリングできませんでした",
                                   detail: "QR のコードが違うか、期限切れか、使用済みです。Mac で新しい QR を出してください。")
            }
            return RemoteIssue(kind: .revoked, title: "この iPhone の登録が取り消されています",
                               detail: "Mac の「iPhone 連携」で取り消されたか、ペアリングし直されました。もう一度ペアリングしてください。")
        case .http(status: 429, _, _):
            return RemoteIssue(kind: .throttled, title: "Mac が一時的に接続を断っています",
                               detail: "失敗が続いたか、開いている接続が多すぎます。数分おいてから自動でつなぎ直します。")
        case .http(status: 409, "too_many_devices", let message):
            return RemoteIssue(kind: .other, title: "ペアリングできる端末の数を超えています",
                               detail: message ?? "Mac の「iPhone 連携」で使っていない端末を取り消してください。")
        case .http(status: 503, _, let message):
            return RemoteIssue(kind: .other, title: "Mac アプリの準備ができていません", detail: message ?? "少し待ってからつなぎ直します。")
        case .http(let status, _, let message):
            return RemoteIssue(kind: .other, title: "Mac から失敗が返りました（\(status)）", detail: message ?? "")
        case .transport(let code):
            switch code {
            case .networkConnectionLost, .secureConnectionFailed:
                // 接続元が塞がれている間、mac は受け入れた時点で切る（TLS の握手もさせない）。
                return RemoteIssue(kind: .unreachable, title: "Mac との接続が切れたか、つながりませんでした",
                                   detail: "通信が成り立たないか、途中で切れました。失敗が続いて Mac が一時的に接続を断っている場合は、数分で戻ります。\n" + unreachableHelp)
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return ambiguousOffline
            default:
                return RemoteIssue(kind: .unreachable, title: "Mac に接続できません", detail: unreachableHelp)
            }
        case .decoding, .streamOverflow:
            return RemoteIssue(kind: .incompatible, title: "Mac からの応答を読めませんでした",
                               detail: "iPhone アプリと Mac アプリの版が合っていない可能性があります。両方を最新にしてください。")
        case .invalidAddress:
            return RemoteIssue(kind: .incompatible, title: "接続先の形が正しくありません", detail: "もう一度ペアリングしてください。")
        }
    }
}

/// つなぎ直すまでの待ち（指数的に伸ばし、上限で止める。同時に張り直さないよう揺らす）。
public struct RemoteBackoff: Sendable, Equatable {
    public var base: TimeInterval
    public var cap: TimeInterval
    public var attempt = 0

    public init(base: TimeInterval = 1, cap: TimeInterval = 30) {
        self.base = base
        self.cap = cap
    }

    /// 次の待ち時間。`jitter` は 0...1（0.5 で揺れなし）。
    public mutating func next(jitter: Double = Double.random(in: 0...1)) -> TimeInterval {
        let raw = min(cap, base * pow(2, Double(min(attempt, 16))))
        attempt += 1
        return max(0.2, raw * (0.8 + 0.4 * jitter))
    }

    /// 回数制限で切られた時（5 分の窓が明けるまで）は長めに待つ。
    public static func throttledDelay(jitter: Double = Double.random(in: 0...1)) -> TimeInterval {
        60 * (1 + jitter)
    }

    public mutating func reset() { attempt = 0 }
}
