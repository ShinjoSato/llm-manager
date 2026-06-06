import { CalendarDays } from "lucide-react";
import type { CalendarData } from "../../../shared/types.js";
import { Card, Empty } from "./ui.js";

const WD = ["日", "月", "火", "水", "木", "金", "土"];

function fmt(ev: { start: string; allDay: boolean }): string {
  const d = new Date(ev.start);
  if (Number.isNaN(d.getTime())) return ev.start;
  const md = `${d.getMonth() + 1}/${d.getDate()}(${WD[d.getDay()]})`;
  if (ev.allDay) return `${md} 終日`;
  const hm = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  return `${md} ${hm}`;
}

export function CalendarCard({ calendar }: { calendar?: CalendarData | null }) {
  // 未設定（null）なら表示しない
  if (!calendar) return null;
  const { events, error } = calendar;
  return (
    <Card title={`今後の予定（${calendar.rangeDays}日）`} icon={<CalendarDays size={15} />} accent="text-cyan-300" count={events.length}>
      {error ? (
        <div className="py-2 text-[12px] text-rose-300">⚠ {error}</div>
      ) : events.length === 0 ? (
        <Empty>予定なし</Empty>
      ) : (
        <div className="divide-y divide-white/5">
          {events.map((ev) => (
            <div key={ev.id} className="flex items-baseline gap-3 py-2 text-[13px]">
              <span className="w-24 shrink-0 font-mono text-[12px] text-slate-400">{fmt(ev)}</span>
              {ev.url ? (
                <a className="link" href={ev.url} target="_blank" rel="noreferrer">{ev.title}</a>
              ) : (
                <span className="text-slate-100">{ev.title}</span>
              )}
              {ev.location && <span className="ml-auto truncate text-[11px] text-slate-500">{ev.location}</span>}
            </div>
          ))}
        </div>
      )}
    </Card>
  );
}
