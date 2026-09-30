// 埋め込み表示の URL 指定。mac アプリが組み立てる URL をそのまま読めることと、任意の CSS を通さないことを押さえる。
import { isEmbedUrl, parseEmbedParams, stageScale } from "../src/embed/params.js";

let ok = 0;
let ng = 0;

function t(name: string, got: unknown, want: unknown): void {
  const pass = JSON.stringify(got) === JSON.stringify(want);
  pass ? ok++ : ng++;
  console.log(`  ${pass ? "OK  " : "NG  "}${name.padEnd(50)}${pass ? "" : `期待 ${JSON.stringify(want)} / 実際 ${JSON.stringify(got)}`}`);
}

t("embed=stage なら埋め込み", isEmbedUrl("?embed=stage&session=a"), true);
t("それ以外は通常画面", isEmbedUrl("?embed=other"), false);
t("クエリ無しは通常画面", isEmbedUrl(""), false);

t("既定は 2d・透過", parseEmbedParams("?embed=stage&session=abc"), {
  sessionId: "abc",
  mode: "2d",
  background: "transparent",
});
t("mode=3d", parseEmbedParams("?embed=stage&session=abc&mode=3d")?.mode, "3d");
t("知らない mode は 2d", parseEmbedParams("?embed=stage&session=abc&mode=4d")?.mode, "2d");
t("# 付きの色", parseEmbedParams("?embed=stage&session=a&bg=%23101826")?.background, "#101826");
t("# 無しの色", parseEmbedParams("?embed=stage&session=a&bg=fff")?.background, "#fff");
t("色以外の CSS は通さない", parseEmbedParams("?embed=stage&session=a&bg=red;x:url(y)")?.background, "transparent");
t("session 無しは null", parseEmbedParams("?embed=stage"), null);

t("枠に収まる倍率（狭い方に合わせる）", stageScale({ width: 100, height: 50 }, { width: 300, height: 100 }), 2);
t("縮小もする", stageScale({ width: 200, height: 100 }, { width: 100, height: 100 }), 0.5);
t("拡大は上限まで", stageScale({ width: 10, height: 10 }, { width: 1000, height: 1000 }), 4);
t("寸法 0 なら等倍", stageScale({ width: 0, height: 0 }, { width: 100, height: 100 }), 1);

console.log(`embed: ${ok} OK / ${ng} NG`);
if (ng > 0) process.exit(1);
