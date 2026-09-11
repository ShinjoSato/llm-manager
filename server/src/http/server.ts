// ai-manager HTTP/JSON API（React フロント用）。
//   GET  /api/health
//   GET  /api/dashboard         保存済み（無ければ収集）
//   POST /api/refresh           再収集して返す
//   GET  /api/state             手動レイヤー
//   POST /api/state             手動レイヤーを保存
//   GET  /api/appstore/:name?   App Store 状況（個別/全件）
//   GET  /api/ranking           App Store ランキング（自アプリ順位つき）
//   GET  /api/trends            Google Trends 急上昇
import { serve } from "@hono/node-server";
import { serveStatic } from "@hono/node-server/serve-static";
import { Hono } from "hono";
import type { MiddlewareHandler } from "hono";
import { existsSync } from "node:fs";
import { join, relative } from "node:path";
import { collect, collectAndSave, readDashboard } from "../core/collect.js";
import { readState, writeState } from "../core/state.js";
import { collectAppStore } from "../core/appstore.js";
import { collectRanking } from "../core/ranking.js";
import { collectTrends } from "../core/trends.js";
import { ROOT } from "../core/paths.js";
import { isAllowedHost, isAllowedOrigin } from "./origin.js";
import type { ManagerState } from "../../../shared/types.js";

const port = Number(process.env.PORT ?? 8765);
// PORT=0 だと OS が別のポートを割り当てるので、実際に待ち受けた値で判定する。
let boundPort = port;

// CORS は付けない。web/dist は同一オリジン配信で、開発時は Vite の proxy 経由になる。
// 付けるとブラウザで開いた任意のサイトからダッシュボードの中身を読めてしまう。
const app = new Hono();

// DNS リバインディング対策。攻撃者のドメインを 127.0.0.1 に向けても Host は攻撃者のもののままなので弾ける。
app.use("*", async (c, next) => {
  if (!isAllowedHost(c.req.header("host"), boundPort)) {
    return c.json({ ok: false, error: "invalid host header" }, 403);
  }
  const origin = c.req.header("origin");
  if (origin !== undefined && !isAllowedOrigin(origin)) {
    return c.json({ ok: false, error: "invalid origin header" }, 403);
  }
  c.header("X-Content-Type-Options", "nosniff");
  await next();
});

// 書き込み系は content-type を必須にする。プリフライトを回避した cross-origin のフォーム POST を弾くため。
const requireJson: MiddlewareHandler = async (c, next) => {
  const type = c.req.header("content-type")?.trimStart().toLowerCase();
  if (c.req.method === "POST" && !type?.startsWith("application/json")) {
    return c.json({ ok: false, error: "content-type must be application/json" }, 415);
  }
  await next();
};
app.use("/api/refresh", requireJson);
app.use("/api/state", requireJson);

app.get("/api/health", (c) => c.json({ ok: true }));

app.get("/api/dashboard", async (c) => {
  const dash = readDashboard() ?? (await collectAndSave());
  return c.json(dash);
});

app.post("/api/refresh", async (c) => c.json(await collectAndSave()));

app.get("/api/state", (c) => c.json(readState()));

app.post("/api/state", async (c) => {
  let body: ManagerState;
  try {
    body = (await c.req.json()) as ManagerState;
  } catch {
    return c.json({ ok: false, error: "invalid json" }, 400);
  }
  return c.json(writeState(body));
});

app.get("/api/appstore/:name?", async (c) => {
  const name = c.req.param("name");
  return c.json(await collectAppStore(name));
});

app.get("/api/ranking", async (c) => c.json(await collectRanking()));

app.get("/api/trends", async (c) => c.json(await collectTrends()));

// 本番: web のビルド成果物を配信（存在すれば）。root は cwd 相対で解決される。
const WEB_DIST = join(ROOT, "web", "dist");
if (existsSync(WEB_DIST)) {
  const rel = relative(process.cwd(), WEB_DIST) || ".";
  app.use("/*", serveStatic({ root: rel, index: "index.html" }));
  app.get("/*", serveStatic({ path: join(rel, "index.html") }));
}

// localhost 限定。認証が無く、手動レイヤーへの書き込み口もあるため外部に出さない。
serve({ fetch: app.fetch, port, hostname: "127.0.0.1" }, (info) => {
  boundPort = info.port;
  console.log(`ai-manager API: http://localhost:${info.port}`);
  console.log(`  GET /api/dashboard | POST /api/refresh | GET,POST /api/state`);
});
