import Foundation

/// 会話画面の 1 行。発話（user / assistant）と、その下に畳むツール呼び出し群。
public struct ChatEntry: Sendable, Equatable, Identifiable {
    public enum Role: Sendable, Equatable { case user, assistant, toolsOnly }

    public var id: String
    public var role: Role
    public var text: String
    public var at: Double?
    public var tools: [TranscriptItem]

    public init(id: String, role: Role, text: String, at: Double?, tools: [TranscriptItem]) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
        self.tools = tools
    }
}

public enum ChatTimeline {
    /// transcript を会話の行に組み直す。ツールは parentId の発話（無ければ直前の発話）の下に畳む。
    public static func entries(from items: [TranscriptItem]) -> [ChatEntry] {
        var entries: [ChatEntry] = []
        var indexById: [String: Int] = [:]
        for item in items {
            switch item.kind {
            case .user, .assistant:
                indexById[item.id] = entries.count
                entries.append(ChatEntry(id: item.id, role: item.kind == .user ? .user : .assistant,
                                         text: item.text ?? "", at: item.at, tools: []))
            case .tool:
                if let parent = item.parentId, let i = indexById[parent] {
                    entries[i].tools.append(item)
                } else if let last = entries.indices.last {
                    entries[last].tools.append(item)
                } else {
                    // 先頭がツールなら（履歴の途中から読んだ等）受け皿だけ作る。
                    entries.append(ChatEntry(id: "tools:\(item.id)", role: .toolsOnly, text: "", at: item.at, tools: [item]))
                }
            case .unknown:
                continue
            }
        }
        return entries
    }

    /// 実行中とみなすツールの id。稼働中で、最後の要素がツール呼び出しならそれ（後続の発話がまだ無い）。
    public static func runningToolId(items: [TranscriptItem], status: SessionStatus?) -> String? {
        guard status == .working || status == .permission, let last = items.last, last.kind == .tool else { return nil }
        return last.id
    }
}
