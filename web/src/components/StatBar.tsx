import { AlertTriangle, CalendarClock, Gauge, Loader, GitPullRequest, Smartphone } from "lucide-react";
import type { Dashboard, UsageWindow } from "../../../shared/types.js";
import type { Highlight } from "../hooks.js";
import { StatCard } from "./ui.js";

/** 残りがこれを割ったら赤で出す。 */
const LOW_REMAINING = 20;

export function StatBar({ dash, highlights }: { dash: Dashboard; highlights: Highlight[] }) {
  const wip = dash.projects.reduce((s, p) => {
    const c = p.board?.counts ?? {};
    return s + (c["In Progress"] ?? 0) + (c["Review"] ?? 0);
  }, 0);
  const prs = dash.projects.reduce((s, p) => s + p.prs.length, 0);

  const apps = dash.projects.filter((p) => p.appstore && !p.appstore.error);
  const appStates = [
    ...new Set(apps.map((p) => p.appstore!.versions?.[0]?.stateLabel).filter(Boolean)),
  ].join(" / ");

  // statusLine 未設定ならファイルが無く usage は null。その時は残量カードを出さない。
  const usage = dash.usage ?? null;

  return (
    <div className={`grid grid-cols-2 gap-3 ${usage ? "md:grid-cols-3 xl:grid-cols-6" : "md:grid-cols-4"}`}>
      <StatCard
        icon={<AlertTriangle size={18} />}
        accent="text-rose-300"
        label="要注目"
        value={highlights.length}
        sub="pin + キーワード"
      />
      <StatCard
        icon={<Loader size={18} />}
        accent="text-cyan-300"
        label="WIP"
        value={wip}
        sub="進行中 + レビュー"
      />
      <StatCard
        icon={<GitPullRequest size={18} />}
        accent="text-emerald-300"
        label="オープン PR"
        value={prs}
      />
      <StatCard
        icon={<Smartphone size={18} />}
        accent="text-violet-300"
        label="App Store"
        value={apps.length}
        sub={appStates || "—"}
      />
      {usage && (
        <UsageCard
          icon={<Gauge size={18} />}
          label="5h 残り"
          window={usage.fiveHour}
          fetchedAt={usage.fetchedAt}
        />
      )}
      {usage && (
        <UsageCard
          icon={<CalendarClock size={18} />}
          label="週 残り"
          window={usage.sevenDay}
          fetchedAt={usage.fetchedAt}
        />
      )}
    </div>
  );
}

/** Claude Code の上限ウィンドウの残り。取得時刻も出す（セッション停止中は更新されないため）。 */
function UsageCard({
  icon,
  label,
  window: w,
  fetchedAt,
}: {
  icon: React.ReactNode;
  label: string;
  window: UsageWindow | null;
  fetchedAt: number;
}) {
  if (!w) {
    return <StatCard icon={icon} accent="text-slate-500" label={label} value="—" sub="未取得" />;
  }
  const left = Math.max(0, Math.min(100, 100 - w.usedPercentage));
  return (
    <StatCard
      icon={icon}
      accent={left < LOW_REMAINING ? "text-rose-300" : left < 40 ? "text-amber-300" : "text-sky-300"}
      label={label}
      value={`${Math.round(left)}%`}
      sub={`${stamp(fetchedAt)} 取得`}
    />
  );
}

function stamp(ms: number): string {
  const d = new Date(ms);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${pad(d.getMonth() + 1)}/${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
