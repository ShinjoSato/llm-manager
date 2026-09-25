// 残量カードの表示。古い値をそれと分からず見せないことが主眼。
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { UsageCard, USAGE_STALE_MS } from "../src/components/UsageCard.js";
import type { UsageWindow } from "../../src/types.js";

const NOW = 1_800_000_000_000;

let ok = 0;
let ng = 0;

function html(w: UsageWindow | null, fetchedAt: number | null): string {
  return renderToStaticMarkup(
    React.createElement(UsageCard, {
      icon: null,
      label: "5h 残り",
      window: w,
      fetchedAt,
      now: NOW,
    }),
  );
}

function t(name: string, got: boolean, want = true): void {
  const pass = got === want;
  pass ? ok++ : ng++;
  console.log(`  ${pass ? "OK  " : "NG  "}${name.padEnd(48)}${pass ? "" : `期待 ${want}`}`);
}

// ── 値がある時 ──
const fresh = html({ usedPercentage: 42.7, resetsAt: NOW + 7_325_000 }, NOW - 30_000);
t("残りは 100 − 使用率", fresh.includes("57%"));
t("リセットまでの時間を添える", fresh.includes("リセット 2時間2分後"));
t("取得からの経過も出す", fresh.includes("取得 30秒前"));
t("余裕があれば警告色にしない", !fresh.includes("text-rose-300"));

const low = html({ usedPercentage: 88, resetsAt: NOW + 300_000 }, NOW);
t("残りがしきい値を割ったら赤", low.includes("text-rose-300"));
t("12% と出る", low.includes("12%"));

const mid = html({ usedPercentage: 70, resetsAt: null }, NOW);
t("残り 30% は注意色", mid.includes("text-amber-300"));
t("リセット時刻が無ければ添えない", !mid.includes("リセット"));
t("それでも取得時刻は出す", mid.includes("取得"));

// ── 古い値・値が無い時 ──
const stale = html({ usedPercentage: 10, resetsAt: null }, NOW - USAGE_STALE_MS - 1);
t("古い値は取得時刻を目立たせる", stale.includes("text-amber-300"));
t("古い理由を title で補う", stale.includes("稼働中のセッションが無い間"));

const none = html(null, null);
t("値が無ければ —", none.includes("—"));
t("設定を促す", none.includes("statusLine 未設定"));

console.log(`\n  ${ng === 0 ? "PASS" : "FAIL"}: ${ok} 件成功 / ${ng} 件失敗`);
if (ng) process.exitCode = 1;
