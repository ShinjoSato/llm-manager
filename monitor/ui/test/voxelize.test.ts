// ドット絵 → 立方体の変換。2D 表示と同じ絵が出ることが前提なので、座標と色の対応を押さえる。
import { voxelize } from "../src/pixel/voxelize.js";
import { fitScale, projectedSize } from "../src/three/fit.js";
import { AGENT_STAND, KID_STAND } from "../src/pixel/sprites.js";

let ok = 0;
let ng = 0;

function t(name: string, got: unknown, want: unknown): void {
  const pass = JSON.stringify(got) === JSON.stringify(want);
  pass ? ok++ : ng++;
  console.log(`  ${pass ? "OK  " : "NG  "}${name.padEnd(50)}${pass ? "" : `期待 ${JSON.stringify(want)} / 実際 ${JSON.stringify(got)}`}`);
}

const PAL = { A: "#f00", B: "#0f0" };

/** 三角関数の誤差を落として比較する。 */
function round<T extends Record<string, number>>(v: T): T {
  return Object.fromEntries(Object.entries(v).map(([k, n]) => [k, Math.round(n * 1e6) / 1e6])) as T;
}

// 3x2 の小さな絵で座標の取り方を確かめる
const SMALL = ["A.B", ".A."] as const;
const small = voxelize(SMALL, PAL);

t("透明マスは立方体にならない", small.length, 3);
t("左右は中央寄せ（幅 3 なら -1, 0, 1）", small.map((v) => v.x).sort(), [-1, 0, 1]);
t("上下は下端が 0（高さ 2 なら 1 が上段）", small.map((v) => v.y), [1, 1, 0]);
t("色がパレットから引かれる", small.map((v) => v.color), ["#f00", "#0f0", "#f00"]);

// パレットに無い文字は落とす（2D 側と同じ扱い）
t("パレット外の文字は落ちる", voxelize(["AZB"], PAL).length, 2);
t("空のスプライトでも落ちない", voxelize([], PAL).length, 0);
t("空行だけでも落ちない", voxelize(["", ""], PAL).length, 0);

// 実際のキャラで 2D と同じマス数になる
const stand = voxelize(AGENT_STAND, {
  S: "#f6d3ab", K: "#0a0e14", G: "#34d399", B: "#10b981", D: "#0f766e",
});
t("親キャラの立方体は 98 個（2D の非透明マスと一致）", stand.length, 98);

const kid = voxelize(KID_STAND, {
  S: "#f6d3ab", K: "#0a0e14", C: "#60a5fa", E: "#1d4ed8", F: "#1d4ed8",
});
t("子キャラの立方体は 82 個", kid.length, 82);

// 枠の中心（3D 側が原点に寄せる点）に対して、2D と同じ位置に並ぶこと
t("枠に余白がある絵でも下端は 0 のまま", voxelize(["...", "A.B"], PAL).map((v) => v.y), [0, 0]);
t("枠の余白ぶん中身は中心より下にある", Math.max(...voxelize(["...", "A.B"], PAL).map((v) => v.y)) < (2 - 1) / 2, true);

// ── 回転させた立体を枠に収める倍率 ──
t("回さなければ見かけの大きさは元のまま", projectedSize(4, 6, 2, 0, 0), { width: 4, height: 6 });
// 90 度回すと奥行きと幅が入れ替わる
t("90 度回すと幅は奥行きになる", round(projectedSize(4, 6, 2, 0, Math.PI / 2)), { width: 2, height: 6 });
// 斜めに回すと必ず元より広がる（枠に収める必要が出る）
const p = projectedSize(8, 15, 3, 0.16, 0.44);
t("斜めに回すと幅は元より広がる", p.width > 8, true);
t("斜めに回すと高さも元より広がる", p.height > 15, true);

t("収まらない時は縮める", fitScale({ width: 12, height: 15 }, p) < 1, true);
t("縮めた後は枠に収まる", p.width * fitScale({ width: 12, height: 15 }, p) <= 12 + 1e-9, true);
t("余裕があっても 1 倍を超えない", fitScale({ width: 100, height: 100 }, p), 1);
t("見かけの大きさが 0 でも落ちない", fitScale({ width: 10, height: 10 }, { width: 0, height: 0 }), 1);

console.log(`\n  ${ng === 0 ? "PASS" : "FAIL"}: ${ok} 件成功 / ${ng} 件失敗`);
if (ng) process.exitCode = 1;
