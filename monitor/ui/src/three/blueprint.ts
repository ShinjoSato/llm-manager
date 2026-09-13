// 空間の寸法・配置・光り方。three に依らない計算だけを置き、形の組み立てとは分ける。
import type { SessionStatus } from "../../../src/types.js";
import { lookOf } from "../pixel/look.js";
import { AGENT_STAND, ITEM_NOTE } from "../pixel/sprites.js";

/** キャラの背丈（世界の単位）。段に対して小さすぎると誰が居るのか読めない。 */
export const PARENT_HEIGHT = 1.62;
export const KID_HEIGHT = 1.15;

/** 段々のピラミッド 1 基の寸法。主役はキャラなので段は低く抑える。 */
export const ZIGGURAT = {
  levels: 5,
  /** 1 段の高さ。 */
  rise: 0.4,
  /** 最上段の大きさ。親エージェント 1 体が乗る。 */
  topWidth: 2.96,
  topDepth: 1.2,
  /** 1 段下りるごとに片側へ広がる量。奥行きは正面から見えないぶん浅く取る。 */
  insetX: 0.38,
  insetZ: 0.4,
  /** 段の上に重ねる縁取り板。ここが状態の色で光る。 */
  cap: 0.07,
  /** 縁取り板の張り出し。段の境目を線として読ませる。 */
  nosing: 0.06,
} as const;

export interface Step {
  /** 下から数えた段。0 が最下段。 */
  level: number;
  width: number;
  depth: number;
  /** 段の底面と上面。キャラは上面に立つ。 */
  base: number;
  top: number;
}

/** 下から上へ小さくなる段を積む。上の段ほど狭いのでピラミッドに見える。 */
export function steps(spec: typeof ZIGGURAT): Step[] {
  const levels = Math.max(1, Math.round(spec.levels));
  return Array.from({ length: levels }, (_, level) => {
    const down = levels - 1 - level;
    return {
      level,
      width: spec.topWidth + 2 * spec.insetX * down,
      depth: spec.topDepth + 2 * spec.insetZ * down,
      base: level * spec.rise,
      top: (level + 1) * spec.rise,
    };
  });
}

export const STEPS = steps(ZIGGURAT);

/** 最上段の上面。親エージェントはここに立つ。 */
export const TOP_Y = STEPS[STEPS.length - 1]!.top;
/** 1 つ下の段の上面。サブエージェントはここに並ぶ。 */
export const KID_Y = STEPS[Math.max(0, STEPS.length - 2)]!.top;

/** 最下段の広がり。配置の間隔とカメラ合わせに使う。 */
export const FOOTPRINT_X = STEPS[0]!.width;
export const FOOTPRINT_Z = STEPS[0]!.depth;

/** いちばん高い点。親の頭まで画角に入れないと顔が切れる。 */
export const SKYLINE = TOP_Y + PARENT_HEIGHT;

/** サブエージェントの間隔。詰めると肩が重なって人数が読めない。 */
export const KID_GAP = 0.95;

/** 子が立つ z。上の段に隠れず、段から落ちない踏み面の中ほどに置く。 */
export const KID_Z =
  (STEPS[STEPS.length - 1]!.depth / 2 + STEPS[Math.max(0, STEPS.length - 2)]!.depth / 2) / 2;

export interface Spot {
  x: number;
  z: number;
}

export interface Layout {
  spots: Spot[];
  /** ピラミッドの中心が占める範囲（footprint を含まない）。 */
  spanX: number;
  spanZ: number;
}

/** ピラミッドを並べる格子。横長の画面に合わせて奥より先に横へ広げる。 */
export function gridLayout(
  count: number,
  spacingX: number,
  spacingZ: number,
  maxCols: number,
): Layout {
  if (count <= 0) return { spots: [], spanX: 0, spanZ: 0 };
  // 横に置ける限りは 1 行に並べる。奥に回すと手前の段に隠れる恐れが出る。
  const cols = Math.min(count, Math.max(1, Math.round(maxCols)));
  const rows = Math.ceil(count / cols);
  const spots: Spot[] = [];
  for (let i = 0; i < count; i++) {
    const col = i % cols;
    const row = Math.floor(i / cols);
    // 端数の行も中央に揃える。行の実数で割らないと最後の行だけ左に寄る。
    const inRow = Math.min(cols, count - row * cols);
    // 中央寄せの結果どの格子に乗るかは行の基数の偶奇で決まる。隣り合う行で必ず半間ずれるよう補う。
    const lattice = inRow % 2 === 0 ? 0.5 : 0;
    const stagger = spacingX * ((((row % 2) * 0.5 - lattice + 1) % 1));
    spots.push({
      // 真後ろに置くと稜線が重なって段数が読めないのでずらす。
      x: (col - (inRow - 1) / 2) * spacingX + stagger,
      // 1 行しか無ければ行間は使わない。隠れない間隔が無限大になることがある。
      z: rows > 1 ? -(row - (rows - 1) / 2) * spacingZ : 0,
    });
  }
  // ずらしたぶん全体が偏るので、左右の端を見て中心に戻す。
  const xs = spots.map((s) => s.x);
  const left = Math.min(...xs);
  const right = Math.max(...xs);
  const offset = (left + right) / 2;
  for (const spot of spots) spot.x -= offset;
  return { spots, spanX: right - left, spanZ: (rows - 1) * spacingZ };
}

/** 画面の縦横比から、1 行に並べてよい基数を決める。横長なら奥へ回さずに済む。 */
export function columnsFor(aspect: number): number {
  const safe = aspect > 0 && Number.isFinite(aspect) ? aspect : 1;
  return Math.max(1, Math.round(safe * 1.3));
}

/** 奥の行が手前の行に隠れない行間。見下ろす角度が浅いほど必要な間隔は伸びる。 */
export function clearSpacingZ(height: number, depth: number, elevation: number): number {
  const tan = Math.tan(elevation);
  if (!(tan > 0)) return Infinity;
  return height / tan + depth / 2;
}

export interface CameraFit {
  position: [number, number, number];
  target: [number, number, number];
}

/** 画角に対する余白。詰めるほどキャラは大きく写るが、端が切れる。 */
const MARGIN = 1.06;

/** ピラミッドの広がりが画角に収まるカメラ位置。正面やや上から見下ろす。 */
export function cameraFit(
  layout: Layout,
  footprintX: number,
  footprintZ: number,
  height: number,
  aspect: number,
  fovDeg: number,
  elevation: number,
): CameraFit {
  const fov = (fovDeg * Math.PI) / 180;
  const safeAspect = aspect > 0 && Number.isFinite(aspect) ? aspect : 1;
  const hFov = 2 * Math.atan(Math.tan(fov / 2) * safeAspect);
  const cos = Math.cos(elevation);
  const sin = Math.sin(elevation);

  const halfW = layout.spanX / 2 + footprintX / 2;
  const halfZ = footprintZ / 2;

  // 見下ろすと奥の行ほど画面の上に来る。奥行きぶんも足して縦の見かけを測る。
  const spots = layout.spots.length ? layout.spots : [{ x: 0, z: 0 }];
  let vMin = Infinity;
  let vMax = -Infinity;
  let nearest = -Infinity;
  for (const spot of spots) {
    for (const y of [0, height]) {
      for (const z of [spot.z - halfZ, spot.z + halfZ]) {
        const v = y * cos - z * sin;
        if (v < vMin) vMin = v;
        if (v > vMax) vMax = v;
        nearest = Math.max(nearest, y * sin + z * cos);
      }
    }
  }

  const halfV = (vMax - vMin) / 2 || height / 2;
  const byHeight = halfV / Math.tan(fov / 2);
  const byWidth = halfW / Math.tan(hFov / 2);

  // 注視点は縦の見かけの中心。ずらすと上下どちらかに余白が偏る。
  const focusY = (vMax + vMin) / 2 / cos;
  // 手前の基はカメラに近いぶん大きく写るので、最前面までの張り出しを距離に足す。
  const protrusion = Math.max(0, nearest - focusY * sin);
  const dist = Math.max(byHeight, byWidth) * MARGIN + protrusion;

  return {
    position: [0, focusY + dist * sin, dist * cos],
    target: [0, focusY, 0],
  };
}

/** 状態を表す光の色。キャラと同じ LOOK の色を使い、2 つの表示で食い違わせない。 */
export function glowOf(status: SessionStatus): string {
  const palette = lookOf(status).palette;
  return palette.G ?? "#94a3b8";
}

interface Beat {
  /** 明るさの基準。 */
  base: number;
  /** 脈打つ幅。0 なら光り続けるだけ。 */
  swing: number;
  speed: number;
}

const BEAT: Record<SessionStatus, Beat> = {
  working: { base: 1.05, swing: 0.35, speed: 2.2 },
  permission: { base: 1.3, swing: 0.6, speed: 3.4 },
  waiting: { base: 1.1, swing: 0.5, speed: 2.6 },
  error: { base: 1.35, swing: 0.7, speed: 5.2 },
  idle: { base: 0.32, swing: 0, speed: 0 },
  stopped: { base: 0.14, swing: 0, speed: 0 },
};

/** 段の光の強さ。要対応ほど強く速く脈打たせる。 */
export function pulse(status: SessionStatus, t: number): number {
  const beat = BEAT[status] ?? BEAT.idle;
  if (!beat.swing) return beat.base;
  return beat.base + beat.swing * Math.sin(t * beat.speed);
}

/** 親の絵の 1 マス。持ち物の大きさも跳ねの量もこれに揃えると格子が崩れない。 */
export const VOXEL = PARENT_HEIGHT / AGENT_STAND.length;

/** 持ち物の背丈。2D と同じく、親と同じ倍率で絵を描いたときの大きさに合わせる。 */
export const ITEM_HEIGHT = VOXEL * ITEM_NOTE.length;

/** 持ち物を置く親の右隣。絵の幅ぶん離さないと親の胴が隠れる。 */
export const ITEM_X = 0.98;

/** 少し手前に出す。親と同じ奥行きだと輪郭が溶けて何を持っているか読めない。 */
export const ITEM_Z = 0.16;

/** 持ち物の下端。手の高さに浮かせる。足元に置くと落とし物に見える。 */
export const ITEM_LIFT = 0.26;

/** 跳ね方。ドット絵らしく 2 コマで跳ねる。滑らかに動かすと絵の質感と合わない。 */
export const HOP = {
  /** 親と持ち物の周期（秒）。2D の bob と揃える。 */
  period: 1.1,
  /** サブエージェントの周期（秒）。2D の bob-slow と揃える。 */
  kidPeriod: 2.2,
  /** 上げる量（絵のマス数）。半端に上げるとドット絵の格子が崩れて見える。 */
  rise: 1,
  /** 子どうしをずらす量（周期に対する割合）。横一列が同時に跳ねると板に見える。 */
  kidStagger: 0.31,
} as const;

/** 2 コマの跳ね。周期の前半は地に足を付け、後半だけ浮かせる。 */
export function hop(t: number, period: number, rise: number): number {
  if (!(period > 0) || !(rise > 0) || !Number.isFinite(t)) return 0;
  const phase = ((t % period) + period) % period;
  return phase < period / 2 ? 0 : rise;
}

/** 基ごとに脈と跳ねをずらす種（0〜1）。全部が揃って動くと群れが機械仕掛けに見える。 */
export function phaseOf(id: string): number {
  let h = 2166136261;
  for (let i = 0; i < id.length; i++) {
    h ^= id.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  // 1 文字違いの id が隣り合って建つので、最後に撹拌して下位の違いを全体へ散らす。
  h ^= h >>> 15;
  h = Math.imul(h, 2246822507);
  h ^= h >>> 13;
  return (h >>> 0) / 4294967296;
}
