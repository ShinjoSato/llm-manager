// 空間の寸法と配置。段が読めなくなったりキャラが画角から溢れると意味を失うので、計算を押さえる。
import { cameraFit, clearSpacingZ, columnsFor, glowOf, gridLayout, hop, phaseOf, pulse, steps, FOOTPRINT_X, FOOTPRINT_Z, HOP, ITEM_HEIGHT, ITEM_LIFT, ITEM_X, ITEM_Z, KID_GAP, KID_HEIGHT, KID_Y, KID_Z, PARENT_HEIGHT, SKYLINE, STEPS, TOP_Y, VOXEL, ZIGGURAT } from "../src/three/blueprint.js";
import { AGENT_STAND, ITEM_BOOK, ITEM_CANVAS, ITEM_HAMMER, ITEM_NOTE, ITEM_QUESTION, ITEM_SCOPE, ITEM_SCROLL, ITEM_TERMINAL, KID_STAND } from "../src/pixel/sprites.js";
import { itemFor } from "../src/pixel/kit.js";
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

// ── 持ち物 ──
const ITEMS = [ITEM_BOOK, ITEM_CANVAS, ITEM_HAMMER, ITEM_NOTE, ITEM_QUESTION, ITEM_SCOPE, ITEM_SCROLL, ITEM_TERMINAL];
t("持ち物の絵は高さが揃っている", ITEMS.every((sprite) => sprite.length === ITEM_NOTE.length), true);
t("持ち物は親と同じ倍率で描く", Math.abs(ITEM_HEIGHT / ITEM_NOTE.length - VOXEL) < 1e-9, true);
t("持ち物は親より小さい", ITEM_HEIGHT < PARENT_HEIGHT, true);
t("持ち物は親の半分より大きい", ITEM_HEIGHT > PARENT_HEIGHT / 2, true);
{
  // 親の胴と持ち物が画面で重なると、何を持っているのかも誰なのかも読めない。
  const half = artWidth(AGENT_STAND, PARENT_HEIGHT) / 2;
  const itemHalf = Math.max(...ITEMS.map((sprite) => artWidth(sprite, ITEM_HEIGHT))) / 2;
  t("持ち物は親に重ならない", ITEM_X - itemHalf > half, true);
  t("持ち物は離れすぎない", ITEM_X - itemHalf - half < VOXEL * 2, true);
  t("持ち物は最上段からはみ出さない", ITEM_X + itemHalf < STEPS[STEPS.length - 1]!.width / 2, true);
  t("持ち物は手前に出す", ITEM_Z > 0, true);
  t("持ち物は最上段の踏み面に収まる", ITEM_Z < STEPS[STEPS.length - 1]!.depth / 2, true);
}
t("持ち物は足元から浮いている", ITEM_LIFT > 0, true);
t("持ち物は親の頭より下にある", ITEM_LIFT + ITEM_HEIGHT < PARENT_HEIGHT, true);
t("稼働中のツールには持ち物がある", itemFor("Bash") !== null, true);
t("スキル実行中は巻物を持つ", itemFor("Bash", "developer-plugin:dev-done")!.sprite, ITEM_SCROLL);
t("ツールが無ければ持ち物も無い", itemFor(null), null);
t("子が出るツールは持ち物にしない", itemFor("Agent"), null);

// ── 跳ね ──
t("跳ねは 2 コマだけ", [0, 0.2, 0.4, 0.6, 0.8, 1, 1.3].every((x) => [0, HOP.rise].includes(hop(x, HOP.period, HOP.rise))), true);
t("周期の前半は地に足が付く", hop(0.1, 1, 1), 0);
t("周期の後半は浮く", hop(0.7, 1, 1), 1);
t("周期ごとに繰り返す", [0.2, 0.7, 1.4].every((x) => hop(x, 1.1, 1) === hop(x + 1.1, 1.1, 1)), true);
{
  // 浮いている時間と付いている時間は半々。偏ると跳ねではなく点滅に見える。
  const n = 220;
  const up = Array.from({ length: n }, (_, i) => hop((i * HOP.period) / n, HOP.period, 1)).filter(Boolean).length;
  t("浮く時間と付く時間は半々", up, n / 2);
}
t("時刻が負でも落ちない", hop(-0.3, 1, 1), 1);
t("周期が 0 なら動かない", hop(0.5, 0, 1), 0);
t("高さが 0 なら動かない", hop(0.5, 1, 0), 0);
t("時刻が壊れていても動かない", hop(NaN, 1, 1), 0);
t("跳ねは絵の 1 マスぶん", HOP.rise, 1);
t("子は親の半分の速さで跳ねる", HOP.kidPeriod, HOP.period * 2);
t("子をずらす量は周期の内側", HOP.kidStagger > 0 && HOP.kidStagger < 1, true);
{
  // 4 体が同時に跳ねないこと（1 枚の板に見えてしまう）。
  const at = (i: number, x: number) => hop(x + i * HOP.kidStagger * HOP.kidPeriod, HOP.kidPeriod, 1);
  const sample = [0, 0.4, 0.9, 1.5, 2.1];
  t("子は同時に跳ばない", sample.some((x) => new Set([0, 1, 2, 3].map((i) => at(i, x))).size > 1), true);
}

// ── 位相の種 ──
t("同じセッションは同じ位相", phaseOf("abc-123"), phaseOf("abc-123"));
t("違うセッションは位相がずれる", phaseOf("abc-123") !== phaseOf("abc-124"), true);
{
  // 1 文字違いの id が隣り合って建つので、わずかな差でも大きく離れないと揃って跳ねる。
  const ids = ["s0", "s1", "s2", "s3", "s4", "s5"];
  const gaps = ids.slice(1).map((id, i) => Math.abs(phaseOf(id) - phaseOf(ids[i]!)));
  t("1 文字違いでも位相は離れる", Math.min(...gaps) > 0.1, true);
}
t("位相は 0〜1 に収まる", ["", "a", "session-9", "0123456789abcdef"].every((id) => phaseOf(id) >= 0 && phaseOf(id) < 1), true);
{
  // 20 基並べても同じ位相に固まらない（揃って明滅すると機械仕掛けに見える）。
  const ids = Array.from({ length: 20 }, (_, i) => `sess-${i}`);
  t("多数の基でも位相が散る", new Set(ids.map(phaseOf)).size > 15, true);
}

// 端数の行が真後ろに重ならない（中央寄せで偶奇が揃うと半間ずらしが打ち消される）
for (const [count, cols] of [[3, 2], [5, 2], [7, 3], [9, 4]] as const) {
  const { spots } = gridLayout(count, 6, 8, cols);
  const rows = new Map<number, number[]>();
  for (const spot of spots) {
    const key = Math.round(spot.z * 1000);
    rows.set(key, [...(rows.get(key) ?? []), spot.x]);
  }
  const list = [...rows.values()];
  let overlap = false;
  for (let a = 0; a < list.length - 1; a++)
    for (const x of list[a]!)
      for (const y of list[a + 1]!) if (Math.abs(x - y) < 1e-6) overlap = true;
  t(`${count} 基 ${cols} 列で真後ろに重ならない`, overlap, false);
}

// 1 行しか無ければ行間は使わない（隠れない間隔が無限大になることがある）
t("1 行なら z は 0", gridLayout(2, 6, Infinity, 4).spots.every((s) => s.z === 0), true);
t("1 行でも NaN にならない", gridLayout(2, 6, Infinity, 4).spots.every((s) => Number.isFinite(s.x)), true);

console.log(`\n  ${ng === 0 ? "PASS" : "FAIL"}: ${ok} 件成功 / ${ng} 件失敗`);
if (ng) process.exitCode = 1;
