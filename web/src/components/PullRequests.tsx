import { GitPullRequest } from "lucide-react";
import type { Project } from "../../../shared/types.js";
import { Card, Empty } from "./ui.js";

export function PullRequests({ projects }: { projects: Project[] }) {
  const prs = projects.flatMap((p) => p.prs.map((pr) => ({ ...pr, proj: p.name })));
  return (
    <Card title="オープン PR" icon={<GitPullRequest size={15} />} accent="text-emerald-300" count={prs.length}>
      {prs.length === 0 ? (
        <Empty />
      ) : (
        <div className="divide-y divide-white/5">
          {prs.map((pr) => (
            <div key={`${pr.proj}#${pr.number}`} className="flex flex-wrap items-center gap-2 py-2 text-[13px]">
              <span className="chip">{pr.proj}</span>
              <a className="link font-mono" href={pr.url} target="_blank" rel="noreferrer">
                #{pr.number}
              </a>
              <span className="text-slate-200">{pr.title}</span>
              {pr.isDraft && <span className="badge badge-neutral">draft</span>}
              <span className="ml-auto text-[11px] text-slate-500">{pr.createdAt.slice(0, 10)}〜</span>
            </div>
          ))}
        </div>
      )}
    </Card>
  );
}
