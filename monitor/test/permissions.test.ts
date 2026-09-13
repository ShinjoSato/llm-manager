// 権限確認の中継。承認が手元以外に漏れると、平文 HTTP 越しに任意のコマンドを許可できてしまう。
import {
  isDecision,
  isLocalActor,
  matchSession,
  parseRequest,
  PENDING_MAX_AGE_MS,
  PENDING_TTL_MS,
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
t("PID で引く", matchSession({ pid: 1234, cwd: null }, SESSIONS), "s1");
t("終了済みは引かない", matchSession({ pid: 9999, cwd: null }, SESSIONS), null);
t("PID が無ければ cwd で引く", matchSession({ pid: null, cwd: "/a" }, SESSIONS), "s1");
t("同じ cwd が複数なら引かない", matchSession({ pid: null, cwd: "/b" }, SESSIONS), null);
t("PID が優先", matchSession({ pid: 5678, cwd: "/a" }, SESSIONS), "s2");
t("手掛かりが無ければ null", matchSession({ pid: null, cwd: null }, SESSIONS), null);
t("知らない PID は cwd に落ちる", matchSession({ pid: 1, cwd: "/a" }, SESSIONS), "s1");

// ── 保留の出し入れ ──
const input = parseRequest(raw)!;
const reg = new PermissionRegistry();
const added = reg.register(input, { sessionId: "s1", project: "project" }, 1_000);
t("初回は created", added.created, true);
t("預かった内容が出る", reg.list(), [
  {
    requestId: "abcde",
    sessionId: "s1",
    project: "project",
    toolName: "Bash",
    description: "ls を実行する",
    inputPreview: '{"command":"ls"}',
    askedAt: 1_000,
  },
]);
t("取り直しは created ではない", reg.register(input, { sessionId: null, project: null }, 2_000).created, false);
t("取り直しでセッションは消えない", reg.list()[0]?.sessionId, "s1");
t("知らない ID は決められない", reg.decide("zzzzz", "allow"), null);

const waiting = reg.wait("abcde", 50);
t("判断で保留は消える", reg.decide("abcde", "allow")?.toolName, "Bash");
t("待っていた側に判断が返る", await waiting, "allow");
t("決めた後は空", reg.list(), []);
t("知らない ID を待つと dropped", await reg.wait("abcde", 50), "dropped");

// 判断が出なければ timeout。保留は残したままなので、チャネルが取り直せる。
reg.register(input, { sessionId: "s1", project: "project" }, 3_000);
t("判断が出なければ timeout", await reg.wait("abcde", 10), "timeout");
t("timeout でも保留は残る", reg.size(), 1);

// ── 端末側で先に答えられた分は落とす ──
t("預かる前の活動では落ちない", reg.dropResolved("s1", 3_000).length, 0);
t("別セッションの活動では落ちない", reg.dropResolved("s2", 9_000).length, 0);
const watching = reg.wait("abcde", 50);
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

console.log(`\npermissions: ${ok} OK / ${ng} NG`);
if (ng > 0) process.exit(1);
