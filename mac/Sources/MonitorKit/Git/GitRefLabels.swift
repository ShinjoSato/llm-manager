import Foundation

/// コミットの横に出す ref の札。同じコミットのローカルとリモートは 1 枚にまとめる。
public struct GitRefLabel: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        /// 切り離された HEAD。
        case head
        case branch
        case remote
        case tag
    }

    public var kind: Kind
    public var name: String
    /// ローカルと同じ名前で同じコミットを指すリモート（「origin」）。
    public var remotes: [String]
    /// 今の HEAD のブランチ（切り離された HEAD の札も含む）。
    public var isCurrent: Bool

    public var id: String { "\(kind.rawValue)/\(name)" }

    public init(kind: Kind, name: String, remotes: [String] = [], isCurrent: Bool = false) {
        self.kind = kind
        self.name = name
        self.remotes = remotes
        self.isCurrent = isCurrent
    }

    /// 狭い欄の札に出す名前。長ければ真ん中を「…」で詰める（頭と末尾の番号を残す）。
    public func compactName(limit: Int = 16) -> String {
        guard name.count > limit, limit >= 5 else { return name }
        let tail = (limit - 1) / 2
        return String(name.prefix(limit - 1 - tail)) + "…" + String(name.suffix(tail))
    }

    /// 札の全体の名前（ホバー・読み上げ用）。
    public var fullText: String {
        switch kind {
        case .head: return "HEAD（切り離し）"
        case .branch:
            let head = isCurrent ? "HEAD → " : ""
            return remotes.isEmpty ? head + name : head + name + "（" + remotes.map { "\($0)/\(name)" }.joined(separator: "・") + " も同じ）"
        case .remote: return name
        case .tag: return "タグ " + name
        }
    }
}

public enum GitRefLabels {
    /// コミットごとの札。並びは 今の HEAD → ブランチ → リモート → タグ（それぞれ名前順）。
    public static func labels(refs: [GitRef], headRef: String?, headOid: String?) -> [String: [GitRefLabel]] {
        var result: [String: [GitRefLabel]] = [:]
        let byTarget = Dictionary(grouping: refs, by: \.target)
        for (target, group) in byTarget {
            let locals = group.filter { $0.kind == .localBranch }
            let localNames = Set(locals.map(\.name))
            var labels: [GitRefLabel] = []
            for ref in locals {
                let remotes = group.compactMap { other -> String? in
                    guard let parts = other.remoteParts, parts.branch == ref.name else { return nil }
                    return parts.remote
                }.sorted()
                labels.append(GitRefLabel(kind: .branch, name: ref.name, remotes: remotes, isCurrent: ref.fullName == headRef))
            }
            for ref in group where ref.kind == .remoteBranch {
                if let parts = ref.remoteParts, localNames.contains(parts.branch) { continue }
                labels.append(GitRefLabel(kind: .remote, name: ref.name))
            }
            for ref in group where ref.kind == .tag {
                labels.append(GitRefLabel(kind: .tag, name: ref.name))
            }
            result[target] = labels
        }
        if headRef == nil, let headOid {
            result[headOid, default: []].append(GitRefLabel(kind: .head, name: "HEAD", isCurrent: true))
        }
        return result.mapValues { $0.sorted(by: order) }
    }

    private static func order(_ a: GitRefLabel, _ b: GitRefLabel) -> Bool {
        func rank(_ label: GitRefLabel) -> Int {
            if label.isCurrent { return 0 }
            switch label.kind {
            case .head: return 0
            case .branch: return 1
            case .remote: return 2
            case .tag: return 3
            }
        }
        let (ra, rb) = (rank(a), rank(b))
        return ra != rb ? ra < rb : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// 行の右に出す日付の短い表記。
public enum GitDates {
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "たった今" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)分前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)時間前" }
        let days = hours / 24
        if days < 30 { return "\(days)日前" }
        if days < 365 { return "\(days / 30)か月前" }
        return "\(days / 365)年前"
    }
}
