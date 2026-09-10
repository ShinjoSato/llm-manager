import { memo, useMemo, type CSSProperties } from "react";
import type { Sprite } from "./sprites.js";

export type Palette = Record<string, string>;

interface Run {
  x: number;
  y: number;
  w: number;
  ch: string;
}

/** 横に連続する同色を 1 つの rect にまとめる。1 マス 1 rect だと要素数が数倍になる。 */
function toRuns(rows: Sprite): Run[] {
  const out: Run[] = [];
  rows.forEach((row, y) => {
    let i = 0;
    while (i < row.length) {
      const ch = row[i]!;
      let j = i;
      while (j < row.length && row[j] === ch) j++;
      if (ch !== ".") out.push({ x: i, y, w: j - i, ch });
      i = j;
    }
  });
  return out;
}

export const PixelArt = memo(function PixelArt({
  sprite,
  palette,
  scale = 4,
  className = "",
  style,
  label,
}: {
  sprite: Sprite;
  palette: Palette;
  scale?: number;
  className?: string;
  style?: CSSProperties;
  /** 読み上げ用。見えるツールチップは Tooltip が担う（<title> だと二重に出る）。 */
  label?: string;
}) {
  const runs = useMemo(() => toRuns(sprite), [sprite]);
  // 空配列だと Math.max が -Infinity を返して viewBox が壊れる。
  const w = useMemo(() => (sprite.length ? Math.max(...sprite.map((r) => r.length)) : 0), [sprite]);
  const h = sprite.length;

  return (
    <svg
      viewBox={`0 0 ${w} ${h}`}
      width={w * scale}
      height={h * scale}
      shapeRendering="crispEdges"
      className={className}
      style={style}
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : "true"}
    >
      {runs.map((r, i) => {
        const fill = palette[r.ch];
        if (!fill) return null;
        return <rect key={i} x={r.x} y={r.y} width={r.w} height={1} fill={fill} />;
      })}
    </svg>
  );
});
