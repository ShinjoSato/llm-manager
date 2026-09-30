// 使用量ファイルの読み取り。statusline が書いた値をそのまま信じず、壊れた入力で画面を止めないことを押さえる。
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseUsage, readUsage } from "../src/usage.js";

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
  "週にリセット時刻があっても読む",
  parseUsage(JSON.stringify({ fetchedAt: 1, sevenDay: { usedPercentage: 30, resetsAt: 99 } }))
    ?.sevenDay,
  { usedPercentage: 30, resetsAt: 99 },
);
t(
  "リセット時刻が無いウィンドウは null",
  parseUsage(JSON.stringify({ fetchedAt: 1, fiveHour: { usedPercentage: 8 } }))?.fiveHour,
  { usedPercentage: 8, resetsAt: null },
);
t(
  "片方だけでも読む",
  parseUsage(JSON.stringify({ fetchedAt: 1, fiveHour: { usedPercentage: 8 } }))?.sevenDay,
  null,
);

// ── 壊れた入力 ──
t("壊れた JSON は null", parseUsage("not json"), null);
t("空文字は null", parseUsage(""), null);
t("配列は null", parseUsage("[]"), null);
t("空オブジェクトは null", parseUsage("{}"), null);
t("取得時刻が無ければ null", parseUsage(JSON.stringify({ fiveHour: { usedPercentage: 8 } })), null);
t(
  "両方のウィンドウが空なら null",
  parseUsage(JSON.stringify({ fetchedAt: 1, fiveHour: null, sevenDay: null })),
  null,
);
t(
  "使用率が数値でないウィンドウは落とす",
  parseUsage(JSON.stringify({ fetchedAt: 1, fiveHour: { usedPercentage: "42" }, sevenDay: { usedPercentage: 5 } }))
    ?.fiveHour,
  null,
);

// ── ファイル読み取り ──
const dir = mkdtempSync(join(tmpdir(), "usage-test-"));
const path = join(dir, "claude-usage.json");
t("ファイルが無ければ null", readUsage(path), null);
writeFileSync(path, FULL, "utf8");
t("あれば読む", readUsage(path)?.fiveHour?.usedPercentage, 42.7);
writeFileSync(path, "{ half written", "utf8");
t("半端な内容でも null で返る", readUsage(path), null);
rmSync(dir, { recursive: true, force: true });

console.log(`\nusage: ${ok} OK / ${ng} NG`);
if (ng > 0) process.exit(1);
