import Foundation
import DeckCore

/// 会話の 1 項目。
enum TestItem {
    static func user(_ id: String, _ text: String, at: Double?, images: Int = 0) -> TranscriptItem {
        TranscriptItem(id: id, kind: .user, at: at, text: text, tool: nil, parentId: nil,
                       images: (0..<images).map { TranscriptImage(index: $0, mediaType: "image/png") })
    }

    static func assistant(_ id: String, at: Double?) -> TranscriptItem {
        TranscriptItem(id: id, kind: .assistant, at: at, text: id, tool: nil, parentId: nil)
    }
}
