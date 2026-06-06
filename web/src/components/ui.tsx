import type { ReactNode } from "react";

export function Card({
  title,
  icon,
  count,
  accent,
  children,
  className = "",
}: {
  title: string;
  icon?: ReactNode;
  count?: number | string;
  accent?: string; // tailwind text color class for the icon
  children: ReactNode;
  className?: string;
}) {
  return (
    <section className={`card ${className}`}>
      <h2 className="card-title">
        {icon && <span className={accent ?? "text-slate-400"}>{icon}</span>}
        <span>{title}</span>
        {count !== undefined && <span className="chip ml-auto">{count}</span>}
      </h2>
      {children}
    </section>
  );
}

export type Tone = "neutral" | "ok" | "danger" | "warn";

export function Badge({ tone = "neutral", children }: { tone?: Tone; children: ReactNode }) {
  return <span className={`badge badge-${tone}`}>{children}</span>;
}

export function Empty({ children = "（なし）" }: { children?: ReactNode }) {
  return <div className="py-2 text-[13px] text-slate-500">{children}</div>;
}

export function StatCard({
  icon,
  label,
  value,
  sub,
  accent = "text-emerald-300",
}: {
  icon: ReactNode;
  label: string;
  value: ReactNode;
  sub?: ReactNode;
  accent?: string;
}) {
  return (
    <div className="glass flex items-center gap-3.5 p-4">
      <div className={`grid h-11 w-11 place-items-center rounded-xl border border-white/10 bg-white/5 ${accent}`}>
        {icon}
      </div>
      <div className="min-w-0">
        <div className="text-[11px] uppercase tracking-wider text-slate-400">{label}</div>
        <div className="flex items-baseline gap-1.5">
          <span className="text-2xl font-semibold tabular-nums leading-tight text-slate-50">{value}</span>
          {sub && <span className="truncate text-[12px] text-slate-400">{sub}</span>}
        </div>
      </div>
    </div>
  );
}

/** SVG の進捗リング（doneRate%）。グラデーション + 中央に%表示。 */
export function ProgressRing({ pct, size = 56, stroke = 6 }: { pct: number; size?: number; stroke?: number }) {
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  const off = c * (1 - pct / 100);
  const id = `ring-${size}`;
  const mid = size / 2;
  return (
    <svg width={size} height={size} className="shrink-0">
      <defs>
        <linearGradient id={id} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="#34d399" />
          <stop offset="100%" stopColor="#22d3ee" />
        </linearGradient>
      </defs>
      <g transform={`rotate(-90 ${mid} ${mid})`}>
        <circle cx={mid} cy={mid} r={r} fill="none" stroke="rgba(255,255,255,0.08)" strokeWidth={stroke} />
        <circle
          cx={mid}
          cy={mid}
          r={r}
          fill="none"
          stroke={`url(#${id})`}
          strokeWidth={stroke}
          strokeLinecap="round"
          strokeDasharray={c}
          strokeDashoffset={off}
          style={{ transition: "stroke-dashoffset .6s ease" }}
        />
      </g>
      <text
        x={mid}
        y={mid}
        dominantBaseline="central"
        textAnchor="middle"
        className="fill-slate-100 font-semibold tabular-nums"
        style={{ fontSize: size * 0.28 }}
      >
        {pct}
      </text>
    </svg>
  );
}
