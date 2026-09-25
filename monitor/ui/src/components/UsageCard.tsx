import type { ReactNode } from "react";
import type { UsageWindow } from "../../../src/types.js";
import { ago, remainingPct, until } from "../format.js";
import { USAGE_THRESHOLD } from "../useNotify.js";
import { StatCard } from "./ui.js";

// statusline は Claude Code が動いている間しか呼ばれない。これを超えたら古い値として見せる。
export const USAGE_STALE_MS = 10 * 60_000;

/** 上限ウィンドウの残り。取得時刻も添えて、セッション停止中の古い値と区別できるようにする。 */
export function UsageCard({
  icon,
  label,
  window: w,
  fetchedAt,
  now,
}: {
  icon: ReactNode;
  label: string;
  window: UsageWindow | null;
  fetchedAt: number | null;
  now: number;
}) {
  if (!w || fetchedAt === null) {
    return (
      <StatCard
        icon={icon}
        accent="text-slate-500"
        label={label}
        value="—"
        sub="statusLine 未設定"
      />
    );
  }
  const left = remainingPct(w.usedPercentage);
  const stale = now - fetchedAt > USAGE_STALE_MS;
  const parts = [
    w.resetsAt !== null ? `リセット ${until(w.resetsAt, now)}` : null,
    `取得 ${ago(fetchedAt, now)}`,
  ];
  return (
    <StatCard
      icon={icon}
      accent={
        left < USAGE_THRESHOLD ? "text-rose-300" : left < 40 ? "text-amber-300" : "text-sky-300"
      }
      label={label}
      value={`${Math.round(left)}%`}
      sub={
        <span
          className={stale ? "text-amber-300" : undefined}
          title={stale ? "稼働中のセッションが無い間は更新されません" : undefined}
        >
          {parts.filter(Boolean).join(" · ")}
        </span>
      }
    />
  );
}
