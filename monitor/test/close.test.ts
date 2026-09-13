// Xcode を閉じる操作。パスを AppleScript に埋め込むと `"` や `\` を含むパスで壊れるので、argv 渡しを押さえる。
import { closeArgs, isCloseApp, parseCloseState } from "../src/close.js";
import { failureReason } from "../src/open.js";

let ok = 0;
let ng = 0;

function t(name: string, got: unknown, want: unknown): void {
  const pass = JSON.stringify(got) === JSON.stringify(want);
  pass ? ok++ : ng++;
  console.log(
    `  ${pass ? "OK  " : "NG  "}${name.padEnd(50)}${pass ? "" : `期待 ${JSON.stringify(want)} / 実際 ${JSON.stringify(got)}`}`,
  );
}

// ── app のホワイトリスト ──
t("xcode は通す", isCloseApp("xcode"), true);
t("vscode は通さない", isCloseApp("vscode"), false);
t("finder は通さない", isCloseApp("finder"), false);
t("大文字は通さない", isCloseApp("Xcode"), false);
t("空文字は通さない", isCloseApp(""), false);
t("文字列以外は通さない", isCloseApp({ app: "xcode" }), false);
t("undefined は通さない", isCloseApp(undefined), false);

// ── osascript へ渡す引数 ──
const NASTY = '/Users/me/a "quoted" \\path/My App.xcodeproj';
const args = closeArgs(NASTY);

t("パスは末尾に 1 引数として渡す", args.at(-1), NASTY);
t("パスは 1 回だけ現れる", args.filter((a) => a === NASTY).length, 1);
// 埋め込みが起きていれば、スクリプト行のどれかにパスの断片が混ざる。
t(
  "スクリプト行にパスを埋め込まない",
  args.slice(0, -1).some((a) => a.includes("quoted") || a.includes("My App")),
  false,
);
t(
  "スクリプト行は -e と交互",
  args.slice(0, -1).filter((_, i) => i % 2 === 0),
  new Array((args.length - 1) / 2).fill("-e"),
);
t(
  "起動していない Xcode を立ち上げない（running を先に見る）",
  args.some((a) => a.includes('application "Xcode" is running')),
  true,
);
t(
  "アプリごと終了しない",
  args.some((a) => /\bquit\b/.test(a)),
  false,
);

// ── osascript の応答 ──
t("closed", parseCloseState("closed\n"), "closed");
t("not_open", parseCloseState("not_open\n"), "not_open");
t("not_running", parseCloseState(" not_running "), "not_running");
t("知らない応答は null", parseCloseState("something else"), null);
t("空の応答は null", parseCloseState(""), null);

// 打ち切られた時にコマンド全文を画面へ出さない（スクリプトが丸ごと赤字で出ていた）
{
  const killed = Object.assign(new Error("Command failed: /usr/bin/osascript -e on run argv"), { killed: true });
  t("打ち切りは言い換える", failureReason(killed, ""), "応答がありません（確認ダイアログが出ているかもしれません）");
  const signaled = Object.assign(new Error("Command failed"), { signal: "SIGTERM" });
  t("シグナルでも言い換える", failureReason(signaled, ""), "応答がありません（確認ダイアログが出ているかもしれません）");
  const plain = Object.assign(new Error("boom"), {});
  t("ふつうの失敗は stderr を出す", failureReason(plain, "  やられた  "), "やられた");
  t("stderr が空なら message", failureReason(plain, ""), "boom");
}

console.log(`close: ${ok} OK / ${ng} NG`);
if (ng > 0) process.exit(1);
