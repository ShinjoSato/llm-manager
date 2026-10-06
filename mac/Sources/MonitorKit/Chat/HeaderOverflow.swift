import Foundation

/// 見出しのボタンが入りきらない時に「…」のメニューへ回すものを決める。
public enum HeaderOverflow {
    /// 優先度の低いものから `hiddenCount` 個を回した時に残す位置（並びは元のまま）。同じ優先度なら右のものから回す。
    public static func visibleIndices(priorities: [Int], hiddenCount: Int) -> [Int] {
        let hidden = Set(hiddenIndices(priorities: priorities, hiddenCount: hiddenCount))
        return priorities.indices.filter { !hidden.contains($0) }
    }

    /// メニューへ回す位置（並びは元のまま）。
    public static func hiddenIndices(priorities: [Int], hiddenCount: Int) -> [Int] {
        let count = min(max(hiddenCount, 0), priorities.count)
        let order = priorities.indices.sorted { a, b in
            priorities[a] != priorities[b] ? priorities[a] < priorities[b] : a > b
        }
        return order.prefix(count).sorted()
    }
}
