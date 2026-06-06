import { LayoutGrid, GitBranch } from "lucide-react";
import type { Project } from "../../../shared/types.js";
import { Card, ProgressRing } from "./ui.js";

const STATUS_ORDER = ["Todo", "In Progress", "Review", "Debug", "Done"];
const STATUS_COLOR: Record<string, string> = {
  Todo: "bg-slate-400",
  "In Progress": "bg-cyan-400",
  Review: "bg-violet-400",
  Debug: "bg-amber-400",
  Done: "bg-emerald-400",
};

function ProjectRow({ p }: { p: Project }) {
  const b = p.board;
  if (!b || !b.counts || Object.keys(b.counts).length === 0) {
    return (
      <div className="flex items-center gap-3 py-3">
        <div className="grid h-14 w-14 shrink-0 place-items-center rounded-full border border-white/10 text-slate-500">
          <GitBranch size={18} />
        </div>
        <div>
          <div className="font-semibold text-slate-100">{p.name}</div>
          <div className="text-[12px] text-slate-500">ボードなし · {p.git?.branch ?? "?"}</div>
        </div>
      </div>
    );
  }
  const c = b.counts;
  const wip = (c["In Progress"] ?? 0) + (c["Review"] ?? 0);
  const total = STATUS_ORDER.reduce((s, k) => s + (c[k] ?? 0), 0) || 1;

  return (
    <div className="flex items-center gap-4 py-3">
      <ProgressRing pct={b.doneRate} />
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="font-semibold text-slate-100">{p.name}</span>
          {wip >= 5 && (
            <span className="badge badge-warn">WIP {wip}</span>
          )}
          {b.url && (
            <a className="link ml-auto text-[11px]" href={b.url} target="_blank" rel="noreferrer">
              board ↗
            </a>
          )}
        </div>
        {/* 積み上げバー */}
        <div className="mt-2 flex h-2 overflow-hidden rounded-full bg-white/5">
          {STATUS_ORDER.filter((s) => c[s]).map((s) => (
            <div key={s} className={STATUS_COLOR[s]} style={{ width: `${((c[s] ?? 0) / total) * 100}%` }} />
          ))}
        </div>
        <div className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-[12px] text-slate-400">
          {STATUS_ORDER.filter((s) => c[s]).map((s) => (
            <span key={s} className="inline-flex items-center gap-1.5">
              <span className={`h-2 w-2 rounded-full ${STATUS_COLOR[s]}`} />
              {s.split(" ")[0]}
              <span className="tabular-nums text-slate-300">{c[s]}</span>
            </span>
          ))}
        </div>
      </div>
    </div>
  );
}

export function ProjectSummary({ projects }: { projects: Project[] }) {
  return (
    <Card title="各プロジェクト" icon={<LayoutGrid size={15} />} accent="text-cyan-400" count={projects.length}>
      <div className="divide-y divide-white/5">
        {projects.map((p) => (
          <ProjectRow key={p.name} p={p} />
        ))}
      </div>
    </Card>
  );
}
