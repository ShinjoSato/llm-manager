// 使用量ファイルの読み取り。未生成・壊れた入力で collect() を落とさないことを押さえる。
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { collectUsage, parseUsage } from "../src/core/usage.js";

let ok = 0;
let ng = 0;

function t(name: string, got: unknown, want: unknown): void {
  const pass = JSON.stringify(got) === JSON.stringify(want);
  pass ? ok++ : ng++;
  console.log(
    `  ${pass ? "OK  " : "NG  "}${name.padEnd(52)}${pass ? "" : `期待 ${JSON.stringify(want)} / 実際 ${JSON.stringify(got)}`}`,
  );
}

const FULL = JSON.stringify({
  fetchedAt: 1750000000000,
  fiveHour: { usedPercentage: 42.7, resetsAt: 1750007325000 },
  sevenDay: { usedPercentage: 61.2, resetsAt: null },
});

// ── 正常系 ──
t("両方のウィンドウを読む", parseUsage(FULL), {
  fetchedAt: 1750000000000,
  fiveHour: { usedPercentage: 42.7, resetsAt: 1750007325000 },
  sevenDay: { usedPercentage: 61.2, resetsAt: null },
});
t(
  "リセット時刻が無いウィンドウは null",
  parseUsage(JSON.stringify({ fetchedAt: 1, fiveHour: { usedPercentage: 8 } }))?.fiveHour,
  { usedPercentage: 8, resetsAt: null },
);

// ── 壊れた入力 ──
t("壊れた JSON は null", parseUsage("not json"), null);
t("空オブジェクトは null", parseUsage("{}"), null);
t("取得時刻が無ければ null", parseUsage(JSON.stringify({ fiveHour: { usedPercentage: 8 } })), null);
t(
  "使用率が数値でないウィンドウは落とす",
  parseUsage(JSON.stringify({ fetchedAt: 1, fiveHour: { usedPercentage: "42" }, sevenDay: { usedPercentage: 5 } }))
    ?.fiveHour,
  null,
);

// ── ファイル読み取り（statusLine 未設定なら no-op）──
const dir = mkdtempSync(join(tmpdir(), "usage-test-"));
const path = join(dir, "claude-usage.json");
t("ファイルが無ければ null", collectUsage(path), null);
writeFileSync(path, FULL, "utf-8");
t("あれば読む", collectUsage(path)?.sevenDay?.usedPercentage, 61.2);
writeFileSync(path, "{ half written", "utf-8");
t("半端な内容でも null で返る", collectUsage(path), null);
rmSync(dir, { recursive: true, force: true });

console.log(`usage: ${ok} OK / ${ng} NG`);
if (ng > 0) process.exit(1);
