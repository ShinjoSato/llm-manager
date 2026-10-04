import Foundation

/// 「あなたの返答待ち」で止まっているセッションの扱い（移植元: 旧 monitor（削除済み）の src/attention.ts）。
public enum Attention {
    /// 人の操作が要る状態。画面で強調し、待ち時間を数える対象。
    public static func needsAttention(_ status: SessionStatus?) -> Bool {
        status == .permission || status == .waiting || status == .error
    }

    /// 前のフックの待ちがまだ続いているか。フックより新しいログ活動があれば、その待ちには答えが出ている。
    public static func heldStatus(_ hookStatus: SessionStatus?, hookAt: Double, lastActivityAt: Double) -> SessionStatus? {
        lastActivityAt > hookAt ? nil : hookStatus
    }

    /// 待ち始めの時刻を更新する。要対応の間に種類が変わっても（権限待ち→入力待ち）待たされ続けているので引き継ぐ。
    public static func nextAttentionSince(prevStatus: SessionStatus?, prevSince: Double?,
                                          nextStatus: SessionStatus?, now: Double) -> Double? {
        guard needsAttention(nextStatus) else { return nil }
        if needsAttention(prevStatus), let prevSince { return prevSince }
        return now
    }

    /// 通知文「… permission to use X」から X を取り出す。形が違えば nil。
    public static func toolFromMessage(_ message: String?) -> String? {
        guard let message,
              let range = message.range(of: #"permission to use [A-Za-z0-9_.:-]+"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let matched = message[range]
        let prefixLength = "permission to use ".count
        return String(matched.dropFirst(prefixLength))
    }

    /// 権限待ちで何を聞かれているかの一行。同じツールと確かめられた時だけ、ログから読んだ直前のツールの説明を添える。
    public static func permissionDetail(toolName: String?, message: String?,
                                        currentTool: String?, currentAction: String?) -> String? {
        let tool = toolName?.isEmpty == false ? toolName : nil
        let msg = message?.isEmpty == false ? message : nil
        let base = tool ?? msg
        // 別のツールの説明を添えると、違う操作の許可を求めているように読めてしまう。
        let asked = tool ?? toolFromMessage(message)
        let action: String?
        if let currentAction, !currentAction.isEmpty, let asked, !asked.isEmpty, asked == currentTool {
            action = currentAction
        } else {
            action = nil
        }
        guard let action else { return base }
        guard let base else { return action }
        return "\(base): \(action)"
    }
}
