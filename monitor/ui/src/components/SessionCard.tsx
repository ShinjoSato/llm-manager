import { GitBranch, Loader, Users } from "lucide-react";
import type { SessionSnapshot } from "../../../src/types.js";
import { ago, dur, kilo } from "../format.js";
import { styleOf } from "../status.js";

export function SessionCard({ s, now }: { s: SessionSnapshot; now: number }) {
  const st = styleOf(s.status);
  const trail = s.recentTools.slice(-6);

  return (
    <div className="glass relative overflow-hidden p-4">
      <div className={`absolute inset-y-0 left-0 w-[3px] ${st.bar}`} />

      <div className="mb-2 flex items-center gap-2">
        <span className="truncate text-[14px] font-semibold text-slate-100">{s.project}</span>
        {s.branch && (
          <span className="chip inline-flex max-w-[150px] items-center gap-1 font-mono">
            <GitBranch size={10} className="shrink-0 text-slate-500" />
            <span className="truncate">{s.branch}</span>
          </span>
        )}
        <span className={`badge ml-auto ${st.badge}`}>
          <i
            className={`h-1.5 w-1.5 rounded-full ${st.dot} ${st.breathe ? "breathe" : ""}`}
          />
          {st.label}
        </span>
      </div>

      <div className={`mb-2 text-[13px] ${s.title ? "text-slate-200" : "text-slate-500"}`}>
        {s.title ?? "（作業内容 未確定）"}
      </div>

      {s.currentTool ? (
        <div className="mb-2 flex items-center gap-1.5 font-mono text-[12px] text-emerald-300">
          <Loader size={11} className="spin-slow shrink-0" />
          {s.currentTool} 実行中
        </div>
      ) : s.activeAgents > 0 ? (
        <div className="mb-2 flex items-center gap-1.5 text-[12px] text-violet-300">
          <Loader size={11} className="spin-slow shrink-0" />
          サブエージェント {s.activeAgents} 実行中
        </div>
      ) : null}

      {s.statusDetail && s.status !== "working" && (
        <div className="mb-2 text-[12px] text-amber-300">{s.statusDetail}</div>
      )}

      <div className="mb-2 flex min-h-[18px] flex-wrap gap-1">
        {trail.map((t, i) => (
          <span
            key={`${i}-${t}`}
            className={`tool-chip ${i === trail.length - 1 ? "border-white/20 text-slate-200" : ""}`}
          >
            {t}
          </span>
        ))}
      </div>

      <div className="flex flex-wrap gap-x-3 gap-y-1 border-t border-white/8 pt-2 text-[11px] tabular-nums text-slate-500">
        <span>最終活動 {ago(s.lastActivityAt, now)}</span>
        <span>稼働 {dur(s.startedAt, now)}</span>
        {s.tokens && <span>キャッシュ {kilo(s.tokens.cacheRead)}</span>}
        {s.activeAgents > 0 && (
          <span className="inline-flex items-center gap-1 text-violet-300">
            <Users size={11} />
            {s.activeAgents}
          </span>
        )}
        <span className="ml-auto">{s.statusSource === "hook" ? "hook" : "log"}</span>
      </div>
    </div>
  );
}
