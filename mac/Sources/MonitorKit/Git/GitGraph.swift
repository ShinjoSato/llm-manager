import Foundation

/// 行の中の線 1 本。上端・点の高さ・下端を結ぶ。
public struct GitGraphEdge: Sendable, Equatable {
    public enum Anchor: Sendable, Equatable { case top, center, bottom }

    public var from: Int
    public var fromAnchor: Anchor
    public var to: Int
    public var toAnchor: Anchor
    public var color: Int

    public init(from: Int, _ fromAnchor: Anchor, to: Int, _ toAnchor: Anchor, color: Int) {
        self.from = from
        self.fromAnchor = fromAnchor
        self.to = to
        self.toAnchor = toAnchor
        self.color = color
    }
}

/// 行の下へ続く線（詳細を開いた時にその下でも線を切らさないため）。
public struct GitGraphLane: Sendable, Equatable {
    public var column: Int
    public var color: Int
}

/// 図の 1 行分（点の列・色・線）。
public struct GitGraphRow: Sendable, Equatable {
    public var column: Int
    public var color: Int
    public var edges: [GitGraphEdge]
    public var continuing: [GitGraphLane]
    /// この行で使う列の数。
    public var width: Int
}

/// レーンの割り当て。子が待っている親の列を引き継ぎ、最初の親は同じ列・他の親は空いた列へ置き、終わった列は詰める。
public enum GitGraphLayout {
    public static let defaultPaletteSize = 8

    private struct Lane {
        var hash: String
        var color: Int
    }

    /// `commits` は子が親より先に来る順（`--date-order`）。図に無い親へ向かう線は最後の行の下まで伸ばす。
    public static func rows(for commits: [GitCommit], paletteSize: Int = defaultPaletteSize) -> [GitGraphRow] {
        var lanes: [Lane] = []
        var rows: [GitGraphRow] = []
        var rotation = 0
        rows.reserveCapacity(commits.count)

        func pickColor(_ active: [Lane?]) -> Int {
            let used = Set(active.compactMap { $0?.color })
            if let free = (0..<paletteSize).first(where: { !used.contains($0) }) { return free }
            defer { rotation += 1 }
            return rotation % paletteSize
        }

        for commit in commits {
            let before = lanes
            let matches = before.indices.filter { before[$0].hash == commit.hash }
            var work: [Lane?] = before.map { $0 }
            let column: Int
            let color: Int
            if let first = matches.first {
                column = first
                color = before[first].color
            } else {
                column = work.count
                color = pickColor(work)
                work.append(nil)
            }
            for index in matches { work[index] = nil }

            var targets: [(slot: Int, color: Int)] = []
            if let first = commit.parents.first {
                work[column] = Lane(hash: first, color: color)
                targets.append((column, color))
            }
            for parent in commit.parents.dropFirst() {
                if let existing = work.firstIndex(where: { $0?.hash == parent }) {
                    targets.append((existing, work[existing]!.color))
                    continue
                }
                let laneColor = pickColor(work)
                let slot: Int
                if let free = work.indices.first(where: { $0 > column && work[$0] == nil }) {
                    slot = free
                } else {
                    slot = work.count
                    work.append(nil)
                }
                work[slot] = Lane(hash: parent, color: laneColor)
                targets.append((slot, laneColor))
            }

            var compacted: [Int?] = []
            var next = 0
            for lane in work {
                compacted.append(lane == nil ? nil : next)
                if lane != nil { next += 1 }
            }
            lanes = work.compactMap { $0 }

            var edges: [GitGraphEdge] = []
            for (index, lane) in before.enumerated() {
                if lane.hash == commit.hash {
                    edges.append(GitGraphEdge(from: index, .top, to: column, .center, color: lane.color))
                } else if let to = compacted[index] {
                    edges.append(GitGraphEdge(from: index, .top, to: to, .bottom, color: lane.color))
                }
            }
            for target in targets {
                guard let to = compacted[target.slot] else { continue }
                edges.append(GitGraphEdge(from: column, .center, to: to, .bottom, color: target.color))
            }
            rows.append(GitGraphRow(column: column, color: color, edges: edges,
                                    continuing: lanes.enumerated().map { GitGraphLane(column: $0.offset, color: $0.element.color) },
                                    width: max(before.count, work.count)))
        }
        return rows
    }
}

/// 図の横の寸法。列が多い時は列の幅を詰めて収め、それでも入らない列は右端の列に寄せて描く（点を消さない）。
public struct GitGraphGeometry: Sendable, Equatable {
    public static let maxLaneWidth = 10.0
    public static let minLaneWidth = 5.0
    /// 360px の欄で説明の幅を残すための図の幅の目安。
    public static let targetWidth = 100.0
    public static let padding = 4.0

    public let laneWidth: Double
    public let visibleLanes: Int

    public init(lanes: Int) {
        let count = max(lanes, 1)
        laneWidth = min(Self.maxLaneWidth, max(Self.minLaneWidth, Self.targetWidth / Double(count)))
        visibleLanes = min(count, Int(Self.targetWidth / laneWidth))
    }

    public var width: Double { Double(visibleLanes) * laneWidth + Self.padding }
    public var dotRadius: Double { min(3.6, laneWidth * 0.36) }
    public var lineWidth: Double { laneWidth < 7 ? 1.3 : 1.6 }

    public func x(_ column: Int) -> Double {
        Double(min(max(column, 0), visibleLanes - 1)) * laneWidth + laneWidth / 2 + Self.padding / 2
    }
}
