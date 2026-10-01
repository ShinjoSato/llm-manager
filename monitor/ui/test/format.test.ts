// 返答待ちの長さの文言。止まっていることが伝わる言い方になっているかを押さえる。
import { waited } from "../src/format.js";

let ok = 0;
let ng = 0;

function t(name: string, got: unknown, want: unknown): void {
  const pass = JSON.stringify(got) === JSON.stringify(want);
  pass ? ok++ : ng++;
  console.log(`  ${pass ? "OK  " : "NG  "}${name.padEnd(50)}${pass ? "" : `期待 ${JSON.stringify(want)} / 実際 ${JSON.stringify(got)}`}`);
}

const NOW = 1_750_000_000_000;
t("時刻が無ければ出さない", waited(null, NOW), null);
t("1 分未満は秒で出す", waited(NOW - 42_000, NOW), "42秒待っています");
t("分で出す", waited(NOW - 3 * 60_000 - 5_000, NOW), "3分待っています");
t("1 時間を超えたら時間と分", waited(NOW - (2 * 3600 + 7 * 60) * 1000, NOW), "2時間7分待っています");
t("時計がずれて未来でも負にしない", waited(NOW + 5_000, NOW), "0秒待っています");
t("言い回しを差し替えられる", waited(NOW - 120_000, NOW, "止まっています"), "2分止まっています");

console.log(`\n  ${ng === 0 ? "PASS" : "FAIL"}: ${ok} 件成功 / ${ng} 件失敗`);
if (ng > 0) process.exit(1);
