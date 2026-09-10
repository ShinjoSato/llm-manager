// 回転させた立体が枠からはみ出さない倍率を出す。
// 枠は 2D 表示の SVG と同じ寸法にしてあるので、3D にしても並びが動かない。

export interface Size {
  width: number;
  height: number;
}

/**
 * 直方体を Y → X の順に回した時の、正射影での見かけの幅と高さ。
 * 群を <group rotation-x><group rotation-y> と入れ子にした順序に合わせてある。
 */
export function projectedSize(
  width: number,
  height: number,
  depth: number,
  rotX: number,
  rotY: number,
): Size {
  const cy = Math.cos(rotY);
  const sy = Math.sin(rotY);
  const cx = Math.cos(rotX);
  const sx = Math.sin(rotX);
  let maxX = 0;
  let maxY = 0;

  for (const ex of [-width / 2, width / 2]) {
    for (const ey of [-height / 2, height / 2]) {
      for (const ez of [-depth / 2, depth / 2]) {
        const x = ex * cy + ez * sy;
        const z = -ex * sy + ez * cy;
        maxX = Math.max(maxX, Math.abs(x));
        maxY = Math.max(maxY, Math.abs(ey * cx - z * sx));
      }
    }
  }

  return { width: maxX * 2, height: maxY * 2 };
}

/** 枠に収まる倍率。2D より大きく見せたくないので 1 を上限にする。 */
export function fitScale(box: Size, projected: Size): number {
  const byWidth = projected.width > 0 ? box.width / projected.width : 1;
  const byHeight = projected.height > 0 ? box.height / projected.height : 1;
  return Math.min(1, byWidth, byHeight);
}
