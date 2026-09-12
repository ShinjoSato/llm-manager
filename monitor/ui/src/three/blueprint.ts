// 空間の寸法・配置・光り方。three に依らない計算だけを置き、形の組み立てとは分ける。
import type { SessionStatus } from "../../../src/types.js";
import { lookOf } from "../pixel/look.js";

/** 議事堂 1 棟の各部の寸法。主役はキャラなので建物は低く広く取る。 */
export const CAPITOL = {
  /** 基壇の 2 段。 */
  stepA: { width: 4.8, depth: 3.8, height: 0.3 },
  stepB: { width: 4.3, depth: 3.4, height: 0.22 },
  /** 土台の列柱。 */
  colonnade: { height: 0.9, radius: 0.14, spanX: 3.4, spanZ: 2.6, perSide: 4 },
  /** サブエージェントが並ぶ 2 段目の床。 */
  tier2: { width: 4.0, depth: 3.3, thickness: 0.24 },
  /** 頂上を支える躯体。奥へ下げてあるので手前に立つ子を隠さない。 */
  attic: { width: 2.4, depth: 1.6, height: 0.8, z: -0.7 },
  /** 頂上の床の前端を受ける 2 本。子の後ろに立つので誰も隠さない。 */
  piers: { radius: 0.1, spanX: 2.2, z: 0.6 },
  /** 親エージェントが立つ頂上の床。 */
  tier3: { width: 3.0, depth: 2.6, thickness: 0.22 },
  /** ドームを載せる胴。柱を立てると親の顔を縦に隠すので輪郭だけにする。 */
  drum: { radius: 0.98, height: 0.7, z: -0.5 },
  dome: { radius: 0.96 },
  finial: { radius: 0.12 },
  /** 建物の footprint（配置の間隔とカメラ合わせに使う）。 */
  footprintX: 4.8,
  footprintZ: 3.8,
} as const;

/** 2 段目の床の上面。 */
export const TIER2_TOP =
  CAPITOL.stepA.height + CAPITOL.stepB.height + CAPITOL.colonnade.height + CAPITOL.tier2.thickness;

/** 頂上の床の上面。親エージェントはここに立つ。 */
export const TIER3_TOP = TIER2_TOP + CAPITOL.attic.height + CAPITOL.tier3.thickness;

/** 胴の上面（ドームの付け根）。 */
export const DRUM_TOP = TIER3_TOP + CAPITOL.drum.height;

/** 建物の全高。カメラの画角合わせに使う。 */
export const CAPITOL_HEIGHT = DRUM_TOP + CAPITOL.dome.radius + CAPITOL.finial.radius * 3;

/** キャラの背丈（世界の単位）。建物に対して小さすぎると誰が居るのか読めない。 */
export const PARENT_HEIGHT = 1.62;
export const KID_HEIGHT = 1.15;

export interface Spot {
  x: number;
  y: number;
  z: number;
}

export interface Layout {
  spots: Spot[];
  rows: number;
  /** 建物の中心が占める範囲（footprint を含まない）。 */
  spanX: number;
  spanY: number;
  spanZ: number;
}

/**
 * 建物を並べる格子。横長の画面に合わせて奥より先に横へ広げ、
 * 奥の行は段 1 つぶん高い場所に置く（持ち上げないと手前の棟に隠れる）。
 */
export function gridLayout(
  count: number,
  spacingX: number,
  spacingZ: number,
  maxCols: number,
  rise: number,
): Layout {
  if (count <= 0) return { spots: [], rows: 0, spanX: 0, spanY: 0, spanZ: 0 };
  // 横に置ける限りは 1 行に並べる。奥に回すと段が増えて全体が縦に伸びる。
  const cols = Math.min(count, Math.max(1, Math.round(maxCols)));
  const rows = Math.ceil(count / cols);
  const spots: Spot[] = [];
  for (let i = 0; i < count; i++) {
    const col = i % cols;
    const row = Math.floor(i / cols);
    // 端数の行も中央に揃える。行の実数で割らないと最後の行だけ左に寄る。
    const inRow = Math.min(cols, count - row * cols);
    spots.push({
      // 真後ろに置くとドームが重なって読めないので半間ずらす。
      x: (col - (inRow - 1) / 2) * spacingX + (row % 2 ? spacingX / 2 : 0),
      y: row * rise,
      z: rowZ(row, rows, spacingZ),
    });
  }
  // ずらしたぶん全体が偏るので、左右の端を見て中心に戻す。
  const xs = spots.map((s) => s.x);
  const left = Math.min(...xs);
  const right = Math.max(...xs);
  const offset = (left + right) / 2;
  for (const spot of spots) spot.x -= offset;
  return {
    spots,
    rows,
    spanX: right - left,
    spanY: (rows - 1) * rise,
    spanZ: (rows - 1) * spacingZ,
  };
}

/** 行の奥行き位置。全体が原点を中心にするので、手前の行ほど z が大きい。 */
function rowZ(row: number, rows: number, spacingZ: number): number {
  return -(row - (rows - 1) / 2) * spacingZ;
}

/** 画面の縦横比から、1 行に並べてよい棟数を決める。横長なら奥へ回さずに済む。 */
export function columnsFor(aspect: number): number {
  const safe = aspect > 0 && Number.isFinite(aspect) ? aspect : 1;
  return Math.max(1, Math.round(safe * 1.3));
}

export interface Terrace {
  /** 段の上面。棟はこの高さに建つ。 */
  top: number;
  /** 段の手前の端。ここに蹴上げが出る。 */
  front: number;
  /** 段の奥の端。 */
  back: number;
}

/**
 * 奥へ上がっていく段。棟が建つ高さには踏み幅の広い踊り場を置き、その間は細かく刻む。
 * 棟が建つ行より数段ぶん先まで伸ばすので、手前しか埋まっていなくても階段として読める。
 */
export function terraces(
  rows: number,
  spacingZ: number,
  rise: number,
  extra: number,
  landing: number,
  flight: number,
): Terrace[] {
  const filled = Math.max(1, Math.round(rows));
  const levels = filled + Math.max(0, Math.round(extra));
  const steps = Math.max(1, Math.round(flight));
  const run = (spacingZ - landing) / steps;
  const out: Terrace[] = [];
  for (let level = 0; level < levels; level++) {
    // 踊り場の奥の端から刻み始める。棟はこの手前に建つ。
    const edge = rowZ(level, filled, spacingZ) - landing / 2;
    for (let k = 1; k <= steps; k++) {
      out.push({ top: level * rise + (k * rise) / steps, front: edge - (k - 1) * run, back: 0 });
    }
  }
  // 段は入れ子の箱なので、いちばん奥の段より先にまとめて底を置く。
  const back = out[out.length - 1]!.front - spacingZ;
  for (const step of out) step.back = back;
  return out;
}

export interface CameraFit {
  position: [number, number, number];
  target: [number, number, number];
}

/** 画角に対する余白。詰めるほどキャラは大きく写るが、端が切れる。 */
const MARGIN = 1.06;

/**
 * 建物の広がりが画角に収まるカメラ位置。正面やや上から見下ろす。
 * 段で持ち上げた奥の棟まで含めた「画面の縦方向の見かけ」で合わせる。
 */
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

  // 見下ろすと奥の段ほど画面の上に来る。持ち上げたぶんも足して縦の見かけを測る。
  const spots = layout.spots.length ? layout.spots : [{ x: 0, y: 0, z: 0 }];
  let vMin = Infinity;
  let vMax = -Infinity;
  let nearest = -Infinity;
  for (const spot of spots) {
    for (const y of [spot.y, spot.y + height]) {
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
  // 手前の棟はカメラに近いぶん大きく写るので、最前面までの張り出しを距離に足す。
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
  return palette.G ?? palette.C ?? "#94a3b8";
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

/** 建物の光の強さ。要対応ほど強く速く脈打たせる。 */
export function pulse(status: SessionStatus, t: number): number {
  const beat = BEAT[status] ?? BEAT.idle;
  if (!beat.swing) return beat.base;
  return beat.base + beat.swing * Math.sin(t * beat.speed);
}
