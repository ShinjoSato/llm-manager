import { AlertTriangle, Pin, Tag } from "lucide-react";
import type { Highlight } from "../hooks.js";
import { Card, Empty } from "./ui.js";

export function Highlights({ items }: { items: Highlight[] }) {
  return (
    <Card title="要注目" icon={<AlertTriangle size={15} />} accent="text-rose-400" count={items.length}>
      {items.length === 0 ? (
        <Empty>いまは要注目なし</Empty>
      ) : (
        <div className="space-y-2.5">
          {items.map((h) => (
            <div
              key={`${h.proj}#${h.item.number}`}
              className={`relative overflow-hidden rounded-xl border bg-white/[0.02] p-3 pl-4 ${
                h.pinned ? "border-rose-500/30" : "border-amber-500/25"
              }`}
            >
              <span
                className={`absolute inset-y-0 left-0 w-1 ${h.pinned ? "bg-rose-500/70" : "bg-amber-500/60"}`}
              />
              <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
                <span className="chip">{h.proj}</span>
                {h.item.url ? (
                  <a className="link font-mono text-[13px]" href={h.item.url} target="_blank" rel="noreferrer">
                    #{h.item.number}
                  </a>
                ) : (
                  <span className="font-mono text-[13px] text-slate-400">#{h.item.number}</span>
                )}
                <span className="text-[13.5px] text-slate-100">{h.item.title}</span>
                <span className="ml-auto text-[11px] text-slate-500">{h.item.status}</span>
              </div>
              <div className="mt-1.5 flex items-center gap-1.5 text-[12px] text-slate-400">
                {h.pinned ? <Pin size={12} className="text-rose-400" /> : <Tag size={12} className="text-amber-400" />}
                {h.why}
              </div>
            </div>
          ))}
        </div>
      )}
    </Card>
  );
}
