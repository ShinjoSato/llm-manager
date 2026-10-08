import Foundation

/// 見出しのボタンが入りきらない時に「…」のメニューへ回すものを決める。
public enum HeaderOverflow {
    /// 優先度（同じなら `subpriorities`、それも同じなら右）の低いものから `hiddenCount` 個を回した時に残す位置（並びは元のまま）。
    public static func visibleIndices(priorities: [Int], subpriorities: [Int]? = nil, hiddenCount: Int) -> [Int] {
        let hidden = Set(hiddenIndices(priorities: priorities, subpriorities: subpriorities, hiddenCount: hiddenCount))
        return priorities.indices.filter { !hidden.contains($0) }
    }

    /// メニューへ回す位置（並びは元のまま）。
    public static func hiddenIndices(priorities: [Int], subpriorities: [Int]? = nil, hiddenCount: Int) -> [Int] {
        let count = min(max(hiddenCount, 0), priorities.count)
        let sub = subpriorities ?? Array(repeating: 0, count: priorities.count)
        precondition(sub.count == priorities.count, "subpriorities は priorities と同じ数")
        let order = priorities.indices.sorted { a, b in
            if priorities[a] != priorities[b] { return priorities[a] < priorities[b] }
            if sub[a] != sub[b] { return sub[a] < sub[b] }
            return a > b
        }
        return order.prefix(count).sorted()
    }
}
