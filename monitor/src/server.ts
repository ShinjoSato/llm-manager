// monitor の HTTP サーバー。SSE で UI にリアルタイム push する。
//   GET  /api/health
//   GET  /api/sessions   スナップショット
//   GET  /api/feed       直近のライブフィード
//   POST /api/sessions/:id/message  そのセッションの受信箱へテキストを投稿
//   POST /api/sessions/:id/open     そのセッションの作業場所を VSCode / Xcode で開く
//   POST /hook           Claude Code のフックから状態遷移を受け取る
//   GET  /events         SSE（sessions / feed）
import { serve } from "@hono/node-server";
import { serveStatic } from "@hono/node-server/serve-static";
import { Hono } from "hono";
import { streamSSE } from "hono/streaming";
import { existsSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { SessionHub } from "./hub.js";
import { isOpenApp } from "./open.js";
import type { FeedItem, HookPayload, SessionSnapshot } from "./types.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const UI_DIST = join(HERE, "..", "ui", "dist");

const hub = new SessionHub();
hub.setMaxListeners(0); // SSE 1 接続につき 3 リスナー。タブを開く数だけ増える。
hub.start();

const port = Number(process.env.PORT ?? 8766);

/** ループバックを指すホスト名。これ以外は外部のドメイン。 */
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]", "::1"]);

/** `host:port` をホストとポートに割る。`[::1]:8766` のブラケット形式も扱う。 */
function splitHostPort(value: string): { host: string; port: string } {
  if (value.startsWith("[")) {
    const end = value.indexOf("]");
    if (end < 0) return { host: value, port: "" };
    return { host: value.slice(0, end + 1), port: value.slice(end + 2) };
  }
  const sep = value.lastIndexOf(":");
  return sep < 0 ? { host: value, port: "" } : { host: value.slice(0, sep), port: value.slice(sep + 1) };
}

function isAllowedHost(value: string | undefined): boolean {
  if (!value) return false; // Host 無し（HTTP/1.0 等）は塞ぐ側に倒す。ブラウザは必ず付ける。
  const { host, port: hostPort } = splitHostPort(value.toLowerCase()); // ホスト名は大文字小文字を区別しない
  if (!LOOPBACK_HOSTS.has(host)) return false;
  // 既定ポート(80)で待つ時だけブラウザがポートを省く。
  return hostPort === String(port) || (hostPort === "" && port === 80);
}

function isAllowedOrigin(value: string): boolean {
  let url: URL;
  try {
    url = new URL(value); // Origin: null（sandbox iframe 等）はここで弾かれる。
  } catch {
    return false;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return false;
  // 開発時の Vite は別ポートで配信するので、ループバックならポートは問わない。
  return LOOPBACK_HOSTS.has(url.hostname);
}

// CORS は付けない。UI は同一オリジン配信で、開発時は Vite の proxy 経由になる。
// 付けるとブラウザで開いた任意のサイトから cwd や作業内容を読めてしまう。
const app = new Hono();

// DNS リバインディング対策。攻撃者のドメインを 127.0.0.1 に向けても Host は攻撃者のもののままなので弾ける。
app.use("*", async (c, next) => {
  if (!isAllowedHost(c.req.header("host"))) {
    return c.json({ ok: false, error: "invalid host header" }, 403);
  }
  const origin = c.req.header("origin");
  if (origin !== undefined && !isAllowedOrigin(origin)) {
    return c.json({ ok: false, error: "invalid origin header" }, 403);
  }
  await next();
});

app.get("/api/health", (c) => c.json({ ok: true, sessions: hub.snapshot().length }));
app.get("/api/sessions", (c) => c.json(hub.snapshot()));
app.get("/api/feed", (c) => c.json(hub.recentFeed()));

/** 送信テキストの上限。受信側は約 100 万文字で拒否するが、その手前で切る。 */
const MAX_MESSAGE_CHARS = 100_000;

app.post("/api/sessions/:sessionId/message", async (c) => {
  // content-type を必須にして、プリフライトを回避した cross-origin POST を弾く。
  if (!c.req.header("content-type")?.startsWith("application/json")) {
    return c.json({ ok: false, error: "content-type must be application/json" }, 415);
  }
  let body: { text?: unknown };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ ok: false, error: "invalid json" }, 400);
  }
  const text = typeof body.text === "string" ? body.text.trim() : "";
  if (!text) return c.json({ ok: false, error: "text が空です" }, 400);
  if (text.length > MAX_MESSAGE_CHARS) {
    return c.json({ ok: false, error: `長すぎます（${MAX_MESSAGE_CHARS} 文字まで）` }, 413);
  }

  const result = await hub.sendMessage(c.req.param("sessionId"), text);
  if (result.ok) return c.json(result);
  const status = result.code === "not_found" ? 404 : result.code === "unreachable" ? 502 : 409;
  return c.json(result, status);
});

// 開く先はパスで受け取らない。任意パスを受けると、別サイトから任意のファイルを開かせる穴になる。
app.post("/api/sessions/:sessionId/open", async (c) => {
  if (!c.req.header("content-type")?.startsWith("application/json")) {
    return c.json({ ok: false, error: "content-type must be application/json" }, 415);
  }
  let body: { app?: unknown };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ ok: false, error: "invalid json" }, 400);
  }
  if (!isOpenApp(body.app)) return c.json({ ok: false, error: "app は vscode / xcode です" }, 400);

  const result = await hub.openInApp(c.req.param("sessionId"), body.app);
  if (result.ok) return c.json(result);
  const status = result.code === "not_found" ? 404 : 409;
  return c.json(result, status);
});

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
    const cleanup = () => {
      closed = true;
      hub.off("sessions", onSessions);
      hub.off("tick", onTick);
      hub.off("feed", onFeed);
    };
    stream.onAbort(cleanup);

    // 登録から解除までを try で囲む。初回 write が失敗してもリスナーを残さない。
    try {
      hub.on("sessions", onSessions);
      hub.on("tick", onTick);
      hub.on("feed", onFeed);

      await stream.writeSSE({ event: "feed-batch", data: JSON.stringify(hub.recentFeed()) });

      let lastSent = 0;
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

if (existsSync(UI_DIST)) {
  const rel = relative(process.cwd(), UI_DIST) || ".";
  app.use("/*", serveStatic({ root: rel, index: "index.html" }));
  app.get("/*", serveStatic({ path: join(rel, "index.html") }));
} else {
  app.get("/", (c) =>
    c.text("UI が未ビルドです。`cd monitor/ui && npm install && npm run build` を実行してください。", 503),
  );
}

// localhost 限定。認証が無く、セッションへの書き込み口もあるため外部に出さない。
serve({ fetch: app.fetch, port, hostname: "127.0.0.1" }, (info) => {
  console.log(`ai-manager monitor: http://localhost:${info.port}`);
  console.log(`  GET /events (SSE) | GET /api/sessions | POST /hook`);
  if (!existsSync(UI_DIST)) console.log("  ⚠ ui/dist が無いため UI は配信されません");
});

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    hub.stop();
    process.exit(0);
  });
}
