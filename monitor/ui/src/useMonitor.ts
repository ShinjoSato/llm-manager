import { useEffect, useState } from "react";
import type { FeedItem, SessionSnapshot } from "../../src/types.js";

// 絞り込みは表示段で行うため、非表示セッションもこの上限を消費する。少し余裕を持たせる。
const FEED_LIMIT = 400;

/** SSE を購読してセッションとライブフィードを保持する。 */
export function useMonitor() {
  const [sessions, setSessions] = useState<SessionSnapshot[]>([]);
  const [feed, setFeed] = useState<FeedItem[]>([]);
  const [connected, setConnected] = useState(false);

  useEffect(() => {
    const es = new EventSource("/events");
    es.addEventListener("open", () => setConnected(true));
    es.addEventListener("error", () => setConnected(false));
    es.addEventListener("sessions", (e) => setSessions(JSON.parse((e as MessageEvent).data)));
    es.addEventListener("feed", (e) => {
      const item = JSON.parse((e as MessageEvent).data) as FeedItem;
      setFeed((prev) => [item, ...prev].slice(0, FEED_LIMIT));
    });
    es.addEventListener("feed-batch", (e) => {
      const items = JSON.parse((e as MessageEvent).data) as FeedItem[];
      setFeed(items.slice().reverse().slice(0, FEED_LIMIT));
    });
    return () => es.close();
  }, []);

  return { sessions, feed, connected };
}

/** 経過時間の表示を進めるための時計。DOM は React が差分だけ更新する。 */
export function useNow(intervalMs = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(t);
  }, [intervalMs]);
  return now;
}
