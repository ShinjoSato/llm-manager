// セッションの受信箱ソケットへテキストを投稿する。
// 経路は公式に文書化されたもので（cross-session messaging の "The session's inbox socket"）、
// 行区切りの JSON を書く。届いたテキストは「別セッションからのメッセージ」として扱われ、
// ユーザー本人の指示にはならない（権限承認・設定変更・スラッシュコマンドは不可）。
import { existsSync } from "node:fs";
import { connect } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

/** 接続してから書き終えるまでの猶予。受信側は 30 秒で切る。 */
const SEND_TIMEOUT_MS = 5_000;

export interface SendResult {
  ok: boolean;
  error?: string;
}

/**
 * レジストリに socket パスが無い場合の既定位置。
 * Claude Code は `$XDG_RUNTIME_DIR|/tmp` の `cc-socks/<pid>.sock` を使い、
 * パスが長すぎる場合だけ `cc-socks-<uid>/` に退避する。
 */
export function defaultSocketPath(pid: number): string | null {
  const bases = [
    join(process.env.XDG_RUNTIME_DIR ?? "/tmp", "cc-socks", `${pid}.sock`),
    join("/tmp", `cc-socks-${process.getuid?.() ?? 0}`, `${pid}.sock`),
  ];
  return bases.find((p) => existsSync(p)) ?? null;
}

/** ~ 始まりのパスを展開する（レジストリの値をそのまま使えるように）。 */
export function expandHome(path: string): string {
  return path.startsWith("~/") ? join(homedir(), path.slice(2)) : path;
}

/** 受信箱ソケットへ 1 通投稿する。接続は書く直前に開く。 */
export function sendToSession(socketPath: string, text: string, token?: string): Promise<SendResult> {
  return new Promise((resolve) => {
    let settled = false;
    const done = (r: SendResult) => {
      if (settled) return;
      settled = true;
      resolve(r);
    };

    const socket = connect(socketPath);
    socket.setTimeout(SEND_TIMEOUT_MS);

    socket.on("connect", () => {
      const lines: string[] = [];
      // macOS/Linux では任意だが、付けられる時は付けておく（Windows では必須）。
      if (token) lines.push(JSON.stringify({ type: "auth", token }));
      lines.push(JSON.stringify({ type: "user", message: { role: "user", content: text } }));
      socket.end(lines.join("\n") + "\n", () => done({ ok: true }));
    });

    socket.on("timeout", () => {
      socket.destroy();
      done({ ok: false, error: "接続がタイムアウトしました" });
    });

    socket.on("error", (err) => {
      socket.destroy();
      done({ ok: false, error: err.message });
    });
  });
}
