import Foundation

// 一覧のアイコンはマークの大きさ・位置・跳ね幅を小さい表示で読めるよう変えている（ステージの 3D はそのまま）。

/// 文字列で持つドット絵。"." は透明で、他の 1 文字がパレットのキーになる。
public struct PixelSprite: Sendable, Equatable {
    public let rows: [String]

    public init(_ rows: [String]) {
        self.rows = rows
    }

    public var width: Int { rows.map(\.count).max() ?? 0 }
    public var height: Int { rows.count }

    /// 絵に使われている色キー（透明を除く）。
    public var keys: Set<Character> {
        Set(rows.joined().filter { $0 != "." })
    }
}

/// 色キー → 0xRRGGBB。
public typealias PixelPalette = [Character: UInt32]

/// 横に連続する同色のマス。1 マス 1 矩形だと塗りの回数が数倍になる。
public struct PixelRun: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var color: UInt32
}

public enum PixelSprites {
    /// 親エージェント（立ち）。G=フード S=肌 K=目 B=胴 D=脚
    public static let agentStand = PixelSprite([
        "....GGGG....",
        "...GGGGGG...",
        "..GGGGGGGG..",
        "..GGSSSSGG..",
        "..GSKSSKSG..",
        "..GSSSSSSG..",
        "...SSSSSS...",
        "....SSSS....",
        "...BBBBBB...",
        "..BBBBBBBB..",
        "..BBBBBBBB..",
        "..BBBBBBBB..",
        "...BBBBBB...",
        "...DD..DD...",
        "..DDD..DDD..",
    ])

    /// 親エージェント（座り）。待機・終了。
    public static let agentSit = PixelSprite([
        "............",
        "............",
        "....GGGG....",
        "...GGGGGG...",
        "..GGGGGGGG..",
        "..GGSSSSGG..",
        "..GSKSSKSG..",
        "..GSSSSSSG..",
        "...SSSSSS...",
        "...BBBBBB...",
        "..BBBBBBBB..",
        "..BBBBBBBB..",
        "..BBBBBBBB..",
        ".DDBBBBBBDD.",
        ".DDDDDDDDDD.",
    ])

    /// 親エージェント（うずくまり）。エラー。
    public static let agentDown = PixelSprite([
        "............",
        "............",
        "............",
        "....GGGG....",
        "...GGGGGG...",
        "..GGGGGGGG..",
        "..GGSSSSGG..",
        "..GSKSSKSG..",
        "..GSSSSSSG..",
        "...SSSSSS...",
        "..BBBBBBBB..",
        ".BBBBBBBBBB.",
        ".BBBBBBBBBB.",
        ".BBBBBBBBBB.",
        ".DDDDDDDDDD.",
    ])

    public static let markBang = PixelSprite(["A", "A", "A", ".", "A"])
    public static let markQuestion = PixelSprite(["AAA", "..A", ".A.", "...", ".A."])
    public static let markSleep = PixelSprite(["AAA", "..A", ".A.", "A..", "AAA"])

    // 以下はステージ（3D）で使う。

    /// サブエージェント。C=明色 E=濃色 S=肌 K=目 F=脚
    public static let kidStand = PixelSprite([
        "..CCCCCC..",
        ".CCCCCCCC.",
        ".CCSSSSCC.",
        ".CSKSSKSC.",
        ".CSSSSSSC.",
        "..SSSSSS..",
        "..EEEEEE..",
        ".EEEEEEEE.",
        ".EEEEEEEE.",
        "..EEEEEE..",
        "..FF..FF..",
        ".FFF..FFF.",
    ])

    // 持ち物。K=枠 G=光る面 W=白 L=線 M=金属 T=柄 P=縁

    /// 端末（Bash）。
    public static let itemTerminal = PixelSprite([
        "........",
        ".KKKKKK.",
        ".KGGGGK.",
        ".KGKGGK.",
        ".KGGKGK.",
        ".KGGGGK.",
        ".KKKKKK.",
        "..K..K..",
    ])

    /// 本（Read / Grep / Glob）。
    public static let itemBook = PixelSprite([
        "........",
        ".WWWWWW.",
        ".WLLLLW.",
        ".WLWWLW.",
        ".WLLLLW.",
        ".WLWWLW.",
        ".WWWWWW.",
        "..KKKK..",
    ])

    /// 巻物（Skill）。
    public static let itemScroll = PixelSprite([
        "..PPPP..",
        ".PWWWWP.",
        ".PWLLWP.",
        ".PWWWWP.",
        ".PWLLWP.",
        ".PWWWWP.",
        "..PPPP..",
        "........",
    ])

    /// 槌（Edit / Write）。
    public static let itemHammer = PixelSprite([
        ".MMMMM..",
        ".MMMMM..",
        ".MMMMM..",
        "...TT...",
        "...TT...",
        "...TT...",
        "...TT...",
        "........",
    ])

    /// 望遠鏡（WebFetch / WebSearch）。
    public static let itemScope = PixelSprite([
        "......MM",
        ".....MM.",
        "....MM..",
        "...MM...",
        "..MM....",
        ".MM.....",
        "MM......",
        "........",
    ])

    /// 問いかけ（AskUserQuestion）。
    public static let itemQuestion = PixelSprite([
        "..GGGG..",
        ".GG..GG.",
        ".....GG.",
        "....GG..",
        "...GG...",
        "...GG...",
        "........",
        "...GG...",
    ])

    /// 画布（Artifact）。
    public static let itemCanvas = PixelSprite([
        ".KKKKKK.",
        ".KWWWWK.",
        ".KWGGWK.",
        ".KWGGWK.",
        ".KWWWWK.",
        ".KKKKKK.",
        "...TT...",
        "..TTTT..",
    ])

    /// 巻いた紙（TodoWrite / 汎用）。
    public static let itemNote = PixelSprite([
        "........",
        ".WWWWWW.",
        ".WLLLLW.",
        ".WLLLLW.",
        ".WLLLLW.",
        ".WWWWWW.",
        "........",
        "........",
    ])

    /// 透明でないマスを、パレットで色が引けるものだけ横に連結して返す。
    public static func runs(_ sprite: PixelSprite, palette: PixelPalette) -> [PixelRun] {
        var out: [PixelRun] = []
        for (y, row) in sprite.rows.enumerated() {
            let cells = Array(row)
            var i = 0
            while i < cells.count {
                let key = cells[i]
                var j = i
                while j < cells.count && cells[j] == key { j += 1 }
                if key != ".", let color = palette[key] {
                    out.append(PixelRun(x: i, y: y, width: j - i, color: color))
                }
                i = j
            }
        }
        return out
    }
}

/// 状態ごとの小さな動き（稼働中は跳ね、要対応と待機はマークを動かす）。
public enum PixelMotion: Sendable, Equatable {
    /// 体が 2 コマで上下に跳ねる。
    case bob
    /// 頭上のマークが点滅する。
    case blink
    /// 頭上の Zz がゆっくり浮き沈みする。
    case drift
    case still
}

/// 1 状態の見た目。
public struct PixelLook: Sendable, Equatable {
    public var sprite: PixelSprite
    public var palette: PixelPalette
    public var mark: PixelSprite?
    public var markPalette: PixelPalette
    public var motion: PixelMotion

    /// 座り・うずくまりは頭が下がるぶん、マークも下げる。
    public var markDrop: Int {
        sprite.rows.prefix { row in row.allSatisfy { $0 == "." } }.count
    }
}

/// あるコマでの配置（グリッドのマス単位）。
public struct PixelFrame: Sendable, Equatable {
    public var bodyOffsetY: Int
    public var markOffsetY: Int
    public var markVisible: Bool
}

public enum PixelCharacter {
    /// 肌と目は職業・状態によらず共通。
    public static let skin: PixelPalette = ["S": 0xf6d3ab, "K": 0x0a0e14]

    /// 1 コマの長さ（秒）。4fps で十分ドット絵らしく、描き直しの回数も抑えられる。
    public static let tick: TimeInterval = 0.25

    /// 体（12 マス）と右上のマーク（3 マス、体の右端 1 列に重ねる）、跳ねる 1 マスぶんの余白。
    public static let gridWidth = 14
    public static let gridHeight = 16
    static let bodyOrigin = (x: 0, y: 1)
    static let markOrigin = (x: 11, y: 0)

    /// 行ごとに毎コマ作り直さないよう、状態ごとの見た目は一度だけ作る。
    private static let looks: [SessionStatus: PixelLook] = Dictionary(
        uniqueKeysWithValues: [SessionStatus.working, .waiting, .permission, .idle, .error, .stopped, .unknown]
            .map { ($0, makeLook(for: $0)) })

    public static func look(for status: SessionStatus) -> PixelLook {
        looks[status] ?? makeLook(for: status)
    }

    private static func makeLook(for status: SessionStatus) -> PixelLook {
        switch status {
        case .working:
            return PixelLook(sprite: PixelSprites.agentStand,
                             palette: skin.merging(["G": 0x34d399, "B": 0x10b981, "D": 0x0f766e]) { $1 },
                             mark: nil, markPalette: [:], motion: .bob)
        case .permission:
            return PixelLook(sprite: PixelSprites.agentStand,
                             palette: skin.merging(["G": 0xfbbf24, "B": 0xd97706, "D": 0x92400e]) { $1 },
                             mark: PixelSprites.markBang, markPalette: ["A": 0xfbbf24], motion: .blink)
        case .waiting:
            return PixelLook(sprite: PixelSprites.agentStand,
                             palette: skin.merging(["G": 0x60a5fa, "B": 0x2563eb, "D": 0x1e40af]) { $1 },
                             mark: PixelSprites.markQuestion, markPalette: ["A": 0x60a5fa], motion: .blink)
        case .error:
            return PixelLook(sprite: PixelSprites.agentDown,
                             palette: skin.merging(["G": 0xf87171, "B": 0xdc2626, "D": 0x991b1b]) { $1 },
                             mark: nil, markPalette: [:], motion: .still)
        case .idle:
            return PixelLook(sprite: PixelSprites.agentSit, palette: idlePalette,
                             mark: PixelSprites.markSleep, markPalette: ["A": 0x64748b], motion: .drift)
        case .stopped:
            return PixelLook(sprite: PixelSprites.agentSit,
                             palette: ["S": 0x8b8378, "K": 0x1e293b, "G": 0x3f4c5e, "B": 0x334155, "D": 0x1e293b],
                             mark: nil, markPalette: [:], motion: .still)
        case .unknown:
            // 状態が取れないうちは待機の姿で止めておく（Zz を出すと「待機」と誤読される）。
            return PixelLook(sprite: PixelSprites.agentSit, palette: idlePalette,
                             mark: nil, markPalette: [:], motion: .still)
        }
    }

    private static let idlePalette: PixelPalette = ["S": 0xcbb99c, "K": 0x0a0e14, "G": 0x64748b, "B": 0x475569, "D": 0x334155]

    /// 時刻から決まるコマ番号。全行が同じ拍で動くよう、行ごとの経過時間ではなく絶対時刻で数える。
    public static func tickIndex(at date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate / tick).rounded(.down))
    }

    public static func frame(_ motion: PixelMotion, tick index: Int) -> PixelFrame {
        let i = ((index % 8) + 8) % 8
        switch motion {
        case .bob:
            // 2 コマずつ（0.5 秒）上下。
            return PixelFrame(bodyOffsetY: i % 4 < 2 ? 0 : -1, markOffsetY: 0, markVisible: true)
        case .blink:
            return PixelFrame(bodyOffsetY: 0, markOffsetY: 0, markVisible: i % 4 < 3)
        case .drift:
            return PixelFrame(bodyOffsetY: 0, markOffsetY: i < 4 ? 0 : -1, markVisible: true)
        case .still:
            return PixelFrame(bodyOffsetY: 0, markOffsetY: 0, markVisible: true)
        }
    }

    /// あるコマで塗るマス（グリッド座標）。描画側はこれを矩形で塗るだけにする。
    public static func runs(for status: SessionStatus, tick index: Int) -> [PixelRun] {
        let look = look(for: status)
        let frame = frame(look.motion, tick: index)
        var out = PixelSprites.runs(look.sprite, palette: look.palette).map {
            PixelRun(x: $0.x + bodyOrigin.x, y: $0.y + bodyOrigin.y + frame.bodyOffsetY, width: $0.width, color: $0.color)
        }
        if let mark = look.mark, frame.markVisible {
            let top = markOrigin.y + look.markDrop + frame.markOffsetY + 1
            out += PixelSprites.runs(mark, palette: look.markPalette).map {
                PixelRun(x: $0.x + markOrigin.x, y: $0.y + top, width: $0.width, color: $0.color)
            }
        }
        return out
    }

    /// 動きのある状態か（止まっている絵には時計を回さない）。
    public static func isAnimated(_ status: SessionStatus) -> Bool {
        look(for: status).motion != .still
    }
}
