// 空間の配置とカメラ合わせ。建物が画角から溢れると段が読めないので、寸法の計算を押さえる。
import { cameraFit, columnsFor, glowOf, gridLayout, pulse, CAPITOL, CAPITOL_HEIGHT, TIER2_TOP, TIER3_TOP } from "../src/three/blueprint.js";

let ok = 0;
let ng = 0;

function t(name: string, got: unknown, want: unknown): void {
  const pass = JSON.stringify(got) === JSON.stringify(want);
  pass ? ok++ : ng++;
  console.log(`  ${pass ? "OK  " : "NG  "}${name.padEnd(50)}${pass ? "" : `期待 ${JSON.stringify(want)} / 実際 ${JSON.stringify(got)}`}`);
}

// ── 段の高さ ──
t("2 段目は基壇と列柱の上にある", TIER2_TOP > CAPITOL.colonnade.height, true);
t("頂上は 2 段目より高い", TIER3_TOP > TIER2_TOP, true);
t("全高はドームのぶん頂上より高い", CAPITOL_HEIGHT > TIER3_TOP + CAPITOL.dome.radius, true);

// ── 建物の並び ──
t("セッションが無ければ何も置かない", gridLayout(0, 6, 9, 5).spots.length, 0);
t("1 棟なら原点に立つ", gridLayout(1, 6, 9, 5).spots, [{ x: 0, z: 0 }]);
t("1 棟なら広がりは 0", [gridLayout(1, 6, 9, 5).spanX, gridLayout(1, 6, 9, 5).spanZ], [0, 0]);
t("2 棟は横に並ぶ", gridLayout(2, 6, 9, 5).spots, [{ x: -3, z: 0 }, { x: 3, z: 0 }]);
t("2 棟の広がりは間隔ぶん", gridLayout(2, 6, 9, 5).spanX, 6);
t("列に収まる数なら 1 行に並べる", gridLayout(5, 6, 9, 5).spanZ, 0);
t("列に収まらない数は奥の行に回す", gridLayout(6, 6, 9, 5).spanZ > 0, true);
t("横長の画面ほど 1 行に多く並べられる", columnsFor(4.9) > columnsFor(1.7), true);
t("縦横比が壊れていても列は 1 以上", columnsFor(0) >= 1, true);

const many = gridLayout(9, 6, 9, 5);
t("9 棟は 2 行以上になる", many.spanZ > 0, true);
t("9 棟すべてに場所がある", many.spots.length, 9);
t("左右の広がりは中心対称", Math.max(...many.spots.map((s) => s.x)) + Math.min(...many.spots.map((s) => s.x)), 0);
t("前後の広がりも中心対称", Math.max(...many.spots.map((s) => s.z)) + Math.min(...many.spots.map((s) => s.z)), 0);

// 奥の行は半間ずらす（真後ろだと手前の棟に隠れる）
const rows = gridLayout(8, 6, 9, 5);
const front = rows.spots.filter((s) => s.z === Math.min(...rows.spots.map((v) => v.z)));
const back = rows.spots.filter((s) => s.z === Math.max(...rows.spots.map((v) => v.z)));
t("奥の棟は手前の棟の真後ろに来ない", front.every((f) => back.every((b) => Math.abs(f.x - b.x) > 1e-9)), true);
t("ずらしても左右の広がりは中心対称", Math.max(...rows.spots.map((s) => s.x)) + Math.min(...rows.spots.map((s) => s.x)), 0);

// ── カメラ ──
const fit = cameraFit(gridLayout(3, 6, 9, 5), 4.8, 6, 3, 34, 0.34);
t("カメラは手前（+z）から見る", fit.position[2] > 0, true);
t("カメラは建物より上にある", fit.position[1] > 6, true);
t("見る先は建物の中ほど", fit.target, [0, 6 * 0.42, 0]);

const near = cameraFit(gridLayout(1, 6, 9, 5), 4.8, 6, 3, 34, 0.34);
const far = cameraFit(gridLayout(12, 6, 9, 5), 4.8, 6, 3, 34, 0.34);
t("棟が増えるほどカメラは引く", far.position[2] > near.position[2], true);

const wide = cameraFit(gridLayout(4, 6, 9, 5), 4.8, 6, 5, 34, 0.34);
const narrow = cameraFit(gridLayout(4, 6, 9, 5), 4.8, 6, 1, 34, 0.34);
t("横長の画面ほど寄れる", wide.position[2] < narrow.position[2], true);
t("縦横比が壊れていても落ちない", Number.isFinite(cameraFit(gridLayout(4, 6, 9, 5), 4.8, 6, 0, 34, 0.34).position[2]), true);

// ── 光り方 ──
t("稼働中はキャラと同じ緑で光る", glowOf("working"), "#34d399");
t("権限待ちは琥珀で光る", glowOf("permission"), "#fbbf24");
t("待機は鈍い色", glowOf("idle"), "#64748b");
t("待機は脈打たない", pulse("idle", 0), pulse("idle", 1.3));
t("終了は待機よりさらに暗い", pulse("stopped", 0) < pulse("idle", 0), true);
t("稼働中は時間で明るさが変わる", pulse("working", 0) !== pulse("working", 0.7), true);
t("要対応は待機より明るい", pulse("permission", 0) > pulse("idle", 0), true);
t("明るさが負にならない", [0, 0.3, 1, 2.5, 7].every((x) => pulse("error", x) > 0), true);

console.log(`\n  ${ng === 0 ? "PASS" : "FAIL"}: ${ok} 件成功 / ${ng} 件失敗`);
if (ng) process.exitCode = 1;
