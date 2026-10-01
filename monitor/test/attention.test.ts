// 返答待ちの扱い。何を聞かれているかの一行と、待ち始めの時刻の引き継ぎを押さえる。
import {
  heldStatus,
  needsAttention,
  nextAttentionSince,
  permissionDetail,
  toolFromMessage,
} from "../src/attention.js";

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
  "ツール名が分からなければ説明を添えない",
  permissionDetail(null, "Claude needs your permission", "Bash", "テストを実行"),
  "Claude needs your permission",
);
t(
  "通知文のツールが同じなら説明を添える",
  permissionDetail(null, "Claude needs your permission to use Bash", "Bash", "テストを実行"),
  "Claude needs your permission to use Bash: テストを実行",
);
t(
  "通知文のツールが違えば説明を添えない",
  permissionDetail(null, "Claude needs your permission to use Edit", "Bash", "テストを実行"),
  "Claude needs your permission to use Edit",
);
t(
  "通知文しか無ければ通知文",
  permissionDetail(null, "Claude needs your permission", null, null),
  "Claude needs your permission",
);
t("ツール名を通知文より優先する", permissionDetail("Write", "Claude needs your permission", null, null), "Write");
t("何を聞かれているか分からなければ説明も出さない", permissionDetail(null, null, "Bash", "テストを実行"), null);
t("通知文からツール名を取る", toolFromMessage("Claude needs your permission to use Bash"), "Bash");
t(
  "MCP のツール名も取る",
  toolFromMessage("Claude needs your permission to use mcp__ai-manager__add_pin"),
  "mcp__ai-manager__add_pin",
);
t("形が違えば取らない", toolFromMessage("Claude needs your permission"), null);
t("通知文が無ければ取らない", toolFromMessage(null), null);
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

// ── 前の待ちが続いているか ──
t("フック以降に動きが無ければ待ちは続く", heldStatus("permission", 1000, 900), "permission");
t("フックと同時刻の活動では解かない", heldStatus("permission", 1000, 1000), "permission");
t("フックより新しい活動があれば答えが出ている", heldStatus("permission", 1000, 2000), null);
t("フック状態が無ければ null", heldStatus(null, 1000, 0), null);

// 権限待ち #1 に答えてツールが動いた後、次の権限待ち #2 がツール行の読み取りより先に届く順。
// フック状態は "permission" のまま残っているが、#2 は #2 の時刻から数える。
{
  let hookStatus: "permission" | null = null;
  let hookAt = 0;
  let since: number | null = null;
  const hook = (now: number, lastActivityAt: number) => {
    since = nextAttentionSince(heldStatus(hookStatus, hookAt, lastActivityAt), since, "permission", now);
    hookStatus = "permission";
    hookAt = now;
  };
  hook(1000, 500); // #1
  hook(3000, 2000); // #1 の tool_result を 2000 に読んだ後で #2
  t("答えた後の次の権限待ちは引き継がない", since, 3000);
  hook(4000, 2000); // 同じ待ちが届き直す
  t("動きが無いまま届き直せば引き継ぐ", since, 3000);
}

console.log(`\nattention: ${ok} OK / ${ng} NG`);
if (ng > 0) process.exit(1);
