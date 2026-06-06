import { execFile } from "node:child_process";

export interface RunResult {
  stdout: string;
  stderr: string;
  code: number;
}

/** 外部CLI（gh/git）を実行。失敗してもthrowせず {code} で返す（Python版の run() 相当）。 */
export function run(
  cmd: string,
  args: string[],
  opts: { cwd?: string; timeout?: number } = {},
): Promise<RunResult> {
  return new Promise((resolve) => {
    execFile(
      cmd,
      args,
      { cwd: opts.cwd, timeout: opts.timeout ?? 60_000, maxBuffer: 32 * 1024 * 1024 },
      (err, stdout, stderr) => {
        const code = err && typeof (err as any).code === "number" ? (err as any).code : err ? 1 : 0;
        resolve({ stdout: (stdout ?? "").trim(), stderr: (stderr ?? "").trim(), code });
      },
    );
  });
}
