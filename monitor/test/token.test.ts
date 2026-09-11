// トークンの比較と読み出し。ここが緩むと LAN から誰でも入れる。
import { loadOrCreateToken, MIN_TOKEN_LENGTH, tokenEquals } from "../src/token.js";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// 本物の secrets/monitor-token を作らない。テストを走らせただけで認証情報が生えるのを防ぐ。
const dir = mkdtempSync(join(tmpdir(), "monitor-token-"));
const file = join(dir, "monitor-token");

let ok = 0;
let ng = 0;

function t(name: string, got: unknown, want: unknown): void {
  const pass = JSON.stringify(got) === JSON.stringify(want);
  pass ? ok++ : ng++;
  console.log(
    `  ${pass ? "OK  " : "NG  "}${name.padEnd(50)}${pass ? "" : `期待 ${JSON.stringify(want)} / 実際 ${JSON.stringify(got)}`}`,
  );
}

const TOKEN = "a".repeat(64);

// ── 比較 ──
t("同じ値は一致", tokenEquals(TOKEN, TOKEN), true);
t("1 文字違いは不一致", tokenEquals(TOKEN, "b" + "a".repeat(63)), false);
t("末尾 1 文字違いも不一致", tokenEquals(TOKEN, "a".repeat(63) + "b"), false);
t("前方一致は不一致", tokenEquals(TOKEN, "a".repeat(63)), false);
t("長いものは不一致", tokenEquals(TOKEN, TOKEN + "a"), false);
t("空文字は不一致", tokenEquals(TOKEN, ""), false);
t("未提示は不一致", tokenEquals(TOKEN, undefined), false);
t("cookie 無し（null）は不一致", tokenEquals(TOKEN, null), false);
t("大文字小文字は区別する", tokenEquals(TOKEN, "A".repeat(64)), false);
// 非 ASCII でもバイト長で比較が落ちないこと
t("マルチバイトでも一致する", tokenEquals("トークン", "トークン"), true);
t("マルチバイトの別値は不一致", tokenEquals("トークン", "とーくん"), false);

// ── 読み出し ──
process.env.MONITOR_TOKEN = " env-token-0123456789abcdef0123456789 ";
t("環境変数を優先し前後の空白を落とす", loadOrCreateToken(file), "env-token-0123456789abcdef0123456789");
process.env.MONITOR_TOKEN = "   ";
const generated = loadOrCreateToken(file);
t("空白だけの環境変数は無視する", generated !== "   ", true);
t("生成/読み出しは 16 進", /^[0-9a-f]{64}$/.test(generated ?? ""), true);
t("同じ値が返る（毎回作り直さない）", loadOrCreateToken(file), generated);

// 短い環境変数トークンは受け付けない（LAN 公開の唯一の防壁になるため）
process.env.MONITOR_TOKEN = "short";
t("短すぎる環境変数は使わない", loadOrCreateToken(file), null);
t("下限は 32 文字", MIN_TOKEN_LENGTH, 32);
process.env.MONITOR_TOKEN = "x".repeat(MIN_TOKEN_LENGTH);
t("下限ちょうどは通す", loadOrCreateToken(file), "x".repeat(MIN_TOKEN_LENGTH));
delete process.env.MONITOR_TOKEN;

// 読めない置き場では作り直さない（既存端末の cookie を黙って無効にしないため）
t("読めない置き場では null", loadOrCreateToken("/dev/null/nope/monitor-token"), null);

rmSync(dir, { recursive: true, force: true });
delete process.env.MONITOR_TOKEN;

console.log(`\n  ${ng === 0 ? "PASS" : "FAIL"}: ${ok} 件成功 / ${ng} 件失敗`);
if (ng) process.exitCode = 1;
