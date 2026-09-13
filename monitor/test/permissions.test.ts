// 権限確認の中継。承認が手元以外に漏れると、平文 HTTP 越しに任意のコマンドを許可できてしまう。
import {
  DECIDED_TTL_MS,
  isDecision,
  isLocalActor,
  matchSession,
  MAX_PENDING,
  parseRequest,
  PENDING_MAX_AGE_MS,
  PENDING_TTL_MS,
  pendingKey,
  PermissionRegistry,
} from "../src/permissions.js";

let ok = 0;
let ng = 0;

function t(name: string, got: unknown, want: unknown): void {
  const pass = JSON.stringify(got) === JSON.stringify(want);
  pass ? ok++ : ng++;
  console.log(
    `  ${pass ? "OK  " : "NG  "}${name.padEnd(50)}${pass ? "" : `期待 ${JSON.stringify(want)} / 実際 ${JSON.stringify(got)}`}`,
  );
}

// ── 判断の値 ──
t("allow は判断", isDecision("allow"), true);
t("deny は判断", isDecision("deny"), true);
t("always は判断ではない", isDecision("always"), false);
t("大文字は判断ではない", isDecision("ALLOW"), false);
t("空は判断ではない", isDecision(""), false);
t("文字列以外は判断ではない", isDecision(1), false);

// ── 手元からだけ受け付ける ──
t("127.0.0.1 は手元", isLocalActor("127.0.0.1"), true);
t("::1 も手元", isLocalActor("::1"), true);
t("IPv4 射影のループバックも手元", isLocalActor("::ffff:127.0.0.1"), true);
t("LAN は手元ではない", isLocalActor("192.168.0.11"), false);
t("IPv4 射影の LAN も手元ではない", isLocalActor("::ffff:192.168.0.11"), false);
t("外部アドレスも手元ではない", isLocalActor("203.0.113.9"), false);
t("接続元不明は手元ではない", isLocalActor(undefined), false);

// ── 申請の読み取り ──
const raw = {
  requestId: "abcde",
  toolName: "Bash",
  description: "ls を実行する",
  inputPreview: '{"command":"ls"}',
  pid: 1234,
  cwd: "/Users/me/project",
};
t("そのまま読める", parseRequest(raw), {
  requestId: "abcde",
  toolName: "Bash",
  description: "ls を実行する",
  inputPreview: '{"command":"ls"}',
  pid: 1234,
  cwd: "/Users/me/project",
});
t("説明が無くても読める", parseRequest({ requestId: "abcde", toolName: "Bash" })?.description, "");
t("pid が無ければ null", parseRequest({ requestId: "abcde", toolName: "Bash" })?.pid, null);
t("ツール名が空なら null", parseRequest({ ...raw, toolName: "  " }), null);
t("ID が空なら null", parseRequest({ ...raw, requestId: "" }), null);
t("ID にスラッシュは通さない", parseRequest({ ...raw, requestId: "../x" }), null);
t("ID が長すぎれば null", parseRequest({ ...raw, requestId: "a".repeat(65) }), null);
t("本体が無ければ null", parseRequest(null), null);
t("負の pid は null 扱い", parseRequest({ ...raw, pid: -1 })?.pid, null);
t(
  "長すぎる引数は切る",
  parseRequest({ ...raw, inputPreview: "x".repeat(5000) })?.inputPreview.length,
  4001,
);

// ── 申請元のセッション ──
const SESSIONS = [
  { sessionId: "s1", pid: 1234, cwd: "/a", alive: true },
  { sessionId: "s2", pid: 5678, cwd: "/b", alive: true },
  { sessionId: "s3", pid: 4321, cwd: "/b", alive: true },
  { sessionId: "s4", pid: 9999, cwd: "/c", alive: false },
];
t("PID で引く", matchSession({ pid: 1234 }, SESSIONS), "s1");
t("終了済みは引かない", matchSession({ pid: 9999 }, SESSIONS), null);
t("PID が無ければ引かない", matchSession({ pid: null }, SESSIONS), null);
// cwd で引くと、同じ場所の別セッションに付け替わって「見ていない確認」を許可させてしまう。
t("知らない PID は cwd に落ちない", matchSession({ pid: 1 }, SESSIONS), null);

// ── 保留の鍵 ──
t("鍵は PID と ID の対", pendingKey({ pid: 1234, requestId: "abcde" }), "1234-abcde");
t("PID 不明でも鍵になる", pendingKey({ pid: null, requestId: "abcde" }), "x-abcde");
t(
  "PID が違えば別の鍵",
  pendingKey({ pid: 1, requestId: "abcde" }) === pendingKey({ pid: 2, requestId: "abcde" }),
  false,
);

// ── 保留の出し入れ ──
const input = parseRequest(raw)!;
const reg = new PermissionRegistry();
const added = reg.register(input, { sessionId: "s1", project: "project" }, 1_000);
t("初回は created", added.created, true);
t("預かった内容が出る", reg.list(), [
  {
    key: "1234-abcde",
    requestId: "abcde",
    sessionId: "s1",
    project: "project",
    toolName: "Bash",
    description: "ls を実行する",
    inputPreview: '{"command":"ls"}',
    askedAt: 1_000,
  },
]);
t(
  "取り直しは created ではない",
  reg.register(input, { sessionId: null, project: null }, 2_000).created,
  false,
);
t("取り直しでセッションは消えない", reg.list()[0]?.sessionId, "s1");
t("変化が無ければ changed ではない", reg.register(input, { sessionId: "s1", project: "project" }, 2_000).changed, false);
t("知らない鍵は決められない", reg.decide("1234-zzzzz", "allow"), null);

const waiting = reg.wait("1234-abcde", 50);
t("判断で保留は消える", reg.decide("1234-abcde", "allow")?.toolName, "Bash");
t("待っていた側に判断が返る", await waiting, "allow");
t("決めた後は空", reg.list(), []);
t("知らない鍵を待つと dropped", await reg.wait("1234-abcde", 50), "dropped");

// 判断が出なければ timeout。保留は残したままなので、チャネルが取り直せる。
reg.register(input, { sessionId: "s1", project: "project" }, 3_000);
t("判断が出なければ timeout", await reg.wait("1234-abcde", 10), "timeout");
t("timeout でも保留は残る", reg.size(), 1);

// ── 後から在庫に載ったセッションを拾う ──
const late = new PermissionRegistry();
late.register(input, { sessionId: null, project: "project" }, 1_000);
t("引けなかった初回は sessionId が null", late.list()[0]?.sessionId, null);
const linked = late.register(input, { sessionId: "s1", project: "project" }, 2_000);
t("後から引けたら changed", linked.changed, true);
t("後から引けたら反映される", late.list()[0]?.sessionId, "s1");

// ── 別セッションの同じ ID は別物 ──
const twins = new PermissionRegistry();
const a = { ...input, pid: 1111 };
const b = { ...input, pid: 2222 };
twins.register(a, { sessionId: "sA", project: "A" }, 1_000);
twins.register(b, { sessionId: "sB", project: "B" }, 1_000);
t("同じ ID でも PID が違えば別の保留", twins.size(), 2);
const waitingB = twins.wait(pendingKey(b), 50);
twins.decide(pendingKey(a), "allow");
t("片方を決めても相手は残る", twins.size(), 1);
t("相手の待ち手には判断が配られない", await Promise.race([waitingB, delay("待機中")]), "待機中");
t("残ったのは相手の分", twins.list()[0]?.sessionId, "sB");

// ── 取り直しの谷間で押された判断 ──
const gap = new PermissionRegistry();
gap.register(input, { sessionId: "s1", project: "project" }, 1_000);
t("待ち手が居なくても決められる", gap.decide(pendingKey(input), "deny", 1_000)?.toolName, "Bash");
t("取り置きを取り出せる", gap.takeDecision(pendingKey(input), 1_100), "deny");
t("取り置きは一度きり", gap.takeDecision(pendingKey(input), 1_100), null);
gap.register(input, { sessionId: "s1", project: "project" }, 2_000);
gap.decide(pendingKey(input), "allow", 2_000);
t("古い取り置きは渡さない", gap.takeDecision(pendingKey(input), 2_000 + DECIDED_TTL_MS), null);

// ── 保留の上限 ──
const flood = new PermissionRegistry();
for (let i = 0; i < MAX_PENDING + 5; i++) {
  flood.register({ ...input, requestId: `r${i}` }, { sessionId: null, project: null }, 1_000 + i);
}
t("上限を超えない", flood.size(), MAX_PENDING);
t("捨てるのは古いほうから", flood.list()[0]?.requestId, "r5");

// ── 端末側で先に答えられた分は落とす ──
t("預かる前の活動では落ちない", reg.dropResolved("s1", 3_000).length, 0);
t("別セッションの活動では落ちない", reg.dropResolved("s2", 9_000).length, 0);
const watching = reg.wait(pendingKey(input), 50);
t("預かった後の活動で落ちる", reg.dropResolved("s1", 3_001)[0]?.requestId, "abcde");
t("待っていた側には dropped が返る", await watching, "dropped");
t("落ちた後は空", reg.size(), 0);

// ── 取りに来なくなった分の掃除 ──
const stale = new PermissionRegistry();
stale.register(input, { sessionId: null, project: null }, 10_000);
t("期限内は残る", stale.sweep(10_000 + PENDING_TTL_MS - 1).length, 0);
t("取りに来なくなれば消える", stale.sweep(10_000 + PENDING_TTL_MS)[0]?.requestId, "abcde");

const old = new PermissionRegistry();
old.register(input, { sessionId: null, project: null }, 0);
// 取り直しは続いていても、答えが返らないまま古びた保留は残さない。
old.register(input, { sessionId: null, project: null }, PENDING_MAX_AGE_MS);
t("古すぎる保留は消える", old.sweep(PENDING_MAX_AGE_MS)[0]?.requestId, "abcde");

// ── 並び ──
const many = new PermissionRegistry();
many.register({ ...input, requestId: "bbbbb" }, { sessionId: null, project: null }, 200);
many.register({ ...input, requestId: "aaaaa" }, { sessionId: null, project: null }, 100);
t("古い確認から並べる", many.list().map((p) => p.requestId), ["aaaaa", "bbbbb"]);

function delay<T>(value: T): Promise<T> {
  return new Promise((resolve) => setTimeout(() => resolve(value), 30));
}

console.log(`\npermissions: ${ok} OK / ${ng} NG`);
if (ng > 0) process.exit(1);
