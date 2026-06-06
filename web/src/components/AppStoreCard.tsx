import { Smartphone, ClipboardCheck, Hammer, Star, Activity } from "lucide-react";
import type { Project, AppRecord, AppVersion } from "../../../shared/types.js";
import { Card, Badge, type Tone } from "./ui.js";

function toneOf(state: string): Tone {
  if (/REJECT|UNRESOLVED|FAILED|INVALID/.test(state)) return "danger";
  if (["READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "COMPLETE", "VALID"].includes(state)) return "ok";
  return "neutral";
}

function Row({ icon, label, children }: { icon: React.ReactNode; label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-center gap-2.5 py-1">
      <span className="flex w-12 shrink-0 items-center gap-1 text-[11px] text-slate-500">
        {icon}
        {label}
      </span>
      {children}
    </div>
  );
}

function AppBlock({ name, a }: { name: string; a: AppRecord }) {
  if (a.error) {
    return (
      <div className="py-3">
        <span className="chip">{name}</span> <span className="text-[12px] text-rose-300">⚠ {a.error}</span>
      </div>
    );
  }
  const versions = a.versions ?? [];
  const shown: AppVersion[] = versions.slice(0, 1).concat(versions.slice(1).filter((v) => v.state.includes("REJECT")));
  const sub = a.reviewSubmissions?.[0];
  const build = a.builds?.[0];
  const rv = a.reviews;
  const cats = a.metrics?.categories ?? [];

  return (
    <div className="py-3">
      <div className="mb-1.5 flex items-center gap-2">
        <span className="font-semibold text-slate-100">{a.appName || name}</span>
        <span className="font-mono text-[11px] text-slate-500">{a.bundleId}</span>
      </div>
      {shown.map((v) => (
        <Row key={`v${v.version}`} icon={<Smartphone size={12} />} label="審査">
          <Badge tone={toneOf(v.state)}>{v.stateLabel}</Badge>
          <span className="text-[12px] text-slate-400">
            {v.platform} v{v.version} · {v.createdDate}
          </span>
        </Row>
      ))}
      {sub && (
        <Row icon={<ClipboardCheck size={12} />} label="提出">
          <Badge tone={toneOf(sub.state)}>{sub.stateLabel}</Badge>
          <span className="text-[12px] text-slate-400">{sub.submittedDate}</span>
        </Row>
      )}
      {build && (
        <Row icon={<Hammer size={12} />} label="Build">
          <Badge tone={toneOf(build.state)}>{build.stateLabel}</Badge>
          <span className="text-[12px] text-slate-400">
            #{build.build} · {build.uploadedDate}
            {build.expired ? " · 期限切れ" : ""}
          </span>
        </Row>
      )}
      {rv && (rv.total || rv.items.length) ? (
        <Row icon={<Star size={12} />} label="評価">
          <span className="text-[12px] text-slate-300">
            総 {rv.total ?? "?"} 件
            {rv.avgOfRecent != null && (
              <span className="ml-1 text-amber-300">★ {rv.avgOfRecent}</span>
            )}
          </span>
        </Row>
      ) : null}
      {cats.length > 0 && (
        <Row icon={<Activity size={12} />} label="指標">
          <span className="text-[12px] text-slate-400">{cats.slice(0, 6).map((c) => c.category).join(", ")}</span>
        </Row>
      )}
    </div>
  );
}

export function AppStoreCard({ projects }: { projects: Project[] }) {
  const apps = projects.filter((p) => p.appstore);
  if (apps.length === 0) return null;
  return (
    <Card title="App Store" icon={<Smartphone size={15} />} accent="text-violet-300" count={apps.length}>
      <div className="divide-y divide-white/5">
        {apps.map((p) => (
          <AppBlock key={p.name} name={p.name} a={p.appstore!} />
        ))}
      </div>
    </Card>
  );
}
