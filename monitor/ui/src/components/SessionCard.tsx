import { GitBranch } from "lucide-react";
import type { SessionSnapshot } from "../../../src/types.js";
import { ago, dur, kilo } from "../format.js";
import { AgentStage } from "../pixel/AgentStage.js";
import { itemForVerb, jobFor, skillLabel } from "../pixel/kit.js";
import { styleOf } from "../status.js";

/** いま何をしているかの一行。スキルの銘 > 具体的な説明 > 持ち物の動作 の順に選ぶ。 */
function actionLine(s: SessionSnapshot): string | null {
  if (s.status !== "working") return null;
  if (s.currentSkill) return `巻物『${skillLabel(s.currentSkill)}』を広げている`;
  if (s.currentAction) return s.currentAction;
  return itemForVerb(s.currentTool);
}

function escortLine(s: SessionSnapshot): string | null {
  if (!s.agents.length) return null;
  // agents は更新時刻順なので、代表者は id 順で選んで文言のちらつきを防ぐ。
  const head = [...s.agents].sort((a, b) => a.id.localeCompare(b.id))[0]!;
  const first = jobFor(head.type).label;
  return s.agents.length > 1 ? `${first} ほか${s.agents.length - 1}名が随伴` : `${first}が随伴`;
}

export function SessionCard({ s, now }: { s: SessionSnapshot; now: number }) {
  const st = styleOf(s.status);
  const action = actionLine(s);
  const escort = escortLine(s);

  return (
    <div className="glass relative overflow-hidden p-4">
      <div className={`absolute inset-y-0 left-0 w-[3px] ${st.bar}`} />

      <div className="mb-1 flex items-center gap-2">
        <span className="truncate text-[14px] font-semibold text-slate-100">{s.project}</span>
        {s.branch && (
          <span className="chip inline-flex max-w-[150px] items-center gap-1 font-mono">
            <GitBranch size={10} className="shrink-0 text-slate-500" />
            <span className="truncate">{s.branch}</span>
          </span>
        )}
        <span className={`badge ml-auto ${st.badge}`}>
          <i className={`h-1.5 w-1.5 rounded-full ${st.dot} ${st.breathe ? "breathe" : ""}`} />
          {st.label}
        </span>
      </div>

      <AgentStage
        status={s.status}
        tool={s.currentTool}
        skill={s.currentSkill}
        agents={s.agents}
      />

      <div className="mb-2 min-h-[36px] px-1 text-center">
        {action && <div className="truncate text-[12px] text-emerald-300">{action}</div>}
        {s.statusDetail && s.status !== "working" && (
          <div className="truncate text-[12px] text-amber-300">{s.statusDetail}</div>
        )}
        {escort && <div className="truncate text-[11px] text-violet-300">{escort}</div>}
        <div className="truncate text-[11.5px] text-slate-400" title={s.title ?? undefined}>
          {s.title ?? "（作業内容 未確定）"}
        </div>
      </div>

      <div className="flex flex-wrap gap-x-3 gap-y-1 border-t border-white/8 pt-2 text-[11px] tabular-nums text-slate-500">
        <span>最終活動 {ago(s.lastActivityAt, now)}</span>
        <span>稼働 {dur(s.startedAt, now)}</span>
        {s.tokens && <span>キャッシュ {kilo(s.tokens.cacheRead)}</span>}
        <span className="ml-auto">{s.statusSource === "hook" ? "hook" : "log"}</span>
      </div>
    </div>
  );
}
