import { TrendingUp } from "lucide-react";
import type { TrendsData } from "../../../shared/types.js";
import { Card, Badge, Empty } from "./ui.js";

export function TrendsCard({ trends }: { trends?: TrendsData | null }) {
  // 未取得（null）なら表示しない
  if (!trends) return null;
  const { items, error } = trends;
  return (
    <Card title={`急上昇（${trends.geo}）`} icon={<TrendingUp size={15} />} accent="text-fuchsia-300" count={items.length}>
      {error ? (
        <div className="py-2 text-[12px] text-rose-300">⚠ {error}</div>
      ) : items.length === 0 ? (
        <Empty>急上昇ワードなし</Empty>
      ) : (
        <div className="divide-y divide-white/5">
          {items.slice(0, 12).map((it, i) => {
            const news = it.news[0];
            return (
              <div key={`${it.title}-${i}`} className="flex items-baseline gap-2 py-1.5 text-[13px]">
                <span className="text-slate-100">{it.title}</span>
                {it.approxTraffic && <Badge tone="neutral">{it.approxTraffic}</Badge>}
                {news?.url && (
                  <a className="link ml-auto truncate text-[11px]" href={news.url} target="_blank" rel="noreferrer">
                    {news.source || "関連ニュース"}
                  </a>
                )}
              </div>
            );
          })}
        </div>
      )}
    </Card>
  );
}
