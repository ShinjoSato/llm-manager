// ai-manager MCP サーバー（Claude Code 用ネイティブツール、stdio）。
// HTTP と同じデータ中核（core/*）を共有する。
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { collect, collectAndSave, readDashboard } from "../core/collect.js";
import { collectAppStore } from "../core/appstore.js";
import { collectRanking } from "../core/ranking.js";
import { collectTrends } from "../core/trends.js";
import { collectCalendar, createEvent } from "../core/calendar.js";
import { readState, writeState } from "../core/state.js";
import { readTsv } from "../core/tsv.js";
import { REGISTRY } from "../core/paths.js";

const server = new McpServer({ name: "ai-manager", version: "0.1.0" });

const json = (data: unknown) => ({
  content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }],
});

server.registerTool(
  "list_projects",
  {
    title: "管理対象プロジェクト一覧",
    description: "ai-manager が管理する全プロジェクト（registry.tsv）を返す。",
    inputSchema: {},
  },
  async () => json(
    readTsv(REGISTRY)
      .filter((r) => r.length >= 3)
      .map((r) => ({ name: r[0], path: r[1], status: r[2], note: r[3] ?? "" })),
  ),
);

server.registerTool(
  "get_dashboard",
  {
    title: "ダッシュボード取得",
    description:
      "保存済みの統合ダッシュボード（各PJのボード/PR/git/App Store状況）を返す。" +
      "最新化したい場合は refresh_dashboard を使う。",
    inputSchema: {},
  },
  async () => json(readDashboard() ?? (await collectAndSave())),
);

server.registerTool(
  "refresh_dashboard",
  {
    title: "ダッシュボード再収集",
    description: "gh/git/App Store Connect から最新を再収集し、保存して返す（時間がかかる）。",
    inputSchema: {},
  },
  async () => json(await collectAndSave()),
);

server.registerTool(
  "get_app_status",
  {
    title: "App Store 審査状況",
    description:
      "App Store Connect の状況（審査ステータス・提出フロー・TestFlightビルド・レビュー・指標）を返す。" +
      "project を指定すると個別、省略で全登録アプリ。",
    inputSchema: { project: z.string().optional().describe("管理対象名（例: mirio）。省略で全件") },
  },
  async ({ project }) => json(await collectAppStore(project)),
);

server.registerTool(
  "get_ranking",
  {
    title: "App Store ランキング",
    description:
      "Apple Marketing Tools RSS（無料）から App Store ランキング（既定 jp の top-free/top-paid）を返す。" +
      "自アプリ（appstore.tsv）の各チャートでの順位（または圏外=null）も付与する。",
    inputSchema: {},
  },
  async () => json(await collectRanking()),
);

server.registerTool(
  "get_trends",
  {
    title: "Google Trends 急上昇",
    description:
      "Google Trends 公式 RSS（無料）からその日の急上昇検索ワード（おおよそのボリューム・関連ニュース付き）を返す。" +
      "geo は地域コード（既定 JP）。",
    inputSchema: { geo: z.string().optional().describe("地域コード（既定 JP）") },
  },
  async ({ geo }) => json(await collectTrends(geo ?? "JP")),
);

server.registerTool(
  "get_state",
  {
    title: "手動レイヤー取得",
    description: "Claude が編集する重点メモ・pin・ハイライトキーワード（manager-state）を返す。",
    inputSchema: {},
  },
  async () => json(readState()),
);

server.registerTool(
  "set_focus_notes",
  {
    title: "今日の重点を更新",
    description: "『今日の重点』(focusNotes) を置き換える。ダッシュボードに即反映される。",
    inputSchema: { notes: z.array(z.string()).describe("重点メモの配列（1要素=1項目）") },
  },
  async ({ notes }) => {
    const state = readState();
    state.focusNotes = notes;
    state.updatedAt = new Date().toISOString().slice(0, 10);
    return json(writeState(state));
  },
);

server.registerTool(
  "add_pin",
  {
    title: "要注目をピン留め",
    description: "指定イシューを『要注目』にピン留めする（pinned に追加）。",
    inputSchema: {
      project: z.string().describe("管理対象名"),
      number: z.number().describe("イシュー/PR番号"),
      reason: z.string().describe("ピンする理由"),
    },
  },
  async ({ project, number, reason }) => {
    const state = readState();
    state.pinned = state.pinned.filter((p) => !(p.project === project && p.number === number));
    state.pinned.push({ project, number, reason });
    state.updatedAt = new Date().toISOString().slice(0, 10);
    return json(writeState(state));
  },
);

server.registerTool(
  "list_calendar_events",
  {
    title: "今後の予定",
    description: "Google カレンダーの今後 N 日分の予定を返す（既定7日）。未設定なら null。",
    inputSchema: { days: z.number().optional().describe("取得する日数（既定7）") },
  },
  async ({ days }) => json(await collectCalendar(days ?? 7)),
);

server.registerTool(
  "create_calendar_event",
  {
    title: "予定を作成",
    description: "Google カレンダーに予定を作成する。start/end は ISO8601（例 2026-06-10T14:00:00+09:00）。",
    inputSchema: {
      title: z.string().describe("予定タイトル"),
      start: z.string().describe("開始 ISO8601"),
      end: z.string().describe("終了 ISO8601"),
      location: z.string().optional().describe("場所（任意）"),
    },
  },
  async ({ title, start, end, location }) => json(await createEvent({ title, start, end, location })),
);

const transport = new StdioServerTransport();
await server.connect(transport);
console.error("ai-manager MCP server running (stdio)");
