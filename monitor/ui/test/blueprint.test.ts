// 空間の寸法と配置。段が読めなくなったりキャラが画角から溢れると意味を失うので、計算を押さえる。
import { cameraFit, clearSpacingZ, columnsFor, glowOf, gridLayout, pulse, steps, FOOTPRINT_X, FOOTPRINT_Z, KID_GAP, KID_HEIGHT, KID_Y, KID_Z, PARENT_HEIGHT, SKYLINE, STEPS, TOP_Y, ZIGGURAT } from "../src/three/blueprint.js";
import { AGENT_STAND, KID_STAND } from "../src/pixel/sprites.js";
import { MAX_KIDS } from "../src/pixel/AgentStage.js";

let ok = 0;
let ng = 0;

function t(name: string, got: unknown, want: unknown): void {
  const pass = JSON.stringify(got) === JSON.stringify(want);
  pass ? ok++ : ng++;
  console.log(`  ${pass ? "OK  " : "NG  "}${name.padEnd(50)}${pass ? "" : `期待 ${JSON.stringify(want)} / 実際 ${JSON.stringify(got)}`}`);
}

/** 絵の中で実際に色が置かれている幅（世界の単位）。余白の列は立たないので寸法に数えない。 */
function artWidth(sprite: readonly string[], height: number): number {
  let lo = Infinity;
  let hi = -Infinity;
  for (const row of sprite) {
    for (let i = 0; i < row.length; i++) {
      if (row[i] === ".") continue;
      lo = Math.min(lo, i);
      hi = Math.max(hi, i);
    }
  }
  return (hi - lo + 1) * (height / sprite.length);
}

// ── 段の積み方 ──
t("段は指定した数だけ積む", STEPS.length, ZIGGURAT.levels);
t("上の段ほど狭い", STEPS.every((s, i) => i === 0 || s.width < STEPS[i - 1]!.width), true);
t("上の段ほど浅い", STEPS.every((s, i) => i === 0 || s.depth < STEPS[i - 1]!.depth), true);
t("段は隙間なく積み上がる", STEPS.every((s, i) => i === 0 || Math.abs(s.base - STEPS[i - 1]!.top) < 1e-9), true);
t("最下段は地面から始まる", STEPS[0]!.base, 0);
t("1 段の高さは揃っている", STEPS.every((s) => Math.abs(s.top - s.base - ZIGGURAT.rise) < 1e-9), true);
t("最上段の上面が全高", Math.abs(TOP_Y - ZIGGURAT.levels * ZIGGURAT.rise) < 1e-9, true);
t("子の段は最上段の 1 つ下", Math.abs(KID_Y - (TOP_Y - ZIGGURAT.rise)) < 1e-9, true);
t("最下段が footprint", [STEPS[0]!.width, STEPS[0]!.depth], [FOOTPRINT_X, FOOTPRINT_Z]);
t("縁取り板は 1 段の高さに収まる", ZIGGURAT.cap < ZIGGURAT.rise, true);
t("段が 1 つでも落ちない", steps({ ...ZIGGURAT, levels: 1 }).length, 1);
t("段を増やすと裾が広がる", steps({ ...ZIGGURAT, levels: 7 })[0]!.width > FOOTPRINT_X, true);

// ── キャラの居場所 ──
t("親は最上段に収まる", artWidth(AGENT_STAND, PARENT_HEIGHT) < STEPS[STEPS.length - 1]!.width, true);
{
  // 子は最大 4 体が横 1 列。はみ出すと段から落ちて浮いて見える。
  const span = (MAX_KIDS - 1) * KID_GAP + artWidth(KID_STAND, KID_HEIGHT);
  t("子は 4 体まで 1 つ下の段に並ぶ", span < STEPS[STEPS.length - 2]!.width, true);
  t("子どうしは重ならない", KID_GAP > artWidth(KID_STAND, KID_HEIGHT), true);
}
{
  // 上の段の前端から下の段の前端までが、子の立てる踏み面。
  const front = STEPS[STEPS.length - 2]!.depth / 2;
  const back = STEPS[STEPS.length - 1]!.depth / 2;
  const thick = (3 * KID_HEIGHT) / KID_STAND.length;
  t("子は上の段より手前に立つ", KID_Z > back, true);
  t("子は踏み面から落ちない", KID_Z - thick / 2 > back && KID_Z + thick / 2 < front, true);
}
t("親は全体の高さの 4 割以上を占める", PARENT_HEIGHT / SKYLINE > 0.4, true);
t("いちばん高い点は親の頭", Math.abs(SKYLINE - (TOP_Y + PARENT_HEIGHT)) < 1e-9, true);

// ── 基の並び ──
t("セッションが無ければ何も置かない", gridLayout(0, 7, 8, 5).spots.length, 0);
t("1 基なら原点に立つ", gridLayout(1, 7, 8, 5).spots, [{ x: 0, z: 0 }]);
t("1 基なら広がりは 0", [gridLayout(1, 7, 8, 5).spanX, gridLayout(1, 7, 8, 5).spanZ], [0, 0]);
t("2 基は横に並ぶ", gridLayout(2, 6, 8, 5).spots, [{ x: -3, z: 0 }, { x: 3, z: 0 }]);
t("2 基の広がりは間隔ぶん", gridLayout(2, 6, 8, 5).spanX, 6);
t("列に収まる数なら 1 行に並べる", gridLayout(5, 6, 8, 5).spanZ, 0);
t("列に収まらない数は奥の行に回す", gridLayout(6, 6, 8, 5).spanZ > 0, true);
t("地面は平らなので段差は付けない", gridLayout(9, 6, 8, 5).spots.every((s) => !("y" in s)), true);
t("横長の画面ほど 1 行に多く並べられる", columnsFor(4.9) > columnsFor(1.7), true);
t("縦横比が壊れていても列は 1 以上", columnsFor(0) >= 1, true);

const many = gridLayout(9, 6, 8, 5);
t("9 基は 2 行以上になる", many.spanZ > 0, true);
t("9 基すべてに場所がある", many.spots.length, 9);
t("左右の広がりは中心対称", Math.max(...many.spots.map((s) => s.x)) + Math.min(...many.spots.map((s) => s.x)), 0);
t("前後の広がりも中心対称", Math.max(...many.spots.map((s) => s.z)) + Math.min(...many.spots.map((s) => s.z)), 0);
t("奥の行ほど手前から遠い", many.spots[8]!.z < many.spots[0]!.z, true);
t("同じ行は同じ奥行き", many.spots[0]!.z, many.spots[1]!.z);

// 奥の行は半間ずらす（真後ろだと稜線が重なって段数が読めない）
const rows = gridLayout(8, 6, 8, 5);
const front = rows.spots.filter((s) => s.z === Math.max(...rows.spots.map((v) => v.z)));
const back = rows.spots.filter((s) => s.z === Math.min(...rows.spots.map((v) => v.z)));
t("奥の基は手前の基の真後ろに来ない", front.every((f) => back.every((b) => Math.abs(f.x - b.x) > 1e-9)), true);
t("ずらしても左右の広がりは中心対称", Math.max(...rows.spots.map((s) => s.x)) + Math.min(...rows.spots.map((s) => s.x)), 0);

// 端数の行も中央に揃う（左詰めだと最後の行だけ偏る）
{
  const { spots } = gridLayout(6, 6, 6, 5);
  const last = spots.slice(5).map((s) => s.x);
  t("端数の行は中央に 1 基", last.length, 1);
  t("端数の行が左に寄りすぎない", Math.abs(last[0]!) <= 3 + 1e-9, true);
}

// ── 行の間隔 ──
{
  const gap = clearSpacingZ(KID_Y + KID_HEIGHT, FOOTPRINT_Z, 0.42);
  t("行間は基の奥行きより広い", gap > FOOTPRINT_Z, true);
  // 手前の子の頭より、奥の基の前端の足元が画面で上に来る（= 隠れない）
  const cos = Math.cos(0.42);
  const sin = Math.sin(0.42);
  t("奥の行の足元は手前の子の頭より上に出る", (gap - FOOTPRINT_Z / 2) * sin >= (KID_Y + KID_HEIGHT) * cos - 1e-9, true);
  t("見下ろす角度が浅いほど行間は広く要る", clearSpacingZ(2.4, 4, 0.3) > clearSpacingZ(2.4, 4, 0.6), true);
  t("真横から見ると隠れないようにはできない", clearSpacingZ(2.4, 4, 0), Infinity);
}

// ── カメラ ──
const layout3 = gridLayout(3, 7, 8, 5);
const fit = cameraFit(layout3, FOOTPRINT_X, FOOTPRINT_Z, SKYLINE, 3, 34, 0.42);
t("カメラは手前（+z）から見る", fit.position[2] > 0, true);
t("カメラは基より上にある", fit.position[1] > SKYLINE, true);
t("見る先は基の中ほど", fit.target[1] > 0 && fit.target[1] < SKYLINE, true);

const near = cameraFit(gridLayout(1, 7, 8, 5), FOOTPRINT_X, FOOTPRINT_Z, SKYLINE, 3, 34, 0.42);
const far = cameraFit(gridLayout(12, 7, 8, 5), FOOTPRINT_X, FOOTPRINT_Z, SKYLINE, 3, 34, 0.42);
t("基が増えるほどカメラは引く", far.position[2] > near.position[2], true);
t("地面が平らなので見る先の高さは行数で変わらない", Math.abs(far.target[1] - near.target[1]) < 1e-9, true);

const wide = cameraFit(gridLayout(4, 7, 8, 5), FOOTPRINT_X, FOOTPRINT_Z, SKYLINE, 5, 34, 0.42);
const narrow = cameraFit(gridLayout(4, 7, 8, 5), FOOTPRINT_X, FOOTPRINT_Z, SKYLINE, 1, 34, 0.42);
t("横長の画面ほど寄れる", wide.position[2] < narrow.position[2], true);
t("縦横比が壊れていても落ちない", Number.isFinite(cameraFit(gridLayout(4, 7, 8, 5), FOOTPRINT_X, FOOTPRINT_Z, SKYLINE, 0, 34, 0.42).position[2]), true);
t("基が無くても落ちない", Number.isFinite(cameraFit(gridLayout(0, 7, 8, 5), FOOTPRINT_X, FOOTPRINT_Z, SKYLINE, 3, 34, 0.42).position[2]), true);

/** 親の背丈が画面の高さに占める割合。顔が判別できるかの目安にする。 */
function parentShare(count: number, aspect: number): number {
  const spacingZ = clearSpacingZ(KID_Y + KID_HEIGHT, FOOTPRINT_Z, 0.42);
  const layout = gridLayout(count, FOOTPRINT_X + 1, spacingZ, columnsFor(aspect));
  const cam = cameraFit(layout, FOOTPRINT_X, FOOTPRINT_Z, SKYLINE, aspect, 34, 0.42);
  const dist = Math.hypot(cam.position[1] - cam.target[1], cam.position[2]);
  const visible = 2 * dist * Math.tan((34 * Math.PI) / 180 / 2);
  return (PARENT_HEIGHT * Math.cos(0.42)) / visible;
}

// 1600×340 の帯で、親が画面の高さの 1/6 以上を占める（顔が判別できる下限）
t("2 基なら親は画面の 1/6 以上を占める", parentShare(2, 1600 / 340) > 1 / 6, true);
t("6 基でも親は画面の 1/10 以上を占める", parentShare(6, 1600 / 340) > 1 / 10, true);
t("基が増えるほど親は小さく写る", parentShare(2, 1600 / 340) > parentShare(10, 1600 / 340), true);

// ── 光り方 ──
t("稼働中はキャラと同じ緑で光る", glowOf("working"), "#34d399");
t("権限待ちは琥珀で光る", glowOf("permission"), "#fbbf24");
t("入力待ちは青で光る", glowOf("waiting"), "#60a5fa");
t("エラーは赤で光る", glowOf("error"), "#f87171");
t("待機は鈍い色", glowOf("idle"), "#64748b");
t("待機は脈打たない", pulse("idle", 0), pulse("idle", 1.3));
t("終了は待機よりさらに暗い", pulse("stopped", 0) < pulse("idle", 0), true);
t("稼働中は時間で明るさが変わる", pulse("working", 0) !== pulse("working", 0.7), true);
t("要対応は待機より明るい", pulse("permission", 0) > pulse("idle", 0), true);
t("明るさが負にならない", [0, 0.3, 1, 2.5, 7].every((x) => pulse("error", x) > 0), true);

console.log(`\n  ${ng === 0 ? "PASS" : "FAIL"}: ${ok} 件成功 / ${ng} 件失敗`);
if (ng) process.exitCode = 1;
