// Claude Code のチャネル（MCP server / stdio）。権限確認を monitor の画面へ中継する。
// 起動は Claude Code 側: `claude --dangerously-load-development-channels server:<name>`。
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

/** monitor の位置。別ポートで動かしている時だけ環境変数で差し替える。 */
const MONITOR_URL = (process.env.MONITOR_URL ?? "http://127.0.0.1:8766").replace(/\/+$/, "");
/** 1 回の長ポーリングの上限。monitor 側の待ち時間より長くして、応答を取りこぼさない。 */
const POLL_TIMEOUT_MS = 90_000;
/** monitor が落ちている時の再試行間隔。端末のダイアログは開いたままなので急がない。 */
const RETRY_DELAY_MS = 5_000;

const PermissionRequestSchema = z.object({
  method: z.literal("notifications/claude/channel/permission_request"),
  params: z.object({
    request_id: z.string(),
    tool_name: z.string(),
    // 説明も引数も Claude Code が組み立てた表示用の文字列。中継するだけで解釈しない。
    description: z.string(),
    input_preview: z.string(),
  }),
});

/** 返す判断。`allow` / `deny` しかない（「常に許可」は表現できない）。 */
type Verdict = { method: "notifications/claude/channel/permission"; params: { request_id: string; behavior: "allow" | "deny" } };

const mcp = new Server<never, Verdict, never>(
  { name: "ai-manager-monitor", version: "0.1.0" },
  {
    capabilities: {
      experimental: {
        "claude/channel": {}, // チャネルとして登録させる
        "claude/channel/permission": {}, // 権限確認の中継をオプトイン
      },
    },
    instructions:
      "ai-manager monitor へ権限確認を中継するだけのチャネルです。" +
      "イベントは届かないので、返信も不要です。",
  },
);

mcp.setNotificationHandler(PermissionRequestSchema, async ({ params }) => {
  const body = JSON.stringify({
    requestId: params.request_id,
    toolName: params.tool_name,
    description: params.description,
    inputPreview: params.input_preview,
    // チャネルは Claude Code の子プロセス。親 PID がそのままセッションの PID になる。
    pid: process.ppid,
    cwd: process.cwd(),
  });

  // 判断が出るまで取り直し続ける。timeout は 1 巡の区切りで、保留は monitor 側に残っている。
  for (;;) {
    const outcome = await ask(body);
    if (outcome === "allow" || outcome === "deny") {
      await mcp.notification({
        method: "notifications/claude/channel/permission",
        params: { request_id: params.request_id, behavior: outcome },
      });
      return;
    }
    // dropped = 端末側で答えられたか期限切れ。これ以上待たない。
    if (outcome === "dropped") return;
    if (outcome === "unreachable") await sleep(RETRY_DELAY_MS);
  }
});

/** monitor に預けて判断を待つ。届かなければ `unreachable`。 */
async function ask(body: string): Promise<"allow" | "deny" | "timeout" | "dropped" | "unreachable"> {
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), POLL_TIMEOUT_MS);
  try {
    const res = await fetch(`${MONITOR_URL}/api/channel/permissions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
      signal: abort.signal,
    });
    if (!res.ok) {
      // 400 系は形が悪いので、取り直しても同じ。諦めて端末のダイアログに任せる。
      log(`monitor が申請を受け付けません（HTTP ${res.status}）`);
      return res.status >= 500 ? "unreachable" : "dropped";
    }
    const json = (await res.json()) as { outcome?: unknown };
    const outcome = json.outcome;
    if (outcome === "allow" || outcome === "deny" || outcome === "dropped") return outcome;
    return "timeout";
  } catch {
    log(`monitor に繋がりません（${MONITOR_URL}）。${RETRY_DELAY_MS / 1000} 秒後に取り直します`);
    return "unreachable";
  } finally {
    clearTimeout(timer);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** stdout は JSON-RPC の通り道なので、ログは必ず stderr へ出す。 */
function log(message: string): void {
  console.error(`[monitor-channel] ${message}`);
}

await mcp.connect(new StdioServerTransport());
log(`接続しました（監視先 ${MONITOR_URL} / セッション PID ${process.ppid}）`);
