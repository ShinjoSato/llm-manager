// 返答待ちの扱い。何を聞かれているかの一行と、待ち始めの時刻の引き継ぎを押さえる。
import { needsAttention, nextAttentionSince, permissionDetail } from "../src/attention.js";

let ok = 0;
let ng = 0;

function t(name: string, got: unknown, want: unknown): void {
  const pass = JSON.stringify(got) === JSON.stringify(want);
  pass ? ok++ : ng++;
  console.log(
    `  ${pass ? "OK  " : "NG  "}${name.padEnd(52)}${pass ? "" : `期待 ${JSON.stringify(want)} / 実際 ${JSON.stringify(got)}`}`,
  );
}

// ── 要対応の判定 ──
t("権限待ちは要対応", needsAttention("permission"), true);
t("入力待ちは要対応", needsAttention("waiting"), true);
t("エラーは要対応", needsAttention("error"), true);
t("稼働中は要対応ではない", needsAttention("working"), false);
t("待機は要対応ではない", needsAttention("idle"), false);
t("状態が無ければ要対応ではない", needsAttention(null), false);

// ── 何を聞かれているか ──
t("同じツールなら説明を添える", permissionDetail("Bash", null, "Bash", "テストを実行"), "Bash: テストを実行");
t("ツール名だけでも出す", permissionDetail("Bash", null, "Bash", null), "Bash");
t("別のツールの説明は添えない", permissionDetail("Edit", null, "Bash", "テストを実行"), "Edit");
t(
  "ツール名が無ければ通知文に説明を添える",
  permissionDetail(null, "Claude needs your permission", "Bash", "テストを実行"),
  "Claude needs your permission: テストを実行",
);
t(
  "通知文しか無ければ通知文",
  permissionDetail(null, "Claude needs your permission", null, null),
  "Claude needs your permission",
);
t("ツール名を通知文より優先する", permissionDetail("Write", "Claude needs your permission", null, null), "Write");
t("説明しか無ければ説明", permissionDetail(null, null, "Bash", "テストを実行"), "テストを実行");
t("何も無ければ null", permissionDetail(null, null, null, null), null);
t("空文字のツール名は無いものとして扱う", permissionDetail("", "通知文", null, null), "通知文");

// ── 待ち始め ──
t("要対応になった時刻を持つ", nextAttentionSince("working", null, "permission", 1000), 1000);
t("最初の状態が要対応でも時刻を持つ", nextAttentionSince(null, null, "waiting", 1000), 1000);
t("要対応どうしの移り変わりは引き継ぐ", nextAttentionSince("permission", 1000, "waiting", 5000), 1000);
t("同じ要対応が届き直しても引き継ぐ", nextAttentionSince("permission", 1000, "permission", 5000), 1000);
t("要対応でなくなれば消える", nextAttentionSince("permission", 1000, "working", 5000), null);
t("待機に移れば消える", nextAttentionSince("waiting", 1000, "idle", 5000), null);
t("時刻が欠けていれば今から数え直す", nextAttentionSince("permission", null, "permission", 5000), 5000);
t("要対応から離れて戻れば数え直す", nextAttentionSince("working", 1000, "error", 9000), 9000);

console.log(`\nattention: ${ok} OK / ${ng} NG`);
if (ng > 0) process.exit(1);
