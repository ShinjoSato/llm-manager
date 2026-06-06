import { RefreshCw, Activity } from "lucide-react";
import { useDashboard, computeHighlights } from "./hooks.js";
import { StatBar } from "./components/StatBar.js";
import { Highlights } from "./components/Highlights.js";
import { ProjectSummary } from "./components/ProjectSummary.js";
import { AppStoreCard } from "./components/AppStoreCard.js";
import { PullRequests } from "./components/PullRequests.js";
import { LocalChanges } from "./components/LocalChanges.js";
import { FocusNotes } from "./components/FocusNotes.js";
import { CalendarCard } from "./components/CalendarCard.js";

function Shell({ children }: { children: React.ReactNode }) {
  return <div className="mx-auto max-w-6xl px-5 py-7 md:px-8">{children}</div>;
}

export function App() {
  const { dash, state, busy, error, refresh, saveState } = useDashboard();

  if (error && !dash) {
    return (
      <Shell>
        <div className="glass border-rose-400/30 p-5 text-rose-200">
          API に接続できません: {error}
          <div className="mt-1.5 text-[13px] text-slate-400">
            起動してください: <code className="font-mono">./scripts/dev.sh</code>
          </div>
        </div>
      </Shell>
    );
  }
  if (!dash || !state) {
    return (
      <Shell>
        <div className="flex items-center gap-2 text-slate-400">
          <Activity size={16} className="animate-pulse" /> 読み込み中...
        </div>
      </Shell>
    );
  }

  const gen = dash.generatedAt.slice(0, 16).replace("T", " ");
  const highlights = computeHighlights(dash, state);

  return (
    <Shell>
      {/* ヘッダー */}
      <header className="mb-6 flex flex-wrap items-center gap-4">
        <div className="flex items-center gap-3">
          <div className="grid h-10 w-10 place-items-center rounded-xl border border-emerald-400/30 bg-emerald-400/10 text-emerald-300">
            <Activity size={18} />
          </div>
          <div>
            <h1 className="text-lg font-semibold leading-tight text-slate-50">ai-manager</h1>
            <p className="text-[11px] uppercase tracking-[0.18em] text-slate-500">manager dashboard</p>
          </div>
        </div>
        <div className="ml-auto flex items-center gap-3">
          <span className="text-[12px] text-slate-500">更新 {gen}</span>
          <button className="btn btn-primary" onClick={refresh} disabled={busy}>
            <RefreshCw size={14} className={busy ? "animate-spin" : ""} />
            {busy ? "取得中..." : "最新を取得"}
          </button>
        </div>
      </header>

      {error && (
        <div className="glass mb-4 border-rose-400/30 p-3 text-[13px] text-rose-200">再取得に失敗: {error}</div>
      )}

      {/* KPI */}
      <StatBar dash={dash} highlights={highlights} />

      {/* 本体グリッド */}
      <div className="mt-5 grid grid-cols-1 gap-5 lg:grid-cols-[1.4fr_1fr]">
        <div className="flex flex-col gap-5">
          <Highlights items={highlights} />
          <ProjectSummary projects={dash.projects} />
          <AppStoreCard projects={dash.projects} />
        </div>
        <div className="flex flex-col gap-5">
          <FocusNotes state={state} onSave={saveState} />
          <CalendarCard calendar={dash.calendar} />
          <PullRequests projects={dash.projects} />
          <LocalChanges projects={dash.projects} />
        </div>
      </div>

      <footer className="mt-8 text-center text-[11px] text-slate-600">
        ai-manager · React + Tailwind · 同じデータ中核を MCP / HTTP で共有
      </footer>
    </Shell>
  );
}
