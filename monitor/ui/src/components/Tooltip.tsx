import { useCallback, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";

/** カーソルと吹き出しの間隔。 */
const GAP = 10;
/** 画面端で切れないように空けるマージン。 */
const EDGE = 8;

export interface TooltipRow {
  label: string;
  value: string;
  /** 種別やパスなど、等幅で読みたい値。 */
  mono?: boolean;
}

interface Position {
  x: number;
  y: number;
  /** 上に出すと画面外に出る場合は下に回す。 */
  below: boolean;
}

/**
 * ドット絵に添える吹き出し。
 * カードが overflow-hidden なので、本文直下へポータルして端で切れないようにする。
 */
export function Tooltip({
  title,
  subtitle,
  rows,
  children,
}: {
  title: string;
  subtitle?: string;
  rows?: TooltipRow[];
  children: ReactNode;
}) {
  const [pos, setPos] = useState<Position | null>(null);
  const anchor = useRef<HTMLSpanElement>(null);

  const place = useCallback(() => {
    const el = anchor.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    // 上に出す余地が無ければ下へ。高さは実測前なので概算で判断する。
    const below = r.top < 160;
    setPos({ x: r.left + r.width / 2, y: below ? r.bottom + GAP : r.top - GAP, below });
  }, []);

  const hide = useCallback(() => setPos(null), []);

  return (
    <>
      <span
        ref={anchor}
        tabIndex={0}
        onMouseEnter={place}
        onMouseLeave={hide}
        onFocus={place}
        onBlur={hide}
        className="inline-flex rounded outline-none focus-visible:ring-1 focus-visible:ring-emerald-400/50"
      >
        {children}
      </span>
      {pos &&
        createPortal(
          <div
            role="tooltip"
            style={{
              position: "fixed",
              left: pos.x,
              top: pos.y,
              transform: `translate(-50%, ${pos.below ? "0" : "-100%"})`,
              maxWidth: `calc(100vw - ${EDGE * 2}px)`,
            }}
            className="pointer-events-none z-50 rounded-lg border border-white/12 bg-[#0b1220]/95 px-3 py-2
                       shadow-[0_18px_40px_-18px_rgba(0,0,0,.9)] backdrop-blur-md"
          >
            <div className="text-[12px] font-semibold text-slate-100">{title}</div>
            {subtitle && <div className="mt-0.5 text-[11px] text-slate-400">{subtitle}</div>}
            {rows && rows.length > 0 && (
              <div className="mt-1.5 grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 border-t border-white/8 pt-1.5">
                {rows.map((r) => (
                  <Row key={r.label} row={r} />
                ))}
              </div>
            )}
          </div>,
          document.body,
        )}
    </>
  );
}

function Row({ row }: { row: TooltipRow }) {
  return (
    <>
      <span className="whitespace-nowrap text-[10.5px] text-slate-500">{row.label}</span>
      <span
        className={`text-[11px] text-slate-300 ${row.mono ? "font-mono break-all" : "break-words"}`}
      >
        {row.value}
      </span>
    </>
  );
}
