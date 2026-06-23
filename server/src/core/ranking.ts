// App Store ランキング取得（Apple Marketing Tools RSS v2・無料/キー不要）。
//   https://rss.marketingtools.apple.com/api/v2/{国}/apps/{種別}/{件数}/apps.json
// 例: https://rss.marketingtools.apple.com/api/v2/jp/apps/top-free/50/apps.json
//   種別: top-free / top-paid / top-grossing、国: jp / us 等、件数: 10/25/50
//
// 自アプリの順位付与:
//   appstore.tsv は bundleId を持つが、RSS のアプリ ID は数値の App Store ID。
//   App Store Connect 認証があれば bundleId→数値 appId を解決して厳密に突き合わせる。
//   無ければ名前の部分一致でフォールバックする（appId は null）。
import { APPS_TSV } from "./paths.js";
import { readTsv } from "./tsv.js";
import { loadCredentials, makeJwt } from "./appstore.js";
import type {
  RankingApp, RankingChart, RankingData, OwnAppRank,
} from "../../../shared/types.js";

const RSS_BASE = "https://rss.marketingtools.apple.com/api/v2";
const ASC_API = "https://api.appstoreconnect.apple.com";

/** 取得するチャート定義（最低 jp の top-free / top-grossing）。 */
export interface ChartSpec {
  country: string;
  kind: string;  // top-free / top-paid / top-grossing
  count: number; // 10 / 25 / 50
}

// 注意: jp の apps RSS では top-grossing（売上）は提供されておらず 404 になる
//   （実機確認済み: top-free / top-paid は 200、top-grossing は 404）。
//   そのため既定は top-free / top-paid とする。grossing を試したい場合は spec で渡せば
//   error 付き空配列として安全に格納される（他チャートは壊れない）。
const DEFAULT_CHARTS: ChartSpec[] = [
  { country: "jp", kind: "top-free", count: 50 },
  { country: "jp", kind: "top-paid", count: 50 },
];

async function safe<T>(fn: () => Promise<T>, fallback: T): Promise<T> {
  try {
    return await fn();
  } catch (e) {
    if (fallback && typeof fallback === "object" && !Array.isArray(fallback)) {
      return { ...(fallback as object), error: String(e) } as T;
    }
    return fallback;
  }
}

/** 1チャート分を取得。 */
async function fetchChart(spec: ChartSpec): Promise<RankingChart> {
  const url = `${RSS_BASE}/${spec.country}/apps/${spec.kind}/${spec.count}/apps.json`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`RSS ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const feed = ((await res.json()) as any).feed ?? {};
  const apps: RankingApp[] = (feed.results ?? []).map((r: any, i: number) => ({
    rank: i + 1,
    appId: String(r.id ?? ""),
    name: r.name ?? "",
    artistName: r.artistName ?? "",
    url: r.url ?? "",
    artworkUrl: r.artworkUrl100 ?? null,
    releaseDate: r.releaseDate ?? "",
  }));
  return {
    country: spec.country,
    kind: spec.kind,
    title: feed.title ?? "",
    updated: feed.updated ?? "",
    apps,
  };
}

/** App Store Connect 認証があれば bundleId→数値 appId を解決。無ければ {}。 */
async function resolveAppIds(bundleIds: string[]): Promise<Record<string, string>> {
  const creds = loadCredentials();
  if (!creds || !bundleIds.length) return {};
  const token = makeJwt(creds);
  const out: Record<string, string> = {};
  for (const bid of bundleIds) {
    try {
      const res = await fetch(
        `${ASC_API}/v1/apps?filter[bundleId]=${encodeURIComponent(bid)}&fields[apps]=bundleId`,
        { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } },
      );
      if (!res.ok) continue;
      const data = ((await res.json()) as any).data ?? [];
      if (data[0]?.id) out[bid] = String(data[0].id);
    } catch { /* このアプリだけスキップ */ }
  }
  return out;
}

/** 自アプリ（appstore.tsv）の各チャートでの順位を算出。 */
function computeOwnRanks(
  charts: RankingChart[],
  apps: { name: string; bundleId: string }[],
  appIdByBundle: Record<string, string>,
): OwnAppRank[] {
  return apps.map(({ name, bundleId }) => {
    const appId = appIdByBundle[bundleId] ?? null;
    const ranks = charts.map((ch) => {
      const chart = `${ch.country}/${ch.kind}`;
      let hit: RankingApp | undefined;
      if (appId) hit = ch.apps.find((a) => a.appId === appId);
      // appId が解決できなければ名前の部分一致でフォールバック（不確実）
      if (!hit) {
        const lc = name.toLowerCase();
        hit = ch.apps.find(
          (a) => a.name.toLowerCase().includes(lc) || lc.includes(a.name.toLowerCase()),
        );
      }
      return { chart, rank: hit ? hit.rank : null };
    });
    return { project: name, bundleId, appId, ranks };
  });
}

/** App Store ランキングを取得。全失敗でも null は返さず空配列＋error で安全に。 */
export async function collectRanking(charts: ChartSpec[] = DEFAULT_CHARTS): Promise<RankingData> {
  const results = await Promise.all(
    charts.map((spec) =>
      safe(() => fetchChart(spec), {
        country: spec.country, kind: spec.kind, title: "", updated: "", apps: [],
      } as RankingChart),
    ),
  );

  const apps = readTsv(APPS_TSV)
    .filter((r) => r.length >= 2)
    .map((r) => ({ name: r[0], bundleId: r[1] }));
  const appIdByBundle = await safe(
    () => resolveAppIds(apps.map((a) => a.bundleId)),
    {} as Record<string, string>,
  );
  const ownApps = computeOwnRanks(results, apps, appIdByBundle);

  return { charts: results, ownApps };
}
