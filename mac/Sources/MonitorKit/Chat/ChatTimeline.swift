import Foundation

/// 会話画面の 1 行。発話（user / assistant）と、その下に畳むツール呼び出し群。
public struct ChatEntry: Sendable, Equatable, Identifiable {
    public enum Role: Sendable, Equatable { case user, assistant, toolsOnly, relay }

    public var id: String
    public var role: Role
    public var text: String
    public var at: Double?
    public var tools: [TranscriptItem]
    /// `.relay` の時だけ。アプリから送った伝言（送信状態を出すため）。
    public var relay: RelayNote?

    public init(id: String, role: Role, text: String, at: Double?, tools: [TranscriptItem], relay: RelayNote? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
        self.tools = tools
        self.relay = relay
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

    /// transcript に、アプリから送った伝言を時刻順に差し込む。transcript 側に写しがあればそちらは出さない。
    public static func entries(from items: [TranscriptItem], notes: [RelayNote]) -> [ChatEntry] {
        guard !notes.isEmpty else { return entries(from: items) }
        var result = entries(from: RelayNotes.removingEchoes(from: items, notes: notes))
        var lowerBound = 0
        for note in notes.sorted(by: { $0.sentAt < $1.sentAt }) {
            let entry = ChatEntry(id: "relay:\(note.id)", role: .relay, text: note.text, at: note.sentAt, tools: [], relay: note)
            // 時刻の無い行は前後関係が分からないので飛ばし、送信より後の最初の発話の前に置く。
            let index = result[lowerBound...].firstIndex { ($0.at ?? -.infinity) > note.sentAt } ?? result.endIndex
            result.insert(entry, at: index)
            lowerBound = index + 1
        }
        return result
    }

    /// 実行中とみなすツールの id。稼働中で、最後の要素がツール呼び出しならそれ（後続の発話がまだ無い）。
    public static func runningToolId(items: [TranscriptItem], status: SessionStatus?) -> String? {
        guard status == .working || status == .permission, let last = items.last, last.kind == .tool else { return nil }
        return last.id
    }
}
