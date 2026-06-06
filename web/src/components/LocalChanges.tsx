import { FolderGit2 } from "lucide-react";
import type { Project } from "../../../shared/types.js";
import { Card, Empty } from "./ui.js";

export function LocalChanges({ projects }: { projects: Project[] }) {
  const dirty = projects.filter((p) => p.git?.dirty);
  return (
    <Card title="ローカル未コミット" icon={<FolderGit2 size={15} />} accent="text-amber-300" count={dirty.length}>
      {dirty.length === 0 ? (
        <Empty>クリーン</Empty>
      ) : (
        <div className="divide-y divide-white/5">
          {dirty.map((p) => (
            <div key={p.name} className="flex items-center gap-2 py-2 text-[13px]">
              <span className="chip">{p.name}</span>
              <span className="text-slate-200">
                未コミット <span className="tabular-nums">{p.git!.dirty}</span> 件
              </span>
              {p.git!.ahead ? (
                <span className="text-[12px] text-slate-500">/ 未push {p.git!.ahead} 件</span>
              ) : null}
            </div>
          ))}
        </div>
      )}
    </Card>
  );
}
