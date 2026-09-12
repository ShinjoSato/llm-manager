// 空間の配置とカメラ合わせ。建物が画角から溢れると段が読めないので、寸法の計算を押さえる。
import { cameraFit, columnsFor, glowOf, gridLayout, pulse, terraces, CAPITOL, CAPITOL_HEIGHT, PARENT_HEIGHT, TIER2_TOP, TIER3_TOP } from "../src/three/blueprint.js";

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
t("親は建物の 3 割以上の背丈がある", PARENT_HEIGHT / CAPITOL_HEIGHT > 0.3, true);
t("親の頭はドームより上に出ない", TIER3_TOP + PARENT_HEIGHT < CAPITOL_HEIGHT, true);
// ドームは奥へ下げてある（真上に載せると親の顔が隠れる）
t("ドームは頂上の床の奥半分に載る", CAPITOL.drum.z < 0, true);
t("ドームは親の立ち位置まで張り出さない", CAPITOL.drum.z + CAPITOL.dome.radius < CAPITOL.tier3.depth / 2, true);
// 躯体は奥に寄せてあり、2 段目の手前に子が立てる
t("躯体は 2 段目の手前を空ける", CAPITOL.attic.z + CAPITOL.attic.depth / 2 < CAPITOL.tier2.depth / 2, true);

// ── 建物の並び ──
t("セッションが無ければ何も置かない", gridLayout(0, 6, 9, 5, 2).spots.length, 0);
t("1 棟なら原点に立つ", gridLayout(1, 6, 9, 5, 2).spots, [{ x: 0, y: 0, z: 0 }]);
t("1 棟なら広がりは 0", [gridLayout(1, 6, 9, 5, 2).spanX, gridLayout(1, 6, 9, 5, 2).spanZ], [0, 0]);
t("2 棟は横に並ぶ", gridLayout(2, 6, 9, 5, 2).spots, [{ x: -3, y: 0, z: 0 }, { x: 3, y: 0, z: 0 }]);
t("2 棟の広がりは間隔ぶん", gridLayout(2, 6, 9, 5, 2).spanX, 6);
t("列に収まる数なら 1 行に並べる", gridLayout(5, 6, 9, 5, 2).spanZ, 0);
t("列に収まる数なら段は上がらない", gridLayout(5, 6, 9, 5, 2).spanY, 0);
t("列に収まらない数は奥の行に回す", gridLayout(6, 6, 9, 5, 2).spanZ > 0, true);
t("横長の画面ほど 1 行に多く並べられる", columnsFor(4.9) > columnsFor(1.7), true);
t("縦横比が壊れていても列は 1 以上", columnsFor(0) >= 1, true);

const many = gridLayout(9, 6, 9, 5, 2);
t("9 棟は 2 行以上になる", many.spanZ > 0, true);
t("9 棟すべてに場所がある", many.spots.length, 9);
t("左右の広がりは中心対称", Math.max(...many.spots.map((s) => s.x)) + Math.min(...many.spots.map((s) => s.x)), 0);
t("前後の広がりも中心対称", Math.max(...many.spots.map((s) => s.z)) + Math.min(...many.spots.map((s) => s.z)), 0);

// 奥の行は段 1 つぶん持ち上げる（同じ高さだと手前の棟に隠れる）
t("奥の行は段のぶん高い", many.spots[0]!.y < many.spots[8]!.y, true);
t("同じ行は同じ高さ", many.spots[0]!.y, many.spots[1]!.y);
t("持ち上げ幅は段の高さ × 行数", many.spanY, (many.rows - 1) * 2);
t("奥の行ほど手前から遠い", many.spots[8]!.z < many.spots[0]!.z, true);

// 奥の行は半間ずらす（真後ろだとドームが重なって読めない）
const rows = gridLayout(8, 6, 9, 5, 2);
const front = rows.spots.filter((s) => s.z === Math.max(...rows.spots.map((v) => v.z)));
const back = rows.spots.filter((s) => s.z === Math.min(...rows.spots.map((v) => v.z)));
t("奥の棟は手前の棟の真後ろに来ない", front.every((f) => back.every((b) => Math.abs(f.x - b.x) > 1e-9)), true);
t("ずらしても左右の広がりは中心対称", Math.max(...rows.spots.map((s) => s.x)) + Math.min(...rows.spots.map((s) => s.x)), 0);

// ── 階段 ──
{
  // 1 行 + 奥に 3 レベル、1 レベルを 4 段に刻む
  const steps = terraces(1, 9, 2, 3, 5, 4);
  t("1 行でも奥に段が伸びる", steps.length, 16);
  t("刻んだ段は少しずつ上がる", steps.slice(0, 4).map((s) => s.top), [0.5, 1, 1.5, 2]);
  t("踊り場の高さは行の高さと揃う", steps[3]!.top, 2);
  t("段は手前から奥へ並ぶ", steps.every((s, i) => i === 0 || s.front < steps[i - 1]!.front), true);
  t("段は手前から奥へ伸びる", steps.every((s) => s.front > s.back), true);
  t("底はいちばん奥の段より奥にある", steps[0]!.back < steps[15]!.front, true);
  // 踊り場の踏み幅は刻み段より広い（棟の footprint を載せるため）
  t("踊り場は刻み段より広い", steps[3]!.front - steps[4]!.front > (steps[0]!.front - steps[1]!.front) * 3, true);
}
t("行が増えれば段も増える", terraces(3, 9, 2, 3, 5, 4).length, 24);
t("刻みを増やせば段も増える", terraces(1, 9, 2, 0, 5, 8).length, 8);
t("刻みが 0 でも落ちない", terraces(1, 9, 2, 0, 5, 0).length, 1);
// 2 行目の棟はその行の踊り場の上に建つ
{
  const layout = gridLayout(4, 6, 9, 2, 2);
  const steps = terraces(layout.rows, 9, 2, 3, 5, 4);
  const backRow = layout.spots[2]!;
  const landing = steps.find((s) => s.top === backRow.y)!;
  const beyond = steps[steps.indexOf(landing) + 1]!.front;
  t("奥の行の棟は踊り場の上に立つ", landing.top, 2);
  t("奥の行の棟は踊り場に収まる", backRow.z - 2 > beyond && backRow.z + 2 < landing.front, true);
}

// ── カメラ ──
const layout3 = gridLayout(3, 6, 9, 5, 2);
const fit = cameraFit(layout3, 4.8, 3.4, 6, 3, 34, 0.34);
t("カメラは手前（+z）から見る", fit.position[2] > 0, true);
t("カメラは建物より上にある", fit.position[1] > 6, true);
t("見る先は建物の中ほど", fit.target[1] > 0 && fit.target[1] < 6, true);

const near = cameraFit(gridLayout(1, 6, 9, 5, 2), 4.8, 3.4, 6, 3, 34, 0.34);
const far = cameraFit(gridLayout(12, 6, 9, 5, 2), 4.8, 3.4, 6, 3, 34, 0.34);
t("棟が増えるほどカメラは引く", far.position[2] > near.position[2], true);
// 段で持ち上げるぶん、行が増えると見る先も上がる
t("行が増えると見る先も上がる", far.target[1] > near.target[1], true);

const wide = cameraFit(gridLayout(4, 6, 9, 5, 2), 4.8, 3.4, 6, 5, 34, 0.34);
const narrow = cameraFit(gridLayout(4, 6, 9, 5, 2), 4.8, 3.4, 6, 1, 34, 0.34);
t("横長の画面ほど寄れる", wide.position[2] < narrow.position[2], true);
t("縦横比が壊れていても落ちない", Number.isFinite(cameraFit(gridLayout(4, 6, 9, 5, 2), 4.8, 3.4, 6, 0, 34, 0.34).position[2]), true);
t("棟が無くても落ちない", Number.isFinite(cameraFit(gridLayout(0, 6, 9, 5, 2), 4.8, 3.4, 6, 3, 34, 0.34).position[2]), true);

// 1600×340 に 2 棟のとき、親が画面の高さの 1/6 以上を占める（顔が判別できる下限）
{
  const aspect = 1600 / 340;
  const two = gridLayout(2, CAPITOL.footprintX + 2, CAPITOL.footprintZ + 3.6, columnsFor(aspect), 1.7);
  const cam = cameraFit(two, CAPITOL.footprintX, CAPITOL.footprintZ, CAPITOL_HEIGHT, aspect, 34, 0.42);
  const dist = Math.hypot(cam.position[1] - cam.target[1], cam.position[2]);
  const visible = 2 * dist * Math.tan((34 * Math.PI) / 180 / 2);
  t("2 棟なら親は画面の 1/6 以上を占める", (PARENT_HEIGHT * Math.cos(0.42)) / visible > 1 / 6, true);
}

// ── 光り方 ──
t("稼働中はキャラと同じ緑で光る", glowOf("working"), "#34d399");
t("権限待ちは琥珀で光る", glowOf("permission"), "#fbbf24");
t("待機は鈍い色", glowOf("idle"), "#64748b");
t("待機は脈打たない", pulse("idle", 0), pulse("idle", 1.3));
t("終了は待機よりさらに暗い", pulse("stopped", 0) < pulse("idle", 0), true);
t("稼働中は時間で明るさが変わる", pulse("working", 0) !== pulse("working", 0.7), true);
t("要対応は待機より明るい", pulse("permission", 0) > pulse("idle", 0), true);
t("明るさが負にならない", [0, 0.3, 1, 2.5, 7].every((x) => pulse("error", x) > 0), true);

// 端数の行も中央に揃う（左詰めだと最後の行だけ偏る）
{
  const { spots } = gridLayout(6, 6, 6, 5, 2);
  const back = spots.slice(5).map((s) => s.x);
  t("端数の行は中央に 1 棟", back.length, 1);
  // 奇数行は半間ずらすので、全体の中心からのずれが半間ぶんに収まる
  t("端数の行が左に寄りすぎない", Math.abs(back[0]!) <= 3 + 1e-9, true);
}
{
  const { spots } = gridLayout(4, 6, 6, 2, 2);
  const front = spots.slice(0, 2).map((s) => s.x);
  const back = spots.slice(2).map((s) => s.x);
  t("行が埋まっていれば従来どおり", front.length === 2 && back.length === 2, true);
}

console.log(`\n  ${ng === 0 ? "PASS" : "FAIL"}: ${ok} 件成功 / ${ng} 件失敗`);
if (ng) process.exitCode = 1;
