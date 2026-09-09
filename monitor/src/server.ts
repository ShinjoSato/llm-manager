// monitor の HTTP サーバー。SSE で UI にリアルタイム push する。
//   GET  /api/health
//   GET  /api/sessions   スナップショット
//   GET  /api/feed       直近のライブフィード
//   POST /hook           Claude Code のフックから状態遷移を受け取る
//   GET  /events         SSE（sessions / feed）
import { serve } from "@hono/node-server";
import { serveStatic } from "@hono/node-server/serve-static";
import { Hono } from "hono";
import { cors } from "hono/cors";
import { streamSSE } from "hono/streaming";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { SessionHub } from "./hub.js";
import type { FeedItem, HookPayload, SessionSnapshot } from "./types.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = join(HERE, "..", "public");

const hub = new SessionHub();
hub.start();

const app = new Hono();
app.use("/api/*", cors());
app.use("/hook", cors());

app.get("/api/health", (c) => c.json({ ok: true, sessions: hub.snapshot().length }));
app.get("/api/sessions", (c) => c.json(hub.snapshot()));
app.get("/api/feed", (c) => c.json(hub.recentFeed()));

app.post("/hook", async (c) => {
  let payload: HookPayload;
  try {
    payload = await c.req.json();
  } catch {
    return c.json({ ok: false, error: "invalid json" }, 400);
  }
  const applied = hub.applyHook(payload);
  // 未知のセッションでも 200 を返す（フック側を失敗させないため）。
  return c.json({ ok: true, applied });
});

app.get("/events", (c) =>
  streamSSE(c, async (stream) => {
    let closed = false;
    let latest: SessionSnapshot[] | null = hub.snapshot();
    let dirty = true;
    const feedQueue: FeedItem[] = [];

    const onSessions = (s: SessionSnapshot[]) => {
      latest = s;
      dirty = true;
    };
    const onTick = (s: SessionSnapshot[]) => {
      latest = s;
    };
    const onFeed = (item: FeedItem) => {
      feedQueue.push(item);
    };

    hub.on("sessions", onSessions);
    hub.on("tick", onTick);
    hub.on("feed", onFeed);

    const cleanup = () => {
      closed = true;
      hub.off("sessions", onSessions);
      hub.off("tick", onTick);
      hub.off("feed", onFeed);
    };
    stream.onAbort(cleanup);

    await stream.writeSSE({
      event: "feed-batch",
      data: JSON.stringify(hub.recentFeed()),
    });

    let lastSent = 0;
    try {
      while (!closed) {
        const now = Date.now();
        // 変化があれば即座に、無くても 1 秒ごとに送って経過時間の表示を進める。
        if (latest && (dirty || now - lastSent >= 1000)) {
          await stream.writeSSE({ event: "sessions", data: JSON.stringify(latest) });
          dirty = false;
          lastSent = now;
        }
        while (feedQueue.length) {
          await stream.writeSSE({ event: "feed", data: JSON.stringify(feedQueue.shift()) });
        }
        await stream.sleep(120);
      }
    } finally {
      cleanup();
    }
  }),
);

const rel = relative(process.cwd(), PUBLIC_DIR) || ".";
app.use("/*", serveStatic({ root: rel, index: "index.html" }));
app.get("/*", serveStatic({ path: join(rel, "index.html") }));

const port = Number(process.env.PORT ?? 8766);
serve({ fetch: app.fetch, port }, (info) => {
  console.log(`ai-manager monitor: http://localhost:${info.port}`);
  console.log(`  GET /events (SSE) | GET /api/sessions | POST /hook`);
});

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    hub.stop();
    process.exit(0);
  });
}
