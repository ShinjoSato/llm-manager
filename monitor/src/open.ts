// macOS の `open` でエディタに開かせる。同じパスを開き直すと既存ウィンドウが前面に出る。
import { execFile } from "node:child_process";
import { isAbsolute } from "node:path";

export const OPEN_APPS = ["vscode", "xcode"] as const;
export type OpenApp = (typeof OPEN_APPS)[number];

/** `open -a` に渡すアプリ名。受け取った文字列をそのままコマンドへ渡さないための対応表。 */
export const APP_NAMES: Record<OpenApp, string> = {
  vscode: "Visual Studio Code",
  xcode: "Xcode",
};

const TIMEOUT_MS = 15_000;

export type OpenFailure = "not_found" | "no_project" | "failed";

export interface OpenResult {
  ok: boolean;
  error?: string;
  code?: OpenFailure;
}

export function isOpenApp(value: unknown): value is OpenApp {
  return typeof value === "string" && (OPEN_APPS as readonly string[]).includes(value);
}

/** 実行に失敗した理由。打ち切りは err.message にコマンド全文が入るので出さない。 */
export function failureReason(err: Error & { killed?: boolean; signal?: string }, stderr: string): string {
  if (err.killed || err.signal) return "応答がありません（確認ダイアログが出ているかもしれません）";
  return stderr.trim() || err.message;
}

/** シェルを経由せず引数配列で渡す。空白入りのパス（`App Store Checker.xcodeproj`）もそのまま通る。 */
export function openWithApp(app: OpenApp, target: string): Promise<OpenResult> {
  // 先頭が `-` のパスは open のオプションとして解釈される。
  if (!isAbsolute(target)) {
    return Promise.resolve({ ok: false, error: "開く先が絶対パスではありません", code: "failed" });
  }
  return new Promise((resolve) => {
    execFile(
      "/usr/bin/open",
      ["-a", APP_NAMES[app], target],
      { timeout: TIMEOUT_MS },
      (err, _stdout, stderr) => {
        if (!err) return resolve({ ok: true });
        resolve({ ok: false, error: failureReason(err, stderr), code: "failed" });
      },
    );
  });
}
