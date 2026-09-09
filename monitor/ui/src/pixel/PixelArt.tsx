import { useMemo } from "react";
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

export function PixelArt({
  sprite,
  palette,
  scale = 4,
  className = "",
  style,
  title,
}: {
  sprite: Sprite;
  palette: Palette;
  scale?: number;
  className?: string;
  style?: React.CSSProperties;
  title?: string;
}) {
  const runs = useMemo(() => toRuns(sprite), [sprite]);
  const w = useMemo(() => Math.max(...sprite.map((r) => r.length)), [sprite]);
  const h = sprite.length;

  return (
    <svg
      viewBox={`0 0 ${w} ${h}`}
      width={w * scale}
      height={h * scale}
      shapeRendering="crispEdges"
      className={className}
      style={style}
      role={title ? "img" : undefined}
      aria-hidden={title ? undefined : "true"}
    >
      {title && <title>{title}</title>}
      {runs.map((r, i) => {
        const fill = palette[r.ch];
        if (!fill) return null;
        return <rect key={i} x={r.x} y={r.y} width={r.w} height={1} fill={fill} />;
      })}
    </svg>
  );
}
