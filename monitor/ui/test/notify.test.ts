// 通知の発火判定。鳴らしすぎ・鳴らなすぎのどちらも困るので境界を押さえる。
import { loadSetting, shouldNotify, type NotifySetting } from "../src/useNotify.js";

const BOTH: NotifySetting = { idle: true, attention: true };
const ONLY_ATTENTION: NotifySetting = { idle: false, attention: true };
const ONLY_IDLE: NotifySetting = { idle: true, attention: false };
const OFF: NotifySetting = { idle: false, attention: false };

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
