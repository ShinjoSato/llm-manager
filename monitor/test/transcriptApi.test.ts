// 会話履歴 API。チャット側は id で差分を取るので、整形・安定 ID・差分・購読の境界を押さえる。
import { appendFileSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Hono } from "hono";
import {
  isValidSessionId,
  itemsFromLine,
  parseSubscription,
  registerTranscriptRoutes,
  summarizeTool,
  TranscriptLog,
  TranscriptStore,
  type ParseContext,
} from "../src/transcriptApi.js";
import type { TranscriptEvent, TranscriptResponse } from "../src/types.js";

let ok = 0;
let ng = 0;

function t(name: string, got: unknown, want: unknown): void {
  const pass = JSON.stringify(got) === JSON.stringify(want);
  pass ? ok++ : ng++;
  console.log(
    `  ${pass ? "OK  " : "NG  "}${name.padEnd(50)}${pass ? "" : `期待 ${JSON.stringify(want)} / 実際 ${JSON.stringify(got)}`}`,
  );
}

const TS = "2026-09-30T13:12:32.000Z";
const AT = Date.parse(TS);

const user = (uuid: string, content: unknown, extra: object = {}) =>
  JSON.stringify({ type: "user", uuid, timestamp: TS, message: { role: "user", content }, ...extra });
const assistant = (uuid: string, content: unknown[]) =>
  JSON.stringify({ type: "assistant", uuid, timestamp: TS, message: { role: "assistant", content } });

// ── 1 行の整形 ──
{
  const ctx: ParseContext = { parentId: null };
  const p = itemsFromLine(JSON.parse(user("u1", "こんにちは")), "line1", ctx);
  t("プロンプトは user", p, [
    { id: "u1:0", kind: "user", at: AT, text: "こんにちは", tool: null, parentId: null },
  ]);
  t("プロンプトが以降の親になる", ctx.parentId, "u1:0");

  const tool = itemsFromLine(
    JSON.parse(assistant("a1", [{ type: "tool_use", name: "Read", input: { file_path: "/x/a.ts" } }])),
    "line2",
    ctx,
  );
  t("応答前のツールはプロンプトにぶら下がる", tool[0]?.parentId, "u1:0");
  t("ツールの要約", tool[0]?.tool, { name: "Read", description: null, target: "/x/a.ts" });

  const text = itemsFromLine(JSON.parse(assistant("a2", [{ type: "text", text: " 読みました " }])), "line3", ctx);
  t("テキスト応答は assistant（前後の空白を落とす）", [text[0]?.kind, text[0]?.text], ["assistant", "読みました"]);
  const next = itemsFromLine(
    JSON.parse(assistant("a3", [{ type: "tool_use", name: "Bash", input: { command: "ls\npwd", description: "一覧" } }])),
    "line4",
    ctx,
  );
  t("応答後のツールは応答にぶら下がる", next[0]?.parentId, "a2:0");
  t("コマンドは 1 行目だけ", next[0]?.tool, { name: "Bash", description: "一覧", target: "ls" });

  t(
    "1 行に複数ブロックがあれば番号で分ける",
    itemsFromLine(
      JSON.parse(assistant("a4", [{ type: "thinking", thinking: "" }, { type: "text", text: "A" }, { type: "tool_use", name: "Glob", input: { pattern: "*.ts" } }])),
      "line5",
      { parentId: null },
    ).map((i) => [i.id, i.kind, i.parentId]),
    [["a4:1", "assistant", null], ["a4:2", "tool", "a4:1"]],
  );
}

// ── 出さない行 ──
{
  const none = (line: string) => itemsFromLine(JSON.parse(line), "lineX", { parentId: null }).length;
  t("tool_result は出さない", none(user("u", [{ type: "tool_result", tool_use_id: "x", content: "ok" }])), 0);
  t("isMeta は出さない", none(user("u", "meta", { isMeta: true })), 0);
  t("仕組み側の注入は出さない", none(user("u", "<system-reminder>x</system-reminder>")), 0);
  t("サブエージェント側の行は出さない", none(user("u", "hi", { isSidechain: true })), 0);
  t("要約は出さない", none(user("u", "summary", { isCompactSummary: true })), 0);
  t("thinking だけの応答は出さない", none(assistant("a", [{ type: "thinking", thinking: "..." }])), 0);
  t("空のプロンプトは出さない", none(user("u", "   ")), 0);
  t("それ以外の type は出さない", none(JSON.stringify({ type: "system", message: { content: "x" } })), 0);
}

// ── スラッシュコマンドと画像 ──
{
  const [cmd] = itemsFromLine(
    JSON.parse(user("u", "<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>42</command-args>")),
    "l",
    { parentId: null },
  );
  t("スラッシュコマンドは打った形に戻す", cmd?.text, "/review 42");
  const [img] = itemsFromLine(
    JSON.parse(user("u", [{ type: "text", text: "これ見て" }, { type: "image", source: {} }])),
    "l",
    { parentId: null },
  );
  t("画像は印だけ残す", img?.text, "これ見て\n[画像]");
  const [noUuid] = itemsFromLine(JSON.parse(JSON.stringify({ type: "user", message: { content: "x" } })), "line7", { parentId: null });
  t("uuid の無い行は行番号で ID を作る", [noUuid?.id, noUuid?.at], ["line7:0", null]);
}

// ── ツール要約 ──
t("Grep はパターンと場所", summarizeTool("Grep", { pattern: "foo", path: "src" }).target, "foo (src)");
t("Skill はスキル名", summarizeTool("Skill", { skill: "developer-plugin:dev-done" }).target, "developer-plugin:dev-done");
t("Agent は種別と説明", summarizeTool("Agent", { subagent_type: "Explore", description: "探す" }), {
  name: "Agent",
  description: "探す",
  target: "Explore",
});
t("入力が無くても落ちない", summarizeTool("TodoWrite", undefined), { name: "TodoWrite", description: null, target: null });
t("長い対象は切る", summarizeTool("Bash", { command: "x".repeat(500) }).target?.length, 301);

// ── sessionId と購読指定 ──
t("UUID は通す", isValidSessionId("9c5a73ea-48db-4aef-9ca5-a772f22c89a0"), true);
t("パス区切りは通さない", isValidSessionId("../etc"), false);
t("空は通さない", isValidSessionId(""), false);
t("購読指定なしは購読しない", parseSubscription(undefined), undefined);
t("* は全セッション", parseSubscription("*"), null);
t("カンマ区切り（不正な id は捨てる）", [...(parseSubscription("a-1, ../x ,b2") ?? [])], ["a-1", "b2"]);
t("不正な id しか無ければ購読しない", parseSubscription("../x"), undefined);

// ── 差分読みと購読（実ファイル） ──
const dir = mkdtempSync(join(tmpdir(), "monitor-transcript-"));
try {
  const path = join(dir, "s1.jsonl");
  writeFileSync(path, `${user("u1", "一つ目")}\n${JSON.stringify({ type: "attachment" })}\n${assistant("a1", [{ type: "text", text: "はい" }])}\n`);

  const log = new TranscriptLog(path);
  t("初回は先頭から全部読む", log.read().map((i) => i.id), ["u1:0", "a1:0"]);
  t("変化が無ければ何も返さない", log.read().length, 0);

  // 書きかけの行は持ち越し、書き終わってから出す。
  const half = user("u2", "二つ目 🎉");
  appendFileSync(path, half.slice(0, 20));
  t("書きかけの行は出さない", log.read().length, 0);
  appendFileSync(path, `${half.slice(20)}\n`);
  t("書き終わったら出す（マルチバイトも壊れない）", log.read().map((i) => i.text), ["二つ目 🎉"]);

  t("after 無しは全件", log.since(undefined), { items: log.items, reset: false });
  t("after 以降だけ", log.since("a1:0").items.map((i) => i.id), ["u2:0"]);
  t("末尾を渡すと空", log.since("u2:0"), { items: [], reset: false });
  t("知らない id は全件 + reset", [log.since("nope").items.length, log.since("nope").reset], [3, true]);

  // ストア: GET と SSE の配信
  const store = new TranscriptStore(
    () => [{ sessionId: "s1", cwd: dir }],
    (id) => (id === "s1" ? path : null),
  );
  const events: TranscriptEvent[] = [];
  const off = store.subscribe("s1", (ev) => events.push(ev));
  t("購読時点までは既読扱い（過去を流さない）", events.length, 0);

  appendFileSync(path, `${assistant("a2", [{ type: "tool_use", name: "Edit", input: { file_path: "/p/q.ts" } }])}\n`);
  store.poll();
  t("追記は sessionId 付きで届く", events.map((e) => [e.sessionId, e.items.map((i) => i.id)]), [["s1", ["a2:0"]]]);
  t("ツールは直前の発話にぶら下がる", events[0]?.items[0]?.parentId, "u2:0");

  appendFileSync(path, `${user("u3", "三つ目")}\n`);
  const got = store.get("s1", "a2:0");
  t("GET の差分", got?.items.map((i) => i.id), ["u3:0"]);
  t("GET で読んだ分も購読者に届く", events.at(-1)?.items.map((i) => i.id), ["u3:0"]);
  t("ログが無ければ null", store.get("s2"), null);

  const others: TranscriptEvent[] = [];
  const offAll = store.subscribe("*", (ev) => others.push(ev));
  const offOther = store.subscribe("zzz", () => {
    throw new Error("別セッションの購読者に届いてはいけない");
  });
  appendFileSync(path, `${assistant("a3", [{ type: "text", text: "完了" }])}\n`);
  store.poll();
  t("* の購読者にも届く", others.map((e) => e.items.map((i) => i.id)), [["a3:0"]]);
  off();
  offAll();
  offOther();
  appendFileSync(path, `${user("u4", "四つ目")}\n`);
  store.poll();
  t("解除後は届かない", [events.length, others.length], [3, 1]);
  store.stop();

  // ルート
  const app = new Hono();
  registerTranscriptRoutes(app, store);
  const res = await app.request("/api/sessions/s1/transcript?after=a3:0");
  const body = (await res.json()) as TranscriptResponse;
  t("GET 200 と形", [res.status, body.sessionId, body.reset, body.items.map((i) => i.text)], [200, "s1", false, ["四つ目"]]);
  t("キャッシュさせない", res.headers.get("cache-control"), "no-store");
  t("見つからなければ 404", (await app.request("/api/sessions/s9/transcript")).status, 404);
  t("不正な id は 400", (await app.request("/api/sessions/a..b/transcript")).status, 400);
} finally {
  rmSync(dir, { recursive: true, force: true });
}

console.log(`transcriptApi: ${ok} OK / ${ng} NG`);
if (ng > 0) process.exit(1);
