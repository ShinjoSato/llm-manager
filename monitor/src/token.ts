// LAN 公開時に使う共有トークン。生成・読み出し・比較。
import { randomBytes, timingSafeEqual } from "node:crypto";
import { chmodSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

/** 置き場は他の秘密情報と揃える（`secrets/*` は .gitignore 済み）。 */
export const TOKEN_FILE = join(HERE, "..", "..", "secrets", "monitor-token");

/** 環境変数を優先し、無ければ secrets から読む。未生成なら作る。用意できなければ null。 */
export function loadOrCreateToken(): string | null {
  const fromEnv = process.env.MONITOR_TOKEN?.trim();
  if (fromEnv) return fromEnv;

  try {
    const saved = readFileSync(TOKEN_FILE, "utf8").trim();
    if (saved) return saved;
  } catch {
    // 未生成。下で作る。
  }

  try {
    const token = randomBytes(32).toString("hex");
    mkdirSync(dirname(TOKEN_FILE), { recursive: true });
    writeFileSync(TOKEN_FILE, `${token}\n`, { mode: 0o600 });
    chmodSync(TOKEN_FILE, 0o600); // 既存ファイルには writeFileSync の mode が効かないため明示する
    return token;
  } catch {
    return null;
  }
}

/** 比較は固定時間で行う。途中で返ると 1 文字ずつ当てる手掛かりになる。 */
export function tokenEquals(expected: string, given: string | undefined | null): boolean {
  if (!given) return false;
  const a = Buffer.from(expected, "utf8");
  const b = Buffer.from(given, "utf8");
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}
