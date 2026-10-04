import Foundation

// ステージ（3D）の寸法・配置・光り方。出典は 旧 monitor UI の `three/blueprint.ts`・`three/World.tsx`（数値は同じ）。

public struct StageVector: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// 段々のピラミッドの 1 段。
public struct StageStep: Sendable, Equatable {
    /// 下から数えた段。0 が最下段。
    public var level: Int
    public var width: Double
    public var depth: Double
    public var base: Double
    public var top: Double
}

public struct StageSpot: Sendable, Equatable {
    public var x: Double
    public var z: Double
}

public struct StageLayout: Sendable, Equatable {
    public var spots: [StageSpot]
    public var spanX: Double
    public var spanZ: Double
}

public struct StageCameraFit: Sendable, Equatable {
    public var position: StageVector
    public var target: StageVector
}

public enum StageBlueprint {
    // MARK: - 寸法

    /// キャラの背丈（世界の単位）。
    public static let parentHeight = 1.62
    public static let kidHeight = 1.15

    public static let levels = 5
    public static let rise = 0.4
    public static let topWidth = 2.96
    public static let topDepth = 1.2
    public static let insetX = 0.38
    public static let insetZ = 0.4
    /// 段の上に重ねる縁取り板。ここが状態の色で光る。
    public static let cap = 0.07
    /// 縁取り板の張り出し。段の境目を線として読ませる。
    public static let nosing = 0.06

    /// 下から上へ小さくなる段を積む。
    public static func steps(levels: Int = levels) -> [StageStep] {
        let count = max(1, levels)
        return (0..<count).map { level in
            let down = Double(count - 1 - level)
            return StageStep(level: level,
                             width: topWidth + 2 * insetX * down,
                             depth: topDepth + 2 * insetZ * down,
                             base: Double(level) * rise,
                             top: Double(level + 1) * rise)
        }
    }

    public static let stepList = steps()

    /// 最上段の上面。親エージェントはここに立つ。
    public static let topY = stepList[stepList.count - 1].top
    /// 1 つ下の段の上面。サブエージェントはここに並ぶ。
    public static let kidY = stepList[max(0, stepList.count - 2)].top
    public static let footprintX = stepList[0].width
    public static let footprintZ = stepList[0].depth
    public static let skyline = topY + parentHeight
    public static let kidGap = 0.95
    /// 子が立つ z。上の段に隠れず、段から落ちない踏み面の中ほど。
    public static let kidZ = (stepList[stepList.count - 1].depth / 2 + stepList[max(0, stepList.count - 2)].depth / 2) / 2

    /// 親の絵の 1 マス。持ち物の大きさも跳ねの量もこれに揃える。
    public static let voxel = parentHeight / Double(PixelSprites.agentStand.height)
    public static let itemHeight = voxel * Double(PixelSprites.itemNote.height)
    public static let itemX = 0.98
    public static let itemZ = 0.16
    public static let itemLift = 0.26

    /// 跳ね方。ドット絵らしく 2 コマで跳ねる。
    public static let hopPeriod = 1.1
    public static let kidHopPeriod = 2.2
    public static let hopRise = 1.0
    public static let kidStagger = 0.31

    public static let markVoxel = voxel
    public static let markRows = 5
    public static let markX = 0.86
    public static let markTop = skyline + voxel
    public static let markBottom = markTop - Double(markRows) * markVoxel
    /// 画角に入れる高さ。跳ねたマークの先まで入れる。
    public static let headroom = markTop + hopRise * markVoxel
    /// マークの跳ねの周期（秒）。親の跳ねとずらす。
    public static let markPeriod = 0.9

    /// キャラの厚み（絵の 1 マスを 1 とした値）。
    public static let figureDepth = 3.0
    /// 同時に出すサブエージェントの上限（出典 `pixel/AgentStage.tsx` の MAX_KIDS）。
    public static let maxKids = 4

    /// 影と光の輪の半径。
    public static let groundRadius = max(footprintX, footprintZ) * 0.55
    public static let shadowRadius = groundRadius * 0.72
    public static let itemGlowSize = itemHeight * 2.1
    public static let markGlowSize = Double(markRows) * markVoxel * 2.4

    // MARK: - 空間（World.tsx）

    public static let fov = 34.0
    /// 見下ろす角度（ラジアン）。
    public static let elevation = 0.42
    public static let spacingX = footprintX + 1
    public static let spacingZ = clearSpacingZ(height: kidY + kidHeight, depth: footprintZ, elevation: elevation)

    public static let groundColor: UInt32 = 0x16243a
    public static let gridCenterColor: UInt32 = 0x1e3a5f
    public static let gridColor: UInt32 = 0x142234
    public static let fogColor: UInt32 = 0x070c14
    public static let stoneColor: UInt32 = 0xaeb9cc
    public static let shadeColor: UInt32 = 0x8b97ab
    public static let capColor: UInt32 = 0x0d1726

    // MARK: - 配置

    /// ピラミッドを並べる格子。横長の画面に合わせて奥より先に横へ広げる。
    public static func gridLayout(count: Int, spacingX: Double, spacingZ: Double, maxCols: Double) -> StageLayout {
        guard count > 0 else { return StageLayout(spots: [], spanX: 0, spanZ: 0) }
        let cols = min(count, max(1, Int(maxCols.rounded(.toNearestOrAwayFromZero))))
        let rows = (count + cols - 1) / cols
        var spots: [StageSpot] = []
        for i in 0..<count {
            let col = i % cols
            let row = i / cols
            let inRow = min(cols, count - row * cols)
            let lattice = inRow % 2 == 0 ? 0.5 : 0
            let raw = (Double(row % 2) * 0.5 - lattice + 1).truncatingRemainder(dividingBy: 1)
            let stagger = spacingX * raw
            spots.append(StageSpot(x: (Double(col) - Double(inRow - 1) / 2) * spacingX + stagger,
                                   z: rows > 1 ? -(Double(row) - Double(rows - 1) / 2) * spacingZ : 0))
        }
        let xs = spots.map(\.x)
        let left = xs.min() ?? 0
        let right = xs.max() ?? 0
        let offset = (left + right) / 2
        for i in spots.indices { spots[i].x -= offset }
        return StageLayout(spots: spots, spanX: right - left, spanZ: Double(rows - 1) * spacingZ)
    }

    /// 画面の縦横比から、1 行に並べてよい基数を決める。
    public static func columnsFor(aspect: Double) -> Double {
        let safe = aspect > 0 && aspect.isFinite ? aspect : 1
        return max(1, (safe * 1.3).rounded(.toNearestOrAwayFromZero))
    }

    /// 奥の行が手前の行に隠れない行間。
    public static func clearSpacingZ(height: Double, depth: Double, elevation: Double) -> Double {
        let t = tan(elevation)
        guard t > 0 else { return .infinity }
        return height / t + depth / 2
    }

    /// 画角に対する余白。
    static let margin = 1.06

    /// ピラミッドの広がりが画角に収まるカメラ位置。正面やや上から見下ろす。
    public static func cameraFit(layout: StageLayout, footprintX: Double, footprintZ: Double, height: Double,
                                 aspect: Double, fovDegrees: Double, elevation: Double) -> StageCameraFit {
        let fov = fovDegrees * .pi / 180
        let safeAspect = aspect > 0 && aspect.isFinite ? aspect : 1
        let hFov = 2 * atan(tan(fov / 2) * safeAspect)
        let c = cos(elevation)
        let s = sin(elevation)
        let halfW = layout.spanX / 2 + footprintX / 2
        let halfZ = footprintZ / 2
        let spots = layout.spots.isEmpty ? [StageSpot(x: 0, z: 0)] : layout.spots
        var vMin = Double.infinity
        var vMax = -Double.infinity
        var nearest = -Double.infinity
        for spot in spots {
            for y in [0, height] {
                for z in [spot.z - halfZ, spot.z + halfZ] {
                    let v = y * c - z * s
                    vMin = min(vMin, v)
                    vMax = max(vMax, v)
                    nearest = max(nearest, y * s + z * c)
                }
            }
        }
        let spread = (vMax - vMin) / 2
        let halfV = spread != 0 ? spread : height / 2
        let byHeight = halfV / tan(fov / 2)
        let byWidth = halfW / tan(hFov / 2)
        let focusY = (vMax + vMin) / 2 / c
        let protrusion = max(0, nearest - focusY * s)
        let dist = max(byHeight, byWidth) * margin + protrusion
        return StageCameraFit(position: StageVector(0, focusY + dist * s, dist * c), target: StageVector(0, focusY, 0))
    }

    // MARK: - 光り方

    /// 状態を表す光の色。キャラのフードと同じ色。
    public static func glowColor(_ status: SessionStatus) -> UInt32 {
        PixelCharacter.look(for: status).palette["G"] ?? 0x94a3b8
    }

    struct Beat {
        var base: Double
        var swing: Double
        var speed: Double
    }

    static func beat(_ status: SessionStatus) -> Beat {
        switch status {
        case .working: return Beat(base: 1.05, swing: 0.35, speed: 2.2)
        case .permission: return Beat(base: 1.3, swing: 0.6, speed: 3.4)
        case .waiting: return Beat(base: 1.1, swing: 0.5, speed: 2.6)
        case .error: return Beat(base: 1.35, swing: 0.7, speed: 5.2)
        case .stopped: return Beat(base: 0.14, swing: 0, speed: 0)
        case .idle, .unknown: return Beat(base: 0.32, swing: 0, speed: 0)
        }
    }

    /// 段の光の強さ。要対応ほど強く速く脈打たせる。
    public static func pulse(_ status: SessionStatus, at t: Double) -> Double {
        let b = beat(status)
        guard b.swing != 0 else { return b.base }
        return b.base + b.swing * sin(t * b.speed)
    }

    /// 要対応の基か。マークを出し、足元の光を強める。
    public static func beckons(_ status: SessionStatus) -> Bool {
        status == .permission || status == .waiting || status == .error
    }

    /// 2 コマの跳ね。周期の前半は地に足を付け、後半だけ浮かせる。
    public static func hop(_ t: Double, period: Double, rise: Double) -> Double {
        guard period > 0, rise > 0, t.isFinite else { return 0 }
        let r = t.truncatingRemainder(dividingBy: period)
        let phase = r < 0 ? r + period : r
        return phase < period / 2 ? 0 : rise
    }

    /// 基ごとに脈と跳ねをずらす種（0〜1）。JS の charCodeAt と同じく UTF-16 で数える。
    public static func phase(of id: String) -> Double {
        var h: UInt32 = 2_166_136_261
        for unit in id.utf16 {
            h ^= UInt32(unit)
            h = h &* 16_777_619
        }
        h ^= h >> 15
        h = h &* 2_246_822_507
        h ^= h >> 13
        return Double(h) / 4_294_967_296
    }
}
