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
import { cors } from "hono/cors";
import { existsSync } from "node:fs";
import { join, relative } from "node:path";
import { collect, collectAndSave, readDashboard } from "../core/collect.js";
import { readState, writeState } from "../core/state.js";
import { collectAppStore } from "../core/appstore.js";
import { collectRanking } from "../core/ranking.js";
import { collectTrends } from "../core/trends.js";
import { ROOT } from "../core/paths.js";
import type { ManagerState } from "../../../shared/types.js";

const app = new Hono();
app.use("/api/*", cors());

app.get("/api/health", (c) => c.json({ ok: true }));

app.get("/api/dashboard", async (c) => {
  const dash = readDashboard() ?? (await collectAndSave());
  return c.json(dash);
});

app.post("/api/refresh", async (c) => c.json(await collectAndSave()));

app.get("/api/state", (c) => c.json(readState()));

app.post("/api/state", async (c) => {
  const body = (await c.req.json()) as ManagerState;
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

const port = Number(process.env.PORT ?? 8765);
serve({ fetch: app.fetch, port }, (info) => {
  console.log(`ai-manager API: http://localhost:${info.port}`);
  console.log(`  GET /api/dashboard | POST /api/refresh | GET,POST /api/state`);
});
