import { Activity, AlertTriangle, Bell, BellOff, Layers, Pause, Radio } from "lucide-react";
import { useMemo } from "react";
import { LiveFeed } from "./components/LiveFeed.js";
import { SessionCard } from "./components/SessionCard.js";
import { StatCard } from "./components/ui.js";
import { styleOf } from "./status.js";
import { useMonitor, useNow } from "./useMonitor.js";
import { useNotify } from "./useNotify.js";

export function App() {
  const { sessions, feed, connected } = useMonitor();
  const now = useNow();
  const notify = useNotify(sessions);

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

        <div className="ml-auto flex items-center gap-1.5">
          <NotifyToggle
            label="要対応"
            hint="許可待ち・入力待ち・エラーになった時に知らせる"
            on={notify.setting.attention}
            onClick={() =>
              void notify.update({ ...notify.setting, attention: !notify.setting.attention })
            }
          />
          <NotifyToggle
            label="待機"
            hint="応答が終わって次の指示待ちになった時に知らせる"
            on={notify.setting.idle}
            onClick={() => void notify.update({ ...notify.setting, idle: !notify.setting.idle })}
          />
          {notify.needsPermission && (
            <button
              onClick={() => void notify.requestPermission()}
              className="rounded-full border border-amber-400/30 bg-amber-400/10 px-2 py-0.5 text-[10px] text-amber-300 transition hover:bg-amber-400/20"
            >
              通知を許可する
            </button>
          )}
          {notify.lastAttempt && (
            <span className="text-[10px] text-slate-500" title="直近に検出した状態変化">
              {notify.lastAttempt}
            </span>
          )}
          {notify.permission === "granted" && (
            <button
              onClick={notify.test}
              title="通知が実際に出せるかを確かめる"
              className="rounded-full border border-white/10 bg-white/5 px-2 py-0.5 text-[10px] text-slate-400 transition hover:bg-white/10"
            >
              通知を試す
            </button>
          )}
          {notify.permission === "denied" && (
            <span className="text-[10px] text-rose-300">
              通知がブラウザで拒否されています（サイト設定から許可してください）
            </span>
          )}
          {notify.permission === "unsupported" && (
            <span className="text-[10px] text-slate-500">このブラウザは通知に未対応</span>
          )}
        </div>
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

function NotifyToggle({
  label,
  hint,
  on,
  onClick,
}: {
  label: string;
  hint: string;
  on: boolean;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      title={hint}
      aria-pressed={on}
      className={`inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[10px] transition ${
        on
          ? "border-emerald-400/30 bg-emerald-400/10 text-emerald-300"
          : "border-white/10 bg-white/5 text-slate-500 hover:bg-white/10"
      }`}
    >
      {on ? <Bell size={10} /> : <BellOff size={10} />}
      {label}
    </button>
  );
}
