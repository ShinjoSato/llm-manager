// ドット絵を立方体の集まりに変換する。
// 描画方法（2D の rect / 3D の box）に依存しないので、カード内の小さい表示でも
// 全画面の空間でも同じ結果を使い回せる。
import type { Palette } from "./PixelArt.js";
import type { Sprite } from "./sprites.js";

export interface Voxel {
  /** 中心の座標。左右の中央・下端を原点にとる（地面に立たせやすい）。 */
  x: number;
  y: number;
  z: number;
  color: string;
}

/**
 * スプライトを立方体に変換する。絵の 1 マスが 1 立方体。
 * 奥行きは描画側が立方体の厚みとして与えるので、ここでは z=0 に並べる。
 */
export function voxelize(sprite: Sprite, palette: Palette): Voxel[] {
  const width = sprite.length ? Math.max(...sprite.map((r) => r.length)) : 0;
  const height = sprite.length;
  const out: Voxel[] = [];

  sprite.forEach((row, rowIndex) => {
    for (let col = 0; col < row.length; col++) {
      const ch = row[col]!;
      const color = palette[ch];
      if (ch === "." || !color) continue;
      out.push({
        // 左右は中央寄せ、上下は下端を 0 にして上向きを正にする。
        x: col - (width - 1) / 2,
        y: height - 1 - rowIndex,
        z: 0,
        color,
      });
    }
  });

  return out;
}

/**
 * 立方体が実際に広がっている大きさ。絵の枠ではなく中身を測る（端の透明は含めない）。
 * カメラの距離を決めるのに使う。
 */
export function boundsOf(voxels: Voxel[]): { width: number; height: number } {
  if (!voxels.length) return { width: 0, height: 0 };
  const xs = voxels.map((v) => v.x);
  const ys = voxels.map((v) => v.y);
  return {
    width: Math.max(...xs) - Math.min(...xs) + 1,
    height: Math.max(...ys) - Math.min(...ys) + 1,
  };
}

/** 中身の重心ではなく外接箱の中心。ここを原点に寄せると回転させても像が暴れない。 */
export function centerOf(voxels: Voxel[]): { x: number; y: number } {
  if (!voxels.length) return { x: 0, y: 0 };
  const xs = voxels.map((v) => v.x);
  const ys = voxels.map((v) => v.y);
  return {
    x: (Math.max(...xs) + Math.min(...xs)) / 2,
    y: (Math.max(...ys) + Math.min(...ys)) / 2,
  };
}
