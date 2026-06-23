// Google Trends 急上昇取得（公式 RSS・無料/キー不要）。
//   https://trends.google.com/trending/rss?geo=JP
// RSS/XML を依存を増やさず軽量な正規表現でパースする。
// 各 <item> は急上昇ワード(title) + おおよそのボリューム(ht:approx_traffic)
//   + 関連ニュース(ht:news_item × N: title/source/url) を持つ。
import type { TrendItem, TrendNews, TrendsData } from "../../../shared/types.js";

const RSS_URL = "https://trends.google.com/trending/rss";

/** &amp; などの XML エンティティを復元。 */
function decode(s: string): string {
  return s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&")
    .trim();
}

/** 親文字列から最初の <tag>...</tag> 中身を取り出す（無ければ ""）。 */
function tag(src: string, name: string): string {
  const m = src.match(new RegExp(`<${name}[^>]*>([\\s\\S]*?)</${name}>`, "i"));
  return m ? decode(m[1]) : "";
}

/** 自己終了タグ等で属性 src を持つもの（<ht:picture>URL</ht:picture> 形式）。 */
function newsItems(itemXml: string): TrendNews[] {
  const out: TrendNews[] = [];
  const re = /<ht:news_item>([\s\S]*?)<\/ht:news_item>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(itemXml)) !== null) {
    const block = m[1];
    out.push({
      title: tag(block, "ht:news_item_title"),
      source: tag(block, "ht:news_item_source"),
      url: tag(block, "ht:news_item_url"),
    });
  }
  return out;
}

function parseItems(xml: string): TrendItem[] {
  const out: TrendItem[] = [];
  const re = /<item>([\s\S]*?)<\/item>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml)) !== null) {
    const block = m[1];
    const pic = tag(block, "ht:picture");
    out.push({
      title: tag(block, "title"),
      approxTraffic: tag(block, "ht:approx_traffic"),
      pubDate: tag(block, "pubDate"),
      picture: pic || null,
      news: newsItems(block),
    });
  }
  return out;
}

/** Google Trends 急上昇を取得。失敗しても error 付きで安全に返す。 */
export async function collectTrends(geo = "JP"): Promise<TrendsData> {
  try {
    const res = await fetch(`${RSS_URL}?geo=${encodeURIComponent(geo)}`);
    if (!res.ok) throw new Error(`RSS ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const xml = await res.text();
    const items = parseItems(xml);
    // channel に明示の更新時刻が無いため、最初の item の pubDate を代表値にする。
    const updated = tag(xml, "lastBuildDate") || items[0]?.pubDate || "";
    return { geo, updated, items };
  } catch (e) {
    return { geo, updated: "", items: [], error: String(e) };
  }
}
