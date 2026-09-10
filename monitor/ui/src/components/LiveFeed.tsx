import { useEffect, useMemo, useState } from "react";
import type { FeedItem, FeedKind, SessionSnapshot } from "../../../src/types.js";
import { clock } from "../format.js";
import { loadHidden, nextHidden, pruneHidden, saveHidden } from "./feedFilter.js";
import { Empty } from "./ui.js";

const KIND: Record<FeedKind, { color: string; mono: boolean }> = {
  tool: { color: "text-sky-300", mono: true },
  prompt: { color: "text-violet-300", mono: false },
  message: { color: "text-slate-400", mono: false },
  status: { color: "text-amber-300", mono: false },
  session: { color: "text-emerald-300", mono: false },
  agent: { color: "text-fuchsia-300", mono: false },
};

/** 同じプロジェクトに複数セッションがある時だけブランチを添えて区別する。 */
function chipLabel(s: SessionSnapshot, all: SessionSnapshot[]): string {
  const dup = all.filter((x) => x.project === s.project).length > 1;
  if (!dup) return s.project;
  return s.branch ? `${s.project}:${s.branch}` : `${s.project}#${s.pid}`;
}

export function LiveFeed({
  items,
  sessions,
}: {
  items: FeedItem[];
  sessions: SessionSnapshot[];
}) {
  const [hidden, setHidden] = useState<string[]>(loadHidden);

  // 保存はここ 1 箇所に寄せる（更新関数の中で副作用を起こさない）。
  useEffect(() => saveHidden(hidden), [hidden]);

  // 一覧にも履歴にも無くなった設定だけ捨てる。フィードに残っている分は隠したままにする。
  const knownIds = useMemo(() => {
    const ids = new Set(sessions.map((s) => s.sessionId));
    for (const i of items) ids.add(i.sessionId);
    return [...ids];
  }, [sessions, items]);

  useEffect(() => {
    if (!knownIds.length) return;
    setHidden((prev) => {
      const next = pruneHidden(prev, knownIds);
      return next.length === prev.length ? prev : next;
    });
  }, [knownIds]);

  const hiddenSet = useMemo(() => new Set(hidden), [hidden]);
  const visible = useMemo(
    () => items.filter((i) => !hiddenSet.has(i.sessionId)),
    [items, hiddenSet],
  );
  const counts = useMemo(() => {
    const m = new Map<string, number>();
    for (const i of items) m.set(i.sessionId, (m.get(i.sessionId) ?? 0) + 1);
    return m;
  }, [items]);

  const allIds = useMemo(() => sessions.map((s) => s.sessionId), [sessions]);
  const toggle = (id: string, only: boolean) =>
    setHidden((prev) => nextHidden(prev, allIds, id, only));

  // チップはステータス順に動かさない。押そうとした対象が入れ替わるのを防ぐ。
  const chipSessions = useMemo(
    () =>
      [...sessions].sort(
        (a, b) => a.project.localeCompare(b.project) || a.sessionId.localeCompare(b.sessionId),
      ),
    [sessions],
  );

  const shownCount = sessions.length - sessions.filter((s) => hiddenSet.has(s.sessionId)).length;
  const filtering = hidden.length > 0;

  return (
    <div className="glass sticky top-5 flex max-h-[calc(100vh-2.5rem)] flex-col">
      <h2 className="card-title mb-0 flex items-center gap-2 border-b border-white/8 px-4 py-3">
        <span>ライブフィード</span>
        {filtering && (
          <span className="rounded-full bg-amber-400/10 px-1.5 text-[10px] font-semibold text-amber-300">
            {shownCount}/{sessions.length}
          </span>
        )}
      </h2>

      {(chipSessions.length > 0 || filtering) && (
        <div className="flex flex-wrap gap-1 border-b border-white/8 px-3 py-2">
          <button
            onClick={() => setHidden([])}
            disabled={!filtering}
            className={`rounded-full border px-2 py-0.5 text-[10px] transition disabled:opacity-40 ${
              filtering
                ? "border-white/12 bg-white/5 text-slate-300 hover:bg-white/10"
                : "border-emerald-400/30 bg-emerald-400/10 text-emerald-300"
            }`}
          >
            すべて
          </button>
          {chipSessions.map((s) => {
            const off = hiddenSet.has(s.sessionId);
            return (
              <button
                key={s.sessionId}
                onClick={(e) => toggle(s.sessionId, e.altKey)}
                title={`${s.cwd}\n${s.branch ?? ""}\n直近の記録 ${counts.get(s.sessionId) ?? 0} 件\nOption+クリックでこれだけ表示`}
                className={`inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[10px] transition ${
                  off
                    ? "border-white/8 bg-transparent text-slate-600 line-through"
                    : "border-white/12 bg-white/5 text-slate-300 hover:bg-white/10"
                }`}
              >
                <span className="max-w-[110px] truncate">{chipLabel(s, chipSessions)}</span>
                <span className={off ? "text-slate-700" : "text-slate-500"}>
                  {counts.get(s.sessionId) ?? 0}
                </span>
              </button>
            );
          })}
        </div>
      )}

      <div className="overflow-y-auto px-2 py-2">
        {visible.length === 0 ? (
          <Empty>{filtering ? "選んだセッションの動きはまだありません" : "まだ動きがありません"}</Empty>
        ) : (
          visible.map((item) => {
            const kind = KIND[item.kind] ?? KIND.message;
            return (
              <div key={item.id} className="grid grid-cols-[46px_1fr] gap-2 rounded-lg px-2 py-1.5">
                <time className="pt-px text-[10.5px] tabular-nums text-slate-600">
                  {clock(item.at)}
                </time>
                <div className="min-w-0">
                  <div className={`text-[10.5px] font-semibold ${kind.color}`}>{item.project}</div>
                  <div
                    className={`break-words text-[12px] text-slate-400 ${kind.mono ? "font-mono text-slate-300" : ""}`}
                  >
                    {item.text}
                  </div>
                </div>
              </div>
            );
          })
        )}
      </div>
    </div>
  );
}
