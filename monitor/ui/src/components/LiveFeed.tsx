import type { FeedItem, FeedKind } from "../../../src/types.js";
import { clock } from "../format.js";
import { Empty } from "./ui.js";

const KIND: Record<FeedKind, { color: string; mono: boolean }> = {
  tool: { color: "text-sky-300", mono: true },
  prompt: { color: "text-violet-300", mono: false },
  message: { color: "text-slate-400", mono: false },
  status: { color: "text-amber-300", mono: false },
  session: { color: "text-emerald-300", mono: false },
  agent: { color: "text-fuchsia-300", mono: false },
};

export function LiveFeed({ items }: { items: FeedItem[] }) {
  return (
    <div className="glass sticky top-5 flex max-h-[calc(100vh-2.5rem)] flex-col">
      <h2 className="card-title mb-0 border-b border-white/8 px-4 py-3">ライブフィード</h2>
      <div className="overflow-y-auto px-2 py-2">
        {items.length === 0 ? (
          <Empty>まだ動きがありません</Empty>
        ) : (
          items.map((item) => {
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
