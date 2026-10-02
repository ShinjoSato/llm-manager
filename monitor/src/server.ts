// monitor の HTTP サーバー。SSE でクライアント（claude-deck）にリアルタイム push する。画面は持たない。
//   GET  /api/health
//   GET  /api/sessions   スナップショット
//   GET  /api/feed       直近のライブフィード
//   GET  /api/usage      5時間 / 7日間ウィンドウの使用量（statusline スクリプトが残した値）
//   POST /api/sessions/:id/message  そのセッションの受信箱へテキストを投稿
//   POST /api/sessions/:id/open     そのセッションの作業場所を VSCode / Xcode で開く
//   POST /api/sessions/:id/close    そのセッションのワークスペースを Xcode から閉じる
//   GET  /api/permissions            保留中の権限確認 / POST /api/permissions/:key  許可・拒否
//   POST /api/channel/permissions    チャネルからの権限確認（判断が出るまで待たせる）
//   POST /hook           Claude Code のフックから状態遷移を受け取る
//   GET  /api/sessions/:id/transcript  会話履歴（transcriptApi.ts）
//   GET  /events         SSE（sessions / feed / permissions / usage。?transcripts= で transcript も）
// 認証が無く書き込み口もあるので、ループバックでしか待ち受けない。
import { serve, type HttpBindings } from "@hono/node-server";
import { Hono, type Context } from "hono";
import { streamSSE } from "hono/streaming";
import { SessionHub } from "./hub.js";
import { isAllowedHost, isAllowedOrigin } from "./origin.js";
import { isCloseApp } from "./close.js";
import { isOpenApp } from "./open.js";
import { isDecision, isLocalActor, parseRequest } from "./permissions.js";
import { registerTranscriptRoutes, TranscriptStore } from "./transcriptApi.js";
import type { FeedItem, HookPayload, PendingPermission, SessionSnapshot, TranscriptEvent, UsageSnapshot } from "./types.js";

const hub = new SessionHub();
hub.setMaxListeners(0); // SSE 1 接続につき 5 リスナー。接続の数だけ増える。
hub.start();
const transcripts = new TranscriptStore(() => hub.snapshot());

const port = Number(process.env.PORT ?? 8766);
// PORT=0 だと OS が別のポートを割り当てるので、実際に待ち受けた値で判定する。
let boundPort = port;

// CORS は付けない。付けるとブラウザで開いた任意のサイトから cwd や作業内容を読めてしまう。
const app = new Hono<{ Bindings: HttpBindings }>();

// DNS リバインディング対策。攻撃者のドメインを 127.0.0.1 に向けても Host は攻撃者のもののままなので弾ける。
app.use("*", async (c, next) => {
  if (!isAllowedHost(c.req.header("host"), boundPort)) {
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
app.get("/api/feed", (c) => {
  const local = isLocalActor(c.env.incoming.socket.remoteAddress);
  return c.json(hub.recentFeed().filter((item) => local || !item.local));
});
registerTranscriptRoutes(app, transcripts);
app.get("/api/usage", (c) => c.json(hub.usageSnapshot()));

/** 判断が出るまでチャネルを待たせる 1 巡分。切れてもチャネルが取り直すので保留は消えない。 */
const PERMISSION_WAIT_MS = 60_000;

// 権限確認の中継はループバック限定（任意のコマンド実行を許可できる口なので、接続元でも確かめる）。
app.post("/api/channel/permissions", async (c) => {
  if (!isLocalActor(c.env.incoming.socket.remoteAddress)) return notFound(c);
  if (!c.req.header("content-type")?.startsWith("application/json")) {
    return c.json({ ok: false, error: "content-type must be application/json" }, 415);
  }
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ ok: false, error: "invalid json" }, 400);
  }
  const input = parseRequest(body);
  if (!input) return c.json({ ok: false, error: "申請の形が不正です" }, 400);

  const outcome = await hub.awaitPermission(input, PERMISSION_WAIT_MS);
  return c.json({ ok: true, outcome });
});

app.get("/api/permissions", (c) => {
  if (!isLocalActor(c.env.incoming.socket.remoteAddress)) return notFound(c);
  c.header("cache-control", "no-store");
  return c.json(hub.pendingPermissions());
});

app.post("/api/permissions/:key", async (c) => {
  if (!isLocalActor(c.env.incoming.socket.remoteAddress)) return notFound(c);
  if (!c.req.header("content-type")?.startsWith("application/json")) {
    return c.json({ ok: false, error: "content-type must be application/json" }, 415);
  }
  let body: { decision?: unknown };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ ok: false, error: "invalid json" }, 400);
  }
  if (!isDecision(body.decision)) {
    return c.json({ ok: false, error: "decision は allow / deny です" }, 400);
  }

  const pending = hub.decidePermission(c.req.param("key"), body.decision);
  // 端末側で先に答えられた後や期限切れの後は保留が無い。
  if (!pending) return c.json({ ok: false, error: "この確認はもう待っていません" }, 404);
  return c.json({ ok: true, decision: body.decision });
});

/** ループバック以外には存在ごと伏せる（理由は permissions.ts）。 */
function notFound(c: Context): Response {
  return c.json({ ok: false, error: "not found" }, 404);
}

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

// 閉じる先もパスで受け取らない。開いているワークスペースは sessionId から引く。
app.post("/api/sessions/:sessionId/close", async (c) => {
  if (!c.req.header("content-type")?.startsWith("application/json")) {
    return c.json({ ok: false, error: "content-type must be application/json" }, 415);
  }
  let body: { app?: unknown };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ ok: false, error: "invalid json" }, 400);
  }
  if (!isCloseApp(body.app)) return c.json({ ok: false, error: "app は xcode です" }, 400);

  const result = await hub.closeInApp(c.req.param("sessionId"), body.app);
  if (result.ok) return c.json(result);
  const status = result.code === "not_found" ? 404 : 409;
  return c.json(result, status);
});

app.post("/hook", async (c) => {
  if (!c.req.header("content-type")?.startsWith("application/json")) {
    return c.json({ ok: false, error: "content-type must be application/json" }, 415);
  }
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

app.get("/events", (c) => {
  // 権限確認は手元の接続にだけ流す（答えられないものを見せない）。
  const local = isLocalActor(c.env.incoming.socket.remoteAddress);
  return streamSSE(c, async (stream) => {
    let closed = false;
    let latest: SessionSnapshot[] | null = hub.snapshot();
    let dirty = true;
    const feedQueue: FeedItem[] = [];
    let usage: UsageSnapshot | null = hub.usageSnapshot();
    let usageDirty = true;
    const transcriptQueue: TranscriptEvent[] = [];
    let unsubscribeTranscripts = () => {};
    let permissions: PendingPermission[] | null = local ? hub.pendingPermissions() : null;

    const onSessions = (s: SessionSnapshot[]) => {
      latest = s;
      dirty = true;
    };
    const onUsage = (u: UsageSnapshot | null) => {
      usage = u;
      usageDirty = true;
    };
    const onTick = (s: SessionSnapshot[]) => {
      latest = s;
    };
    const onFeed = (item: FeedItem) => {
      if (local || !item.local) feedQueue.push(item);
    };
    const onPermissions = (list: PendingPermission[]) => {
      if (local) permissions = list;
    };
    const cleanup = () => {
      closed = true;
      hub.off("sessions", onSessions);
      hub.off("tick", onTick);
      hub.off("feed", onFeed);
      hub.off("usage", onUsage);
      unsubscribeTranscripts();
      hub.off("permissions", onPermissions);
    };
    stream.onAbort(cleanup);

    // 登録から解除までを try で囲む。初回 write が失敗してもリスナーを残さない。
    try {
      hub.on("sessions", onSessions);
      hub.on("tick", onTick);
      hub.on("feed", onFeed);
      hub.on("usage", onUsage);
      // 会話の追記は求めた接続にだけ流す（本文が大きく、一覧画面には要らない）。
      unsubscribeTranscripts = transcripts.subscribe(c.req.query("transcripts"), (ev) => transcriptQueue.push(ev));
      hub.on("permissions", onPermissions);

      await stream.writeSSE({
        event: "feed-batch",
        data: JSON.stringify(hub.recentFeed().filter((item) => local || !item.local)),
      });

      let lastSent = 0;
      while (!closed) {
        const now = Date.now();
        // 変化があれば即座に、無くても 1 秒ごとに送って経過時間の表示を進める。
        if (latest && (dirty || now - lastSent >= 1000)) {
          await stream.writeSSE({ event: "sessions", data: JSON.stringify(latest) });
          dirty = false;
          lastSent = now;
        }
        if (usageDirty) {
          await stream.writeSSE({ event: "usage", data: JSON.stringify(usage) });
          usageDirty = false;
        }
        if (permissions) {
          // 書き出しの間に届いた更新を捨てないよう、await の前に取り出す。
          const list = permissions;
          permissions = null;
          await stream.writeSSE({ event: "permissions", data: JSON.stringify(list) });
        }
        while (feedQueue.length) {
          await stream.writeSSE({ event: "feed", data: JSON.stringify(feedQueue.shift()) });
        }
        while (transcriptQueue.length) {
          await stream.writeSSE({ event: "transcript", data: JSON.stringify(transcriptQueue.shift()) });
        }
        await stream.sleep(120);
      }
    } finally {
      cleanup();
    }
  });
});

serve({ fetch: app.fetch, port, hostname: "127.0.0.1" }, (info) => {
  boundPort = info.port;
  console.log(`ai-manager monitor: http://localhost:${info.port}`);
  console.log(`  GET /events (SSE) | GET /api/sessions | POST /hook`);
});

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    hub.stop();
    transcripts.stop();
    process.exit(0);
  });
}
