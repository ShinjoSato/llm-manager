import type { ReactNode } from "react";

export function StatCard({
  icon,
  label,
  value,
  sub,
  accent = "text-emerald-300",
  onClick,
  hint,
}: {
  icon: ReactNode;
  label: string;
  value: ReactNode;
  sub?: ReactNode;
  accent?: string;
  /** 渡すと押せるカードになる。 */
  onClick?: () => void;
  hint?: string;
}) {
  const Tag = onClick ? "button" : "div";
  return (
    <Tag
      {...(onClick ? { type: "button" as const, onClick } : {})}
      title={hint}
      className={`glass flex items-center gap-3.5 p-4 text-left ${
        onClick ? "cursor-pointer transition hover:bg-white/[0.07]" : ""
      }`}
    >
      <div
        className={`grid h-11 w-11 place-items-center rounded-xl border border-white/10 bg-white/5 ${accent}`}
      >
        {icon}
      </div>
      <div className="min-w-0">
        <div className="text-[11px] uppercase tracking-wider text-slate-400">{label}</div>
        <div className="flex items-baseline gap-1.5">
          <span className="text-2xl font-semibold leading-tight tabular-nums text-slate-50">
            {value}
          </span>
          {sub && <span className="truncate text-[12px] text-slate-400">{sub}</span>}
        </div>
      </div>
    </Tag>
  );
}

export function Empty({ children = "（なし）" }: { children?: ReactNode }) {
  return <div className="py-2 text-[13px] text-slate-500">{children}</div>;
}
