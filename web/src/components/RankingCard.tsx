import { Trophy } from "lucide-react";
import type { RankingData } from "../../../shared/types.js";
import { Card, Badge, Empty } from "./ui.js";

const KIND_LABEL: Record<string, string> = {
  "top-free": "無料",
  "top-paid": "有料",
  "top-grossing": "売上",
};

function chartLabel(chart: string): string {
  const [country, kind] = chart.split("/");
  return `${(country || "").toUpperCase()} ${KIND_LABEL[kind] ?? kind}`;
}

export function RankingCard({ ranking }: { ranking?: RankingData | null }) {
  // 未取得（null）なら表示しない
  if (!ranking) return null;
  const { charts, ownApps, error } = ranking;
  // 順位が1つでも入っている自アプリだけハイライト
  const ranked = ownApps.filter((o) => o.ranks.some((r) => r.rank !== null));

  return (
    <Card title="App Store ランキング" icon={<Trophy size={15} />} accent="text-amber-300" count={charts.length}>
      {error ? (
        <div className="py-2 text-[12px] text-rose-300">⚠ {error}</div>
      ) : charts.length === 0 ? (
        <Empty>ランキング取得なし</Empty>
      ) : (
        <div className="flex flex-col gap-3">
          {/* 自アプリの順位サマリ */}
          {ownApps.length > 0 && (
            <div className="flex flex-col gap-1.5">
              {ownApps.map((o) => (
                <div key={o.project} className="flex items-center gap-2 text-[13px]">
                  <span className="w-16 shrink-0 font-semibold text-slate-100">{o.project}</span>
                  <div className="flex flex-wrap gap-1.5">
                    {o.ranks.map((r) => (
                      <Badge key={r.chart} tone={r.rank !== null ? "ok" : "neutral"}>
                        {chartLabel(r.chart)}: {r.rank !== null ? `${r.rank}位` : "圏外"}
                      </Badge>
                    ))}
                  </div>
                </div>
              ))}
            </div>
          )}

          {/* 各チャートの上位（5件まで） */}
          {charts.map((ch) => (
            <div key={`${ch.country}/${ch.kind}`}>
              <div className="mb-1 text-[11px] uppercase tracking-wider text-slate-400">
                {chartLabel(`${ch.country}/${ch.kind}`)}（{ch.title}）
              </div>
              <div className="divide-y divide-white/5">
                {ch.apps.slice(0, 5).map((a) => {
                  const own = ranked.some((o) => o.appId === a.appId);
                  return (
                    <div key={a.appId} className="flex items-baseline gap-2 py-1 text-[13px]">
                      <span className="w-6 shrink-0 text-right font-mono text-[12px] text-slate-400">{a.rank}</span>
                      <a
                        className={own ? "link font-semibold text-amber-300" : "link"}
                        href={a.url}
                        target="_blank"
                        rel="noreferrer"
                      >
                        {a.name}
                      </a>
                      <span className="ml-auto truncate text-[11px] text-slate-500">{a.artistName}</span>
                    </div>
                  );
                })}
              </div>
            </div>
          ))}
        </div>
      )}
    </Card>
  );
}
