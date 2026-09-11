// トークンの比較と読み出し。ここが緩むと LAN から誰でも入れる。
import { loadOrCreateToken, tokenEquals } from "../src/token.js";

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
process.env.MONITOR_TOKEN = " env-token ";
t("環境変数を優先し前後の空白を落とす", loadOrCreateToken(), "env-token");
process.env.MONITOR_TOKEN = "   ";
const generated = loadOrCreateToken();
t("空白だけの環境変数は無視する", generated !== "   ", true);
t("生成/読み出しは 16 進", /^[0-9a-f]{64}$/.test(generated ?? ""), true);
t("同じ値が返る（毎回作り直さない）", loadOrCreateToken(), generated);
delete process.env.MONITOR_TOKEN;

console.log(`\n  ${ng === 0 ? "PASS" : "FAIL"}: ${ok} 件成功 / ${ng} 件失敗`);
if (ng) process.exitCode = 1;
