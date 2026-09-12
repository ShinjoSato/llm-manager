// 空間の寸法・配置・光り方。three に依らない計算だけを置き、形の組み立てとは分ける。
import type { SessionStatus } from "../../../src/types.js";
import { lookOf } from "../pixel/look.js";

/** 議事堂 1 棟の各段の高さ（床の上面 y）と幅。段数は固定。 */
export const CAPITOL = {
  /** 基壇の 2 段。 */
  stepA: { size: 4.8, height: 0.35 },
  stepB: { size: 4.2, height: 0.25 },
  /** 土台の列柱。 */
  colonnade: { height: 1.4, radius: 0.14, span: 3.4, perSide: 4 },
  /** サブエージェントが並ぶ 2 段目の床。 */
  tier2: { size: 4.0, thickness: 0.3 },
  /** 2 段目を囲う柱（頂上を支える）。 */
  piers: { height: 1.0, radius: 0.1, span: 2.2 },
  /** 親エージェントが立つ頂上の床。 */
  tier3: { size: 2.6, thickness: 0.25 },
  /** ドームを支える円形列柱。 */
  rotunda: { height: 1.25, radius: 0.08, ring: 0.95, count: 8 },
  /** 冠とドーム。 */
  cornice: { radius: 1.12, height: 0.18 },
  dome: { radius: 1.0 },
  finial: { radius: 0.13 },
  /** 建物の footprint（配置の間隔に使う）。 */
  footprint: 4.8,
} as const;

/** 2 段目の床の上面。 */
export const TIER2_TOP =
  CAPITOL.stepA.height + CAPITOL.stepB.height + CAPITOL.colonnade.height + CAPITOL.tier2.thickness;

/** 頂上の床の上面。親エージェントはここに立つ。 */
export const TIER3_TOP = TIER2_TOP + CAPITOL.piers.height + CAPITOL.tier3.thickness;

/** 冠の上面（ドームの付け根）。 */
export const CORNICE_TOP = TIER3_TOP + CAPITOL.rotunda.height + CAPITOL.cornice.height;

/** 建物の全高。カメラの画角合わせに使う。 */
export const CAPITOL_HEIGHT = CORNICE_TOP + CAPITOL.dome.radius + CAPITOL.finial.radius * 3;

/** キャラの背丈（世界の単位）。段の高さに対して小さすぎると誰も居ないように見える。 */
export const PARENT_HEIGHT = 1.15;
export const KID_HEIGHT = 0.85;

export interface Spot {
  x: number;
  z: number;
}

export interface Layout {
  spots: Spot[];
  /** 建物の中心が占める範囲（footprint を含まない）。 */
  spanX: number;
  spanZ: number;
}

/**
 * 建物を並べる格子。横長の画面に合わせて奥より先に横へ広げ、
 * 奥の行は半間ずらす（真後ろに置くと手前の棟に隠れて段が見えない）。
 */
export function gridLayout(
  count: number,
  spacingX: number,
  spacingZ: number,
  maxCols: number,
): Layout {
  if (count <= 0) return { spots: [], spanX: 0, spanZ: 0 };
  // 横に置ける限りは 1 行に並べる。奥に回すと手前の棟の陰になって見づらい。
  const cols = Math.min(count, Math.max(1, Math.round(maxCols)));
  const rows = Math.ceil(count / cols);
  const spots: Spot[] = [];
  for (let i = 0; i < count; i++) {
    const col = i % cols;
    const row = Math.floor(i / cols);
    spots.push({
      x: (col - (cols - 1) / 2) * spacingX + (row % 2 ? spacingX / 2 : 0),
      z: -(row - (rows - 1) / 2) * spacingZ,
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

/** 画面の縦横比から、1 行に並べてよい棟数を決める。横長なら奥へ回さずに済む。 */
export function columnsFor(aspect: number): number {
  const safe = aspect > 0 && Number.isFinite(aspect) ? aspect : 1;
  return Math.max(1, Math.round(safe * 1.6));
}

export interface CameraFit {
  position: [number, number, number];
  target: [number, number, number];
}

/**
 * 建物の広がりが画角に収まるカメラ位置。正面やや上から見下ろす。
 * 縦横どちらで溢れるかは画面の縦横比で変わるので、両方を満たす距離を採る。
 */
export function cameraFit(
  layout: Layout,
  footprint: number,
  height: number,
  aspect: number,
  fovDeg: number,
  elevation: number,
): CameraFit {
  const halfW = layout.spanX / 2 + footprint / 2;
  const halfD = layout.spanZ / 2 + footprint / 2;
  const fov = (fovDeg * Math.PI) / 180;
  const safeAspect = aspect > 0 && Number.isFinite(aspect) ? aspect : 1;
  const hFov = 2 * Math.atan(Math.tan(fov / 2) * safeAspect);

  // 見下ろすと奥行きが縦方向の見かけに足される。
  const seenHalfHeight = (height / 2) * Math.cos(elevation) + halfD * Math.sin(elevation);
  const byHeight = seenHalfHeight / Math.tan(fov / 2);
  const byWidth = halfW / Math.tan(hFov / 2);
  // 手前の列はカメラに近いぶん大きく写るので、外接箱に収めるだけでは足元が切れる。
  const dist = Math.max(byHeight, byWidth) * 1.18 + halfD * Math.cos(elevation);

  const focusY = height * 0.42;
  return {
    position: [0, focusY + dist * Math.sin(elevation), dist * Math.cos(elevation)],
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
