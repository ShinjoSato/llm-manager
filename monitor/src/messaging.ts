// セッションの受信箱ソケットへテキストを投稿する。
// 経路は公式に文書化されたもので（cross-session messaging の "The session's inbox socket"）、
// 行区切りの JSON を書く。届いたテキストは「別セッションからのメッセージ」として扱われ、
// ユーザー本人の指示にはならない（権限承認・設定変更・スラッシュコマンドは不可）。
import { lstatSync } from "node:fs";
import { connect } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

/** 無通信がこれだけ続いたら諦める。受信側は 30 秒で切る。 */
const IDLE_TIMEOUT_MS = 5_000;
/** 相手が読み続けても待ち続けないための全体の締め切り。 */
const TOTAL_TIMEOUT_MS = 15_000;

export type SendFailure = "not_found" | "not_alive" | "no_socket" | "unreachable";

export interface SendResult {
  ok: boolean;
  error?: string;
  code?: SendFailure;
}

/**
 * 自分が所有する Unix ソケットか。
 * lstat なのでシンボリックリンクは isSocket() が false になり、他人が仕掛けた口に書き込まない。
 */
export function isOwnSocket(path: string): boolean {
  try {
    const st = lstatSync(path);
    return st.isSocket() && st.uid === (process.getuid?.() ?? st.uid);
  } catch {
    return false;
  }
}

/**
 * レジストリに socket パスが無い場合の既定位置。
 * Claude Code は `$XDG_RUNTIME_DIR|/tmp` の `cc-socks/<pid>.sock` を使い、
 * パスが長すぎる場合だけ `cc-socks-<uid>/` に退避する。
 */
export function defaultSocketPath(pid: number): string | null {
  const candidates = [
    join(process.env.XDG_RUNTIME_DIR ?? "/tmp", "cc-socks", `${pid}.sock`),
    join("/tmp", `cc-socks-${process.getuid?.() ?? 0}`, `${pid}.sock`),
  ];
  return candidates.find(isOwnSocket) ?? null;
}

/** ~ 始まりのパスを展開する（レジストリの値をそのまま使えるように）。 */
export function expandHome(path: string): string {
  if (path === "~") return homedir();
  return path.startsWith("~/") ? join(homedir(), path.slice(2)) : path;
}

/**
 * 受信箱ソケットへ 1 通投稿する。接続は書く直前に開く。
 * ok は「書き終えた」までの保証で、受信側が受理したかまでは分からない。
 */
export function sendToSession(socketPath: string, text: string): Promise<SendResult> {
  return new Promise((resolve) => {
    let settled = false;
    const done = (r: SendResult) => {
      if (settled) return;
      settled = true;
      clearTimeout(deadline);
      socket.destroy();
      resolve(r);
    };

    const socket = connect(socketPath);
    socket.setTimeout(IDLE_TIMEOUT_MS);
    const deadline = setTimeout(
      () => done({ ok: false, error: "送信が時間内に終わりませんでした", code: "unreachable" }),
      TOTAL_TIMEOUT_MS,
    );

    socket.on("connect", () => {
      // 認証行は macOS/Linux では任意。他セッションのトークンは持てないので付けない。
      const line = JSON.stringify({ type: "user", message: { role: "user", content: text } });
      socket.end(line + "\n", (err?: Error | null) =>
        done(err ? { ok: false, error: err.message, code: "unreachable" } : { ok: true }),
      );
    });

    socket.on("timeout", () =>
      done({ ok: false, error: "応答がありませんでした", code: "unreachable" }),
    );
    socket.on("error", (err) => done({ ok: false, error: err.message, code: "unreachable" }));
    // 書き終える前に閉じられた場合に、Promise が宙に浮かないようにする。
    socket.on("close", () =>
      done({ ok: false, error: "接続が閉じられました", code: "unreachable" }),
    );
  });
}
