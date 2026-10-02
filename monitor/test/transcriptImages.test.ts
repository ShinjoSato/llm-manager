// 会話履歴の画像。本文には目録だけを載せ、本体は行を読み直してバイナリで返す。
import { appendFileSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Hono } from "hono";
import {
  imageDataOf,
  imagesOf,
  isValidItemId,
  itemsFromLine,
  registerTranscriptRoutes,
  TranscriptLog,
  TranscriptStore,
} from "../src/transcriptApi.js";
import type { TranscriptResponse } from "../src/types.js";

let ok = 0;
let ng = 0;

function t(name: string, got: unknown, want: unknown): void {
  const pass = JSON.stringify(got) === JSON.stringify(want);
  pass ? ok++ : ng++;
  console.log(
    `  ${pass ? "OK  " : "NG  "}${name.padEnd(50)}${pass ? "" : `期待 ${JSON.stringify(want)} / 実際 ${JSON.stringify(got)}`}`,
  );
}

const TS = "2026-10-02T09:00:00.000Z";
// 1x1 の PNG（実データの形を保つため本物のヘッダーを使う）。
const PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64",
);
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46]);
const image = (mediaType: string, data: Buffer) => ({ type: "image", source: { type: "base64", media_type: mediaType, data: data.toString("base64") } });
const user = (uuid: string, content: unknown, extra: object = {}) =>
  JSON.stringify({ type: "user", uuid, timestamp: TS, message: { role: "user", content }, ...extra });
const assistant = (uuid: string, text: string) =>
  JSON.stringify({ type: "assistant", uuid, timestamp: TS, message: { role: "assistant", content: [{ type: "text", text }] } });

// ── 目録 ──
{
  const content = [
    image("image/png", PNG),
    { type: "text", text: "コンフリクトしてる" },
    image("image/svg+xml", Buffer.from("<svg/>")),
    { type: "image", source: { type: "url", url: "https://example.com/a.png" } },
    image("image/jpeg", JPEG),
  ];
  t("取り出せる形式だけを位置付きで載せる", imagesOf(content), [
    { index: 0, mediaType: "image/png" },
    { index: 3, mediaType: "image/jpeg" },
  ]);
  t("文字列の content は画像なし", imagesOf("hi"), []);
  t("本体は base64 を戻したもの", imageDataOf(content, 0)?.data.equals(PNG), true);
  t("SVG は返さない", imageDataOf(content, 1), null);
  t("base64 以外は返さない", imageDataOf(content, 2), null);
  t("範囲外は null", imageDataOf(content, 9), null);

  const [item] = itemsFromLine(JSON.parse(user("u1", content)), "line1", { parentId: null });
  t("発話に目録が付く", item?.images.map((i) => i.index), [0, 3]);
  t("本文に base64 を流さない", JSON.stringify(item).includes(PNG.toString("base64")), false);
  t("本文の印は従来どおり", item?.text, "[画像]\nコンフリクトしてる\n[画像]\n[画像]\n[画像]");
  const [only] = itemsFromLine(JSON.parse(user("u2", [image("image/png", PNG)])), "line2", { parentId: null });
  t("画像だけの発話も出す", [only?.text, only?.images.length], ["[画像]", 1]);
  const [reply] = itemsFromLine(JSON.parse(assistant("a1", "はい")), "line3", { parentId: null });
  t("応答の目録は空", reply?.images, []);
  const result = itemsFromLine(
    JSON.parse(user("u3", [{ type: "tool_result", tool_use_id: "x", content: [image("image/png", PNG)] }])),
    "line4",
    { parentId: null },
  );
  t("ツール結果の画像は出さない", result.length, 0);
}

// ── 要素 id ──
t("uuid:番号は通す", isValidItemId("9ebe6f6b-8bb4-4b6f-ae38-23c465ae94a0:0"), true);
t("行番号の id も通す", isValidItemId("line12:0"), true);
t("番号が無ければ通さない", isValidItemId("abc"), false);
t("パス区切りは通さない", isValidItemId("../x:0"), false);

// ── 行を読み直して取り出す（実ファイル） ──
const dir = mkdtempSync(join(tmpdir(), "monitor-transcript-images-"));
try {
  const path = join(dir, "s1.jsonl");
  // 先に日本語・絵文字の行を置き、バイト位置の計算がずれないことを確かめる。
  writeFileSync(path, `${user("u0", "前置き 🎉 日本語")}\n${JSON.stringify({ type: "attachment" })}\n`);
  const log = new TranscriptLog(path);
  log.read();
  appendFileSync(path, `${user("u1", [image("image/png", PNG), { type: "text", text: "見て" }, image("image/jpeg", JPEG)])}\n`);
  const half = user("u2", [image("image/png", PNG)]);
  appendFileSync(path, half.slice(0, 40));
  t("追記分の目録", log.read().map((i) => [i.id, i.images.length]), [["u1:0", 2]]);
  appendFileSync(path, `${half.slice(40)}\n${assistant("a1", "了解 ✅")}\n`);
  log.read();
  t("1 枚目", log.image("u1:0", 0)?.data.equals(PNG), true);
  t("2 枚目は形式も返す", [log.image("u1:0", 1)?.mediaType, log.image("u1:0", 1)?.data.equals(JPEG)], ["image/jpeg", true]);
  t("書きかけを跨いだ行も取り出せる", log.image("u2:0", 0)?.data.equals(PNG), true);
  t("画像の無い発話は null", log.image("u0:0", 0), null);
  t("知らない id は null", log.image("zz:0", 0), null);

  // 位置がずれていたら（不正な UTF-8 等）uuid で探し直す。
  const broken = new TranscriptLog(path);
  broken.read();
  (broken as any).imageLines.set("u2:0", { offset: 0, length: 10, uuid: "u2" });
  t("位置がずれても uuid で探し直す", broken.image("u2:0", 0)?.data.equals(PNG), true);

  // ルート
  const store = new TranscriptStore(
    () => [{ sessionId: "s1", cwd: dir }],
    (id) => (id === "s1" ? path : null),
  );
  const app = new Hono();
  registerTranscriptRoutes(app, store);
  const list = (await (await app.request("/api/sessions/s1/transcript")).json()) as TranscriptResponse;
  t("GET の目録", list.items.filter((i) => i.images.length).map((i) => i.id), ["u1:0", "u2:0"]);

  const res = await app.request("/api/sessions/s1/transcript/u1:0/images/0");
  t("画像は 200 と content-type", [res.status, res.headers.get("content-type")], [200, "image/png"]);
  t("中身はバイナリのまま", Buffer.from(await res.arrayBuffer()).equals(PNG), true);
  t("型を推測させない", res.headers.get("x-content-type-options"), "nosniff");
  t("共有キャッシュに置かせない", res.headers.get("cache-control"), "private, max-age=86400");
  const encoded = await app.request("/api/sessions/s1/transcript/u1%3A0/images/1");
  t("区切りを符号化した id も通る", [encoded.status, encoded.headers.get("content-type")], [200, "image/jpeg"]);
  t("範囲外は 404", (await app.request("/api/sessions/s1/transcript/u1:0/images/5")).status, 404);
  t("画像の無い発話は 404", (await app.request("/api/sessions/s1/transcript/a1:0/images/0")).status, 404);
  t("知らないセッションは 404", (await app.request("/api/sessions/s9/transcript/u1:0/images/0")).status, 404);
  t("不正な要素 id は 400", (await app.request("/api/sessions/s1/transcript/u1/images/0")).status, 400);
  t("不正な番号は 400", (await app.request("/api/sessions/s1/transcript/u1:0/images/-1")).status, 400);
  t("不正なセッション id は 400", (await app.request("/api/sessions/a..b/transcript/u1:0/images/0")).status, 400);
  store.stop();
} finally {
  rmSync(dir, { recursive: true, force: true });
}

console.log(`transcriptImages: ${ok} OK / ${ng} NG`);
if (ng > 0) process.exit(1);
