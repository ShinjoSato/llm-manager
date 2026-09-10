import { useCallback, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";

/** アンカーと吹き出しの間隔。 */
const GAP = 10;
/** 画面端から空けるマージン。 */
const EDGE = 8;

export interface TooltipRow {
  label: string;
  value: string;
  /** 種別やパスなど、等幅で読みたい値。 */
  mono?: boolean;
}

/**
 * ドット絵に添える吹き出し。
 * カードが overflow-hidden なので、本文直下へポータルして端で切れないようにする。
 */
export function Tooltip({
  title,
  subtitle,
  rows,
  focusable = true,
  children,
}: {
  title: string;
  subtitle?: string;
  rows?: TooltipRow[];
  /** 子スプライトのように数が多いものはタブ順から外す。 */
  focusable?: boolean;
  children: ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const anchor = useRef<HTMLSpanElement>(null);
  const tip = useRef<HTMLDivElement>(null);

  /** 実寸を測ってから置く。内容で高さが変わるので、閾値では決められない。 */
  const place = useCallback(() => {
    const a = anchor.current;
    const t = tip.current;
    if (!a || !t) return;
    const ar = a.getBoundingClientRect();
    const tr = t.getBoundingClientRect();
    const vw = document.documentElement.clientWidth;
    const vh = document.documentElement.clientHeight;

    const above = ar.top - tr.height - GAP >= EDGE;
    const top = above ? ar.top - GAP - tr.height : ar.bottom + GAP;
    const left = ar.left + ar.width / 2 - tr.width / 2;

    t.style.top = `${clamp(top, EDGE, vh - tr.height - EDGE)}px`;
    t.style.left = `${clamp(left, EDGE, vw - tr.width - EDGE)}px`;
    t.style.visibility = "visible";
  }, []);

  const hide = useCallback(() => setOpen(false), []);

  useLayoutEffect(() => {
    if (!open) return;
    place();
    // スクロールやリサイズで置き去りにならないよう追従する（キーボード操作中は blur が来ない）。
    const onMove = () => place();
    window.addEventListener("scroll", onMove, true);
    window.addEventListener("resize", onMove);
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") hide();
    };
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("scroll", onMove, true);
      window.removeEventListener("resize", onMove);
      window.removeEventListener("keydown", onKey);
    };
  }, [open, place, hide]);

  return (
    <>
      <span
        ref={anchor}
        tabIndex={focusable ? 0 : -1}
        onMouseEnter={() => setOpen(true)}
        onMouseLeave={hide}
        onFocus={() => setOpen(true)}
        onBlur={hide}
        className="inline-flex rounded outline-none focus-visible:ring-1 focus-visible:ring-emerald-400/50"
      >
        {children}
      </span>
      {open &&
        createPortal(
          <div
            ref={tip}
            role="tooltip"
            // 実寸を測るまでは見せない。measure 前に描くと一瞬ずれた位置に出る。
            style={{ position: "fixed", top: 0, left: 0, visibility: "hidden", maxWidth: 340 }}
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

function clamp(v: number, min: number, max: number): number {
  return Math.min(Math.max(v, min), Math.max(min, max));
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
