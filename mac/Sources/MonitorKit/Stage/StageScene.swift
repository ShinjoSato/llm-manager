import Foundation

// 1 セッション分のステージの中身と動き。出典は 旧 monitor UI の `three/Ziggurat.tsx`・`pixel/voxelize.ts`・`pixel/kit.ts`・`pixel/look.ts`。

/// 立方体 1 つ。左右の中央・下端を原点に取る（絵の 1 マス = 1）。
public struct StageVoxel: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var color: UInt32
}

/// 寄せて描く光（カメラを向く板）。
public struct StageGlow: Sendable, Equatable {
    public var color: UInt32
    /// 置き場の原点からの高さ。
    public var offsetY: Double
    public var size: Double
}

/// ステージに立つ 1 体（キャラ・頭上マーク・持ち物）。
public struct StageFigure: Sendable, Equatable {
    public var id: String
    public var voxels: [StageVoxel]
    /// 絵の 1 マスの大きさ（世界の単位）。
    public var scale: Double
    /// 静止時の置き場。
    public var position: StageVector
    public var glow: StageGlow?
}

/// あるコマでの動く値。
public struct StageFrame: Sendable, Equatable {
    public var parentY: Double
    public var itemY: Double?
    public var markY: Double?
    public var kidYs: [Double]
    /// 縁取り板の光の強さ（emissiveIntensity）。
    public var capGlow: Double
    public var haloOpacity: Double
    public var markGlowOpacity: Double
}

public enum StageVoxels {
    /// 絵の 1 マスを 1 立方体にする。透明とパレットに無い色は飛ばす。
    public static func voxelize(_ sprite: PixelSprite, palette: PixelPalette) -> [StageVoxel] {
        let width = Double(sprite.width)
        let height = sprite.height
        var out: [StageVoxel] = []
        for (row, line) in sprite.rows.enumerated() {
            for (col, key) in line.enumerated() where key != "." {
                guard let color = palette[key] else { continue }
                out.append(StageVoxel(x: Double(col) - (width - 1) / 2, y: Double(height - 1 - row), color: color))
            }
        }
        return out
    }
}

/// 持ち物の絵と配色（出典 kit.ts の ITEMS）。
public struct StageItem: Sendable, Equatable {
    public var sprite: PixelSprite
    public var palette: PixelPalette
}

public enum StageItems {
    static let metal: PixelPalette = ["M": 0xcbd5e1, "T": 0xa16207, "K": 0x334155, "W": 0xe2e8f0,
                                      "L": 0x64748b, "G": 0x34d399, "P": 0xa16207]

    static func tinted(_ overrides: PixelPalette) -> PixelPalette {
        metal.merging(overrides) { $1 }
    }

    static let book = StageItem(sprite: PixelSprites.itemBook, palette: metal)
    static let hammer = StageItem(sprite: PixelSprites.itemHammer, palette: metal)
    static let scope = StageItem(sprite: PixelSprites.itemScope, palette: metal)
    static let note = StageItem(sprite: PixelSprites.itemNote, palette: metal)
    static let scroll = StageItem(sprite: PixelSprites.itemScroll, palette: tinted(["P": 0xf59e0b, "L": 0x92400e]))

    static let items: [String: StageItem] = [
        "Bash": StageItem(sprite: PixelSprites.itemTerminal, palette: tinted(["K": 0x475569, "G": 0x34d399])),
        "Read": book, "Grep": book, "Glob": book,
        "Edit": hammer, "Write": hammer, "NotebookEdit": hammer,
        "Skill": scroll,
        "WebFetch": scope, "WebSearch": scope, "ToolSearch": scope,
        "AskUserQuestion": StageItem(sprite: PixelSprites.itemQuestion, palette: tinted(["G": 0xfbbf24])),
        "Artifact": StageItem(sprite: PixelSprites.itemCanvas, palette: tinted(["G": 0x22d3ee])),
        "TodoWrite": note, "SendUserFile": note, "SendMessage": note,
    ]

    /// スキル実行中は巻物を持たせ続ける。Agent / Task は子が出るので持ち物にしない。
    public static func item(tool: String?, skill: String?) -> StageItem? {
        if let skill, !skill.isEmpty { return scroll }
        guard let tool, !tool.isEmpty, tool != "Agent", tool != "Task" else { return nil }
        return items[tool] ?? note
    }
}

/// 1 セッション分のステージ。SceneKit 側はこれをそのまま描き、`frame(at:still:)` で動かす。
public struct StageSceneModel: Sendable, Equatable {
    public var sessionId: String
    public var status: SessionStatus
    public var glow: UInt32
    public var beckons: Bool
    public var phase: Double
    public var parent: StageFigure
    public var mark: StageFigure?
    public var item: StageFigure?
    public var kids: [StageFigure]

    public init(session s: SessionSnapshot) {
        typealias B = StageBlueprint
        sessionId = s.sessionId
        status = s.status
        glow = B.glowColor(s.status)
        beckons = B.beckons(s.status)
        phase = B.phase(of: s.sessionId)

        let look = PixelCharacter.look(for: s.status)
        let parentScale = B.parentHeight / Double(look.sprite.height)
        parent = StageFigure(id: "parent", voxels: StageVoxels.voxelize(look.sprite, palette: look.palette),
                             scale: parentScale, position: StageVector(0, B.topY + parentScale / 2, 0), glow: nil)

        // 頭上マークはこちらを呼んでいる状態だけ立てる（出典 look.ts の mark / markPalette）。
        if let sign = Self.mark(for: s.status) {
            mark = StageFigure(id: "mark", voxels: StageVoxels.voxelize(sign.sprite, palette: ["A": sign.color]),
                               scale: B.markVoxel,
                               position: StageVector(B.markX, B.markBottom + B.markVoxel / 2, 0),
                               glow: StageGlow(color: glow, offsetY: Double(B.markRows - 1) / 2 * B.markVoxel,
                                               size: B.markGlowSize))
        } else {
            mark = nil
        }

        if s.status == .working, let kit = StageItems.item(tool: s.currentTool, skill: s.currentSkill) {
            let scale = B.itemHeight / Double(kit.sprite.height)
            item = StageFigure(id: "item", voxels: StageVoxels.voxelize(kit.sprite, palette: kit.palette), scale: scale,
                               position: StageVector(B.itemX, B.topY + B.itemLift + scale / 2, B.itemZ),
                               glow: StageGlow(color: B.glowColor(.working), offsetY: B.itemHeight / 2 - scale / 2,
                                               size: B.itemGlowSize))
        } else {
            item = nil
        }

        let kidScale = B.kidHeight / Double(PixelSprites.kidStand.height)
        let agents = Array(s.agents.prefix(B.maxKids)).sorted { $0.id < $1.id }
        kids = agents.enumerated().map { i, agent in
            let job = StageLogic.job(for: agent.type)
            let palette = PixelCharacter.skin.merging(["C": job.light, "E": job.dark, "F": job.dark]) { $1 }
            return StageFigure(id: "kid-\(agent.id)", voxels: StageVoxels.voxelize(PixelSprites.kidStand, palette: palette),
                               scale: kidScale,
                               position: StageVector((Double(i) - Double(agents.count - 1) / 2) * B.kidGap,
                                                     B.kidY + kidScale / 2, B.kidZ),
                               glow: nil)
        }
    }

    /// 要対応の状態の頭上マーク。
    static func mark(for status: SessionStatus) -> (sprite: PixelSprite, color: UInt32)? {
        switch status {
        case .permission: return (PixelSprites.markBang, 0xfbbf24)
        case .waiting: return (PixelSprites.markQuestion, 0x60a5fa)
        case .error: return (PixelSprites.markBang, 0xf87171)
        default: return nil
        }
    }

    /// 動くものがあるか。無ければ 1 枚描いて止めてよい。
    public var isAnimated: Bool {
        StageBlueprint.beat(status).swing != 0 || mark != nil || item != nil || !kids.isEmpty
    }

    /// 時刻 `t`（秒）での動く値。`still` は動きを減らす設定で、脈も跳ねも止める。
    public func frame(at t: Double, still: Bool) -> StageFrame {
        typealias B = StageBlueprint
        let level = B.pulse(status, at: still ? 0 : t + phase * .pi * 2)
        let beat = still ? 0 : B.hop(t + phase * B.hopPeriod, period: B.hopPeriod, rise: B.hopRise)
        let lift = (status == .working ? beat : 0) * parent.scale
        let markHop = still ? 0 : B.hop(t + phase * B.markPeriod, period: B.markPeriod, rise: B.hopRise)
        let kidYs = kids.enumerated().map { i, kid in
            let at = t + (phase + Double(i) * B.kidStagger) * B.kidHopPeriod
            return kid.position.y + (still ? 0 : B.hop(at, period: B.kidHopPeriod, rise: B.hopRise)) * kid.scale
        }
        return StageFrame(parentY: parent.position.y + lift,
                          itemY: item.map { $0.position.y + beat * parent.scale },
                          markY: mark.map { $0.position.y + markHop * B.markVoxel },
                          kidYs: kidYs,
                          capGlow: level * 0.9,
                          haloOpacity: beckons ? 0.12 + level * 0.16 : 0.05 + level * 0.09,
                          markGlowOpacity: 0.45 + level * 0.3)
    }
}

/// 画面の縦横比に合わせたカメラと地面（出典 World.tsx）。
public struct StageView: Sendable, Equatable {
    public var camera: StageCameraFit
    /// 地面の一辺。画角を埋めるだけ広げる。
    public var groundWidth: Double
    public var gridDivisions: Int
    public var fogStart: Double
    public var fogEnd: Double

    public init(aspect: Double) {
        typealias B = StageBlueprint
        let safe = aspect > 0 && aspect.isFinite ? aspect : 1
        let layout = B.gridLayout(count: 1, spacingX: B.spacingX, spacingZ: B.spacingZ, maxCols: B.columnsFor(aspect: safe))
        camera = B.cameraFit(layout: layout, footprintX: B.footprintX, footprintZ: B.footprintZ, height: B.headroom,
                             aspect: safe, fovDegrees: B.fov, elevation: B.elevation)
        let reach = hypot(camera.position.y - camera.target.y, camera.position.z)
        groundWidth = reach * tan(B.fov * .pi / 180 / 2) * max(safe, 1) * 2.6
        gridDivisions = max(2, Int((groundWidth / B.spacingX).rounded(.toNearestOrAwayFromZero)) * 2)
        fogStart = reach * 1.05
        fogEnd = reach * 2.6
    }
}
