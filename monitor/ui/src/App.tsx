import { Activity, AlertTriangle, Layers, Pause, Radio } from "lucide-react";
import { useMemo } from "react";
import { LiveFeed } from "./components/LiveFeed.js";
import { SessionCard } from "./components/SessionCard.js";
import { StatCard } from "./components/ui.js";
import { styleOf } from "./status.js";
import { useMonitor, useNow } from "./useMonitor.js";

export function App() {
  const { sessions, feed, connected } = useMonitor();
  const now = useNow();

  const sorted = useMemo(
    () =>
      [...sessions].sort(
        (a, b) =>
          styleOf(a.status).rank - styleOf(b.status).rank || a.project.localeCompare(b.project),
      ),
    [sessions],
  );

  const count = (f: (s: (typeof sessions)[number]) => boolean) => sessions.filter(f).length;
  const attention = count((s) => ["permission", "waiting", "error"].includes(s.status));

  return (
    <div className="mx-auto max-w-[1700px] p-5">
      <header className="mb-5 flex flex-wrap items-center gap-3">
        <h1 className="text-[15px] font-semibold tracking-wide text-slate-100">
          Claude Code Monitor
        </h1>
        <span
          className={`badge ${
            connected
              ? "border-emerald-400/30 bg-emerald-400/10 text-emerald-300"
              : "border-rose-400/40 bg-rose-500/15 text-rose-300"
          }`}
        >
          <Radio size={11} className={connected ? "breathe" : ""} />
          {connected ? "リアルタイム接続" : "再接続中…"}
        </span>
        <span className="text-[11px] text-slate-500">
          伝言は「別セッションからのメッセージ」として届きます（指示や承認としては扱われません）
        </span>
      </header>

      <div className="mb-5 grid grid-cols-2 gap-3 md:grid-cols-4">
        <StatCard
          icon={<Activity size={18} />}
          accent="text-emerald-300"
          label="稼働中"
          value={count((s) => s.status === "working")}
          sub="ツール実行中"
        />
        <StatCard
          icon={<AlertTriangle size={18} />}
          accent="text-amber-300"
          label="要対応"
          value={attention}
          sub="権限 / 入力待ち"
        />
        <StatCard
          icon={<Pause size={18} />}
          accent="text-slate-300"
          label="待機"
          value={count((s) => s.status === "idle")}
        />
        <StatCard
          icon={<Layers size={18} />}
          accent="text-cyan-300"
          label="セッション"
          value={count((s) => s.alive)}
          sub="稼働中プロセス"
        />
      </div>

      <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="grid content-start gap-3 sm:grid-cols-2 2xl:grid-cols-3">
          {sorted.length === 0 ? (
            <div className="glass col-span-full p-10 text-center text-[13px] text-slate-500">
              稼働中の Claude Code セッションがありません
            </div>
          ) : (
            sorted.map((s) => <SessionCard key={s.sessionId} s={s} now={now} />)
          )}
        </div>
        <LiveFeed items={feed} sessions={sorted} />
      </div>
    </div>
  );
}
