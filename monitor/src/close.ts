// Xcode から 1 つのワークスペースだけを閉じる。アプリごと終了はしない。
import { execFile } from "node:child_process";
import { isAbsolute } from "node:path";

export const CLOSE_APPS = ["xcode"] as const;
export type CloseApp = (typeof CLOSE_APPS)[number];

const TIMEOUT_MS = 15_000;

/** 閉じられたか、そもそも開いていなかったか。どれも成功として扱う（冪等）。 */
export const CLOSE_STATES = ["closed", "not_open", "not_running"] as const;
export type CloseState = (typeof CLOSE_STATES)[number];

export type CloseFailure = "not_found" | "no_project" | "failed";

export interface CloseResult {
  ok: boolean;
  state?: CloseState;
  error?: string;
  code?: CloseFailure;
}

export function isCloseApp(value: unknown): value is CloseApp {
  return typeof value === "string" && (CLOSE_APPS as readonly string[]).includes(value);
}

const SCRIPT = [
  "on run argv",
  "set wanted to item 1 of argv",
  // running を先に見る。`tell application "Xcode"` は起動していない Xcode を立ち上げてしまう。
  'if not (application "Xcode" is running) then return "not_running"',
  'tell application "Xcode"',
  "repeat with doc in workspace documents",
  // `target` は Xcode の用語なので変数名に使えない（用語として解釈され一致しない）。
  "if (path of doc) is wanted then",
  "close doc",
  'return "closed"',
  "end if",
  "end repeat",
  "end tell",
  'return "not_open"',
  "end run",
] as const;

/** パスは argv で渡す。スクリプトに埋め込むと `"` や `\` を含むパスで壊れる。 */
export function closeArgs(target: string): string[] {
  return [...SCRIPT.flatMap((line) => ["-e", line]), target];
}

export function parseCloseState(stdout: string): CloseState | null {
  const value = stdout.trim();
  return (CLOSE_STATES as readonly string[]).includes(value) ? (value as CloseState) : null;
}

/** シェルを経由せず引数配列で渡す。空白入りのパスもそのまま通る。 */
export function closeXcodeWorkspace(target: string): Promise<CloseResult> {
  // 先頭が `-` のパスは osascript のオプションとして解釈される。
  if (!isAbsolute(target)) {
    return Promise.resolve({ ok: false, error: "閉じる先が絶対パスではありません", code: "failed" });
  }
  return new Promise((resolve) => {
    execFile(
      "/usr/bin/osascript",
      closeArgs(target),
      { timeout: TIMEOUT_MS },
      (err, stdout, stderr) => {
        if (err) return resolve({ ok: false, error: stderr.trim() || err.message, code: "failed" });
        const state = parseCloseState(stdout);
        if (!state) return resolve({ ok: false, error: "応答を読めません", code: "failed" });
        resolve({ ok: true, state });
      },
    );
  });
}
