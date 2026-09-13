// monitor の HTTP サーバー。SSE で UI にリアルタイム push する。
//   GET  /api/health
//   GET  /api/sessions   スナップショット
//   GET  /api/feed       直近のライブフィード
//   GET  /api/lan        LAN 接続用の案内 / GET /api/lan/qr.svg  その QR（どちらもループバック限定）
//   POST /api/sessions/:id/message  そのセッションの受信箱へテキストを投稿
//   POST /api/sessions/:id/open     そのセッションの作業場所を VSCode / Xcode で開く
//   POST /api/sessions/:id/close    そのセッションのワークスペースを Xcode から閉じる
//   GET  /api/permissions            保留中の権限確認 / POST /api/permissions/:requestId  許可・拒否
//   POST /api/channel/permissions    チャネルからの権限確認（判断が出るまで待たせる）
//   POST /hook           Claude Code のフックから状態遷移を受け取る
//   GET  /events         SSE（sessions / feed / permissions）
// 既定はループバック限定。MONITOR_LAN=1 のときだけ LAN へ出し、トークンを持つ端末だけ通す。
import { serve, type HttpBindings } from "@hono/node-server";
import { serveStatic } from "@hono/node-server/serve-static";
import { Hono, type Context } from "hono";
import { getCookie, setCookie } from "hono/cookie";
import { streamSSE } from "hono/streaming";
import { existsSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { SessionHub } from "./hub.js";
import { lanInfoFor, lanQrSvgFor } from "./lan.js";
import {
  isAllowedHost,
  isAllowedOrigin,
  isLoopbackAddress,
  isPrivateIPv4,
  localIPv4Addresses,
} from "./origin.js";
import { isCloseApp } from "./close.js";
import { isOpenApp } from "./open.js";
import { isDecision, isLocalActor, parseRequest } from "./permissions.js";
import { loadOrCreateToken, MIN_TOKEN_LENGTH, TOKEN_FILE, tokenEquals } from "./token.js";
import type { FeedItem, HookPayload, PendingPermission, SessionSnapshot } from "./types.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const UI_DIST = join(HERE, "..", "ui", "dist");

// LAN 公開はオプトイン。既定はループバック限定のまま。
const lanEnabled = process.env.MONITOR_LAN === "1";
const lanHosts: ReadonlySet<string> = new Set(lanEnabled ? localIPv4Addresses() : []);

const token = lanEnabled ? loadOrCreateToken() : null;
if (lanEnabled && !token) {
  // 設定ミスで無防備に開くより落ちる方が安全。
  console.error(
    `MONITOR_LAN=1 ですがトークンを用意できません（${TOKEN_FILE} を読み書きできないか、MONITOR_TOKEN が ${MIN_TOKEN_LENGTH} 文字未満）。起動を中止します。`,
  );
  process.exit(1);
}

const hub = new SessionHub();
hub.setMaxListeners(0); // SSE 1 接続につき 3 リスナー。タブを開く数だけ増える。
hub.start();

const port = Number(process.env.PORT ?? 8766);
// PORT=0 だと OS が別のポートを割り当てるので、実際に待ち受けた値で判定する。
let boundPort = port;

// CORS は付けない。UI は同一オリジン配信で、開発時は Vite の proxy 経由になる。
// 付けるとブラウザで開いた任意のサイトから cwd や作業内容を読めてしまう。
const app = new Hono<{ Bindings: HttpBindings }>();

// DNS リバインディング対策。攻撃者のドメインを 127.0.0.1 に向けても Host は攻撃者のもののままなので弾ける。
app.use("*", async (c, next) => {
  if (!isAllowedHost(c.req.header("host"), boundPort, lanHosts)) {
    return c.json({ ok: false, error: "invalid host header" }, 403);
  }
  const origin = c.req.header("origin");
  if (origin !== undefined && !isAllowedOrigin(origin, boundPort, lanHosts)) {
    return c.json({ ok: false, error: "invalid origin header" }, 403);
  }
  await next();
});

/** トークンを載せる cookie の名前。 */
const TOKEN_COOKIE = "monitor_token";

// LAN からはトークンを持つ端末だけ通す。ヘッダーではなく cookie に載せるのは、
// SSE を張る EventSource がカスタムヘッダーを付けられないため。
app.use("*", async (c, next) => {
  if (!token) return next(); // 既定（ループバック限定）は従来どおり素通り
  if (isLoopbackAddress(c.env.incoming.socket.remoteAddress)) return next();

  const url = new URL(c.req.url);
  const given = url.searchParams.get("t");
  if (given !== null) {
    if (!tokenEquals(token, given)) return c.json({ ok: false, error: "invalid token" }, 401);
    setCookie(c, TOKEN_COOKIE, token, {
      httpOnly: true,
      sameSite: "Lax",
      path: "/",
      maxAge: 60 * 60 * 24 * 365,
    });
    // リダイレクトすると POST の本体が捨てられるので、画面を開く時だけ差し替える。
    if (c.req.method === "GET" || c.req.method === "HEAD") {
      url.searchParams.delete("t");
      // 履歴やスクリーンショットにトークンを残さないため、URL から外して開き直させる。
      return c.redirect(`${safePath(url.pathname)}${url.search}`, 302);
    }
    return next();
  }

  if (!tokenEquals(token, getCookie(c, TOKEN_COOKIE))) {
    return unauthorized(c);
  }
  await next();
});

/** `//evil.com` は protocol-relative URL として外部へ飛ぶので、先頭のスラッシュを 1 本に畳む。 */
function safePath(pathname: string): string {
  return pathname.startsWith("//") ? `/${pathname.replace(/^\/+/, "")}` : pathname;
}

/** 画面から開いた時は、次に何をすればいいか分かる形で返す。 */
function unauthorized(c: Context): Response {
  if (c.req.header("accept")?.includes("text/html")) {
    return c.html(
      "<meta charset=\"utf-8\"><p>この端末は未認証です。Mac の monitor を起動した端末に出ている QR を読み直してください。</p>",
      401,
    );
  }
  return c.json({ ok: false, error: "unauthorized" }, 401);
}

app.get("/api/health", (c) => c.json({ ok: true, sessions: hub.snapshot().length }));
app.get("/api/sessions", (c) => c.json(hub.snapshot()));
app.get("/api/feed", (c) => c.json(hub.recentFeed()));

// 別端末を繋ぐための案内。ループバック以外には存在ごと伏せる（理由は lan.ts）。
app.get("/api/lan", (c) => {
  c.header("cache-control", "no-store");
  const info = lanInfoFor(c.env.incoming.socket.remoteAddress, lanHosts, boundPort, token);
  return info ? c.json(info) : c.json({ ok: false, error: "not found" }, 404);
});

app.get("/api/lan/qr.svg", (c) => {
  const svg = lanQrSvgFor(c.env.incoming.socket.remoteAddress, lanHosts, boundPort, token);
  if (!svg) return c.json({ ok: false, error: "not found" }, 404);
  return c.body(svg, 200, {
    "content-type": "image/svg+xml; charset=utf-8",
    // トークンが埋まった画像なのでキャッシュに残さない。
    "cache-control": "no-store",
  });
});

/** 判断が出るまでチャネルを待たせる 1 巡分。切れてもチャネルが取り直すので保留は消えない。 */
const PERMISSION_WAIT_MS = 60_000;

// 権限確認の中継はループバック限定。承認できる相手が増えると、平文 HTTP の LAN 越しに
// 任意のコマンド実行を許可できてしまう（スマホからの承認は Remote Control が担う）。
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

app.post("/api/permissions/:requestId", async (c) => {
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

  const pending = hub.decidePermission(c.req.param("requestId"), body.decision);
  // 端末側で先に答えられた後や期限切れの後は保留が無い。
  if (!pending) return c.json({ ok: false, error: "この確認はもう待っていません" }, 404);
  return c.json({ ok: true, decision: body.decision });
});

/** ループバック以外には存在ごと伏せる（理由は permissions.ts / lan.ts）。 */
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
  // 権限確認は手元の画面にだけ流す。LAN の画面には出さない（答えられないものを見せない）。
  const local = isLocalActor(c.env.incoming.socket.remoteAddress);
  return streamSSE(c, async (stream) => {
    let closed = false;
    let latest: SessionSnapshot[] | null = hub.snapshot();
    let dirty = true;
    const feedQueue: FeedItem[] = [];
    let permissions: PendingPermission[] | null = local ? hub.pendingPermissions() : null;

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
    const onPermissions = (list: PendingPermission[]) => {
      if (local) permissions = list;
    };
    const cleanup = () => {
      closed = true;
      hub.off("sessions", onSessions);
      hub.off("tick", onTick);
      hub.off("feed", onFeed);
      hub.off("permissions", onPermissions);
    };
    stream.onAbort(cleanup);

    // 登録から解除までを try で囲む。初回 write が失敗してもリスナーを残さない。
    try {
      hub.on("sessions", onSessions);
      hub.on("tick", onTick);
      hub.on("feed", onFeed);
      hub.on("permissions", onPermissions);

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
        if (permissions) {
          await stream.writeSSE({ event: "permissions", data: JSON.stringify(permissions) });
          permissions = null;
        }
        while (feedQueue.length) {
          await stream.writeSSE({ event: "feed", data: JSON.stringify(feedQueue.shift()) });
        }
        await stream.sleep(120);
      }
    } finally {
      cleanup();
    }
  });
});

if (existsSync(UI_DIST)) {
  const rel = relative(process.cwd(), UI_DIST) || ".";
  app.use("/*", serveStatic({ root: rel, index: "index.html" }));
  app.get("/*", serveStatic({ path: join(rel, "index.html") }));
} else {
  app.get("/", (c) =>
    c.text("UI が未ビルドです。`cd monitor/ui && npm install && npm run build` を実行してください。", 503),
  );
}

// 既定は localhost 限定。セッションへの書き込み口があるので、外に出すのは MONITOR_LAN=1 の時だけ。
serve({ fetch: app.fetch, port, hostname: lanEnabled ? "0.0.0.0" : "127.0.0.1" }, (info) => {
  boundPort = info.port;
  console.log(`ai-manager monitor: http://localhost:${info.port}`);
  console.log(`  GET /events (SSE) | GET /api/sessions | POST /hook`);
  if (token) {
    if (lanHosts.size === 0) console.log("  ⚠ LAN の IPv4 が見つかりません（Wi-Fi に繋がっていますか）");
    // 仮想 IF（VPN・Docker 等）まで QR を出すとどれを読むか分からなくなる。
    const shown = [...lanHosts].filter(isPrivateIPv4);
    void (async () => {
      const { default: qrcode } = await import("qrcode-terminal");
      for (const host of shown.length ? shown : [...lanHosts]) {
        const url = `http://${host}:${info.port}/?t=${encodeURIComponent(token)}`;
        console.log(`\n  LAN: ${url}`);
        // 64 文字の hex を別端末で手打ちするのは現実的でないので QR で読ませる。
        qrcode.generate(url, { small: true });
      }
    })();
  }
  if (!existsSync(UI_DIST)) console.log("  ⚠ ui/dist が無いため UI は配信されません");
});

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    hub.stop();
    process.exit(0);
  });
}
