// 通知の発火判定。鳴らしすぎ・鳴らなすぎのどちらも困るので境界を押さえる。
import { loadSetting, shouldNotify, type NotifySetting } from "../src/useNotify.js";

const BOTH: NotifySetting = { idle: true, attention: true, usage: false };
const ONLY_ATTENTION: NotifySetting = { idle: false, attention: true, usage: false };
const ONLY_IDLE: NotifySetting = { idle: true, attention: false, usage: false };
const OFF: NotifySetting = { idle: false, attention: false, usage: false };

let ok = 0;
let ng = 0;

function t(name: string, got: boolean, want: boolean): void {
  const pass = got === want;
  pass ? ok++ : ng++;
  console.log(
    `  ${pass ? "OK  " : "NG  "}${name.padEnd(52)}${pass ? "" : `期待 ${want} / 実際 ${got}`}`,
  );
}

// 初回と据え置きでは鳴らさない
t("初回（前の状態が無い）は鳴らさない", shouldNotify(undefined, "permission", BOTH), false);
t("同じ状態が続く間は鳴らさない", shouldNotify("permission", "permission", BOTH), false);
t("待機が続く間も鳴らさない", shouldNotify("idle", "idle", BOTH), false);

// 要対応
t("稼働 → 権限待ちで鳴る", shouldNotify("working", "permission", ONLY_ATTENTION), true);
t("待機 → 入力待ちで鳴る", shouldNotify("idle", "waiting", ONLY_ATTENTION), true);
t("稼働 → エラーで鳴る", shouldNotify("working", "error", ONLY_ATTENTION), true);
t("要対応がオフなら鳴らない", shouldNotify("working", "permission", ONLY_IDLE), false);

// 待機
t("稼働 → 待機で鳴る", shouldNotify("working", "idle", ONLY_IDLE), true);
t("権限待ち → 待機では鳴らさない", shouldNotify("permission", "idle", ONLY_IDLE), false);
t("待機がオフなら鳴らない", shouldNotify("working", "idle", ONLY_ATTENTION), false);

// 鳴らしたくない遷移
t("待機 → 稼働は鳴らさない", shouldNotify("idle", "working", BOTH), false);
t("稼働 → 終了は鳴らさない", shouldNotify("working", "stopped", BOTH), false);
t("両方オフなら何も鳴らない", shouldNotify("working", "permission", OFF), false);

// localStorage が無い Node 上でも既定値に落ちる
t("localStorage が無くても既定値を返す", typeof loadSetting().attention === "boolean", true);

// 既定でどれかがオンなら、許可を求める導線が要る（オンなのに鳴らない状態を作らない）
const d = loadSetting();
t("既定でどれかがオンになっている", d.idle || d.attention, true);

console.log(`\n  ${ng === 0 ? "PASS" : "FAIL"}: ${ok} 件成功 / ${ng} 件失敗`);
if (ng) process.exitCode = 1;

// ── SSE が毎秒フルスナップショットを送る流れを再現する ──
import { collectPending } from "../src/useNotify.js";
import type { SessionStatus } from "../../src/types.js";

function feed(
  prev: Map<string, SessionStatus>,
  last: Map<string, number>,
  status: SessionStatus,
  now: number,
  setting = BOTH,
) {
  return collectPending(
    [{ sessionId: "s1", project: "janken-five", status }],
    prev, last, setting, now,
  );
}

{
  const prev = new Map<string, SessionStatus>();
  const last = new Map<string, number>();
  let now = 1_000_000;

  // 接続直後のスナップショット
  t("接続直後は鳴らない", feed(prev, last, "idle", now).length === 0, true);
  now += 1000;
  t("同じ状態が続いても鳴らない", feed(prev, last, "idle", now).length === 0, true);
  now += 1000;
  // ここで権限待ちに変わる
  const hit = feed(prev, last, "permission", now);
  t("idle → permission で 1 件検出される", hit.length === 1, true);
  t("検出された前の状態が idle", hit[0]?.was === "idle", true);
  now += 1000;
  t("次の秒は同じ状態なので鳴らない", feed(prev, last, "permission", now).length === 0, true);
  now += 1000;
  t("permission → idle は鳴らない（待機オンでも）", feed(prev, last, "idle", now).length === 0, true);
  now += 5000;
  t("再び permission になれば鳴る", feed(prev, last, "permission", now).length === 1, true);
}

{
  // クールダウン
  const prev = new Map<string, SessionStatus>();
  const last = new Map<string, number>();
  let now = 2_000_000;
  feed(prev, last, "idle", now);
  now += 1000;
  t("1 回目は鳴る", feed(prev, last, "permission", now).length === 1, true);
  now += 1000;
  feed(prev, last, "idle", now);
  now += 1000;
  t("4 秒以内の 2 回目は抑制される", feed(prev, last, "waiting", now).length === 0, true);
  now += 5000;
  feed(prev, last, "idle", now);
  now += 1000;
  t("4 秒を過ぎれば再び鳴る", feed(prev, last, "permission", now).length === 1, true);
}

{
  // 消えたセッションの掃除
  const prev = new Map<string, SessionStatus>();
  const last = new Map<string, number>();
  collectPending([{ sessionId: "a", project: "x", status: "idle" }], prev, last, BOTH, 1);
  collectPending([{ sessionId: "b", project: "y", status: "idle" }], prev, last, BOTH, 2);
  t("消えたセッションの記録は捨てられる", prev.has("a") === false && prev.has("b"), true);
}

// ── 上限の残量アラート ──
import { collectUsageAlerts, emptyUsageAlertState, USAGE_THRESHOLD } from "../src/useNotify.js";
import { USAGE_STALE_MS } from "../src/format.js";
import type { UsageSnapshot } from "../../src/types.js";

const NOW = 1_700_000_000_000;

const snap = (
  five: number | null,
  seven: number | null,
  resetsAt: number | null = NOW + 60_000,
  fetchedAt: number = NOW,
): UsageSnapshot => ({
  fetchedAt,
  fiveHour: five === null ? null : { usedPercentage: five, resetsAt },
  sevenDay: seven === null ? null : { usedPercentage: seven, resetsAt: null },
});

{
  const state = emptyUsageAlertState();
  t("しきい値を割っていなければ鳴らない", collectUsageAlerts(snap(50, 50), state, true, NOW).length === 0, true);
  t("残りちょうど 20% では鳴らない", collectUsageAlerts(snap(80, 50), state, true, NOW).length === 0, true);
  const hit = collectUsageAlerts(snap(81, 50), state, true, NOW);
  t("残り 19% で 5h だけ鳴る", hit.length === 1 && hit[0]?.kind === "fiveHour", true);
  t("同じウィンドウでは鳴り続けない", collectUsageAlerts(snap(85, 50), state, true, NOW).length === 0, true);
  const reset = collectUsageAlerts(snap(90, 50, NOW + 120_000), state, true, NOW);
  t("ウィンドウが替われば再び鳴る", reset.length === 1 && reset[0]?.kind === "fiveHour", true);
}

{
  const state = emptyUsageAlertState();
  t("週も割れば鳴る", collectUsageAlerts(snap(10, 95), state, true, NOW).map((a) => a.kind).join() === "sevenDay", true);
  t("週も 1 回だけ", collectUsageAlerts(snap(10, 96), state, true, NOW).length === 0, true);
  // 週はリセット時刻が無いので、残りが戻ったことでウィンドウの切り替わりを見る
  collectUsageAlerts(snap(10, 5), state, true, NOW);
  t("残りが戻った後は再び鳴る", collectUsageAlerts(snap(10, 97), state, true, NOW).length === 1, true);
}

{
  const state = emptyUsageAlertState();
  t("オフなら鳴らない", collectUsageAlerts(snap(99, 99), state, false, NOW).length === 0, true);
  t("オンにしたら鳴る", collectUsageAlerts(snap(99, 99), state, true, NOW).length === 2, true);
}

{
  const state = emptyUsageAlertState();
  t("値が無ければ鳴らない", collectUsageAlerts(null, state, true, NOW).length === 0, true);
  t("ウィンドウが欠けていても落ちない", collectUsageAlerts(snap(null, null), state, true, NOW).length === 0, true);
  t("しきい値は既定 20%", USAGE_THRESHOLD === 20, true);
  t("しきい値は呼び出し側で変えられる", collectUsageAlerts(snap(60, 10), state, true, NOW, 50).length === 1, true);
}

{
  const state = emptyUsageAlertState();
  const old = snap(99, 99, NOW + 60_000, NOW - USAGE_STALE_MS - 1);
  t("古い記録では鳴らない", collectUsageAlerts(old, state, true, NOW).length === 0, true);
  t("古い記録は記憶も残さない", state.fiveHour === null && state.sevenDay === null, true);
  t("新しくなれば鳴る", collectUsageAlerts(snap(99, 99), state, true, NOW).length === 2, true);
}

{
  const state = emptyUsageAlertState();
  t("期限が過ぎたウィンドウでは鳴らない", collectUsageAlerts(snap(99, null, NOW - 1), state, true, NOW).length === 0, true);
  const after = collectUsageAlerts(snap(99, null, NOW + 60_000), state, true, NOW);
  t("次の記録が来たら鳴る", after.length === 1 && after[0]?.kind === "fiveHour", true);
}

console.log(`\n  ${ng === 0 ? "PASS" : "FAIL"}: ${ok} 件成功 / ${ng} 件失敗（合計）`);
if (ng) process.exitCode = 1;
