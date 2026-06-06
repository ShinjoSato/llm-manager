import { AlertTriangle, Loader, GitPullRequest, Smartphone } from "lucide-react";
import type { Dashboard } from "../../../shared/types.js";
import type { Highlight } from "../hooks.js";
import { StatCard } from "./ui.js";

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

  return (
    <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
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
    </div>
  );
}
