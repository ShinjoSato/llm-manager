// 動きを減らす設定の参照。2D の CSS と同じ条件で、脈も跳ねも止める。
const media =
  typeof window !== "undefined" && window.matchMedia
    ? window.matchMedia("(prefers-reduced-motion: reduce)")
    : null;

/** 毎フレーム読む。設定を切り替えても描き直しを待たずに効く。 */
export function prefersStill(): boolean {
  return media?.matches ?? false;
}
