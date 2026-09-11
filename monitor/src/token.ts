// LAN 公開時に使う共有トークン。生成・読み出し・比較。
import { randomBytes, timingSafeEqual } from "node:crypto";
import { chmodSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

/** 置き場は他の秘密情報と揃える（`secrets/*` は .gitignore 済み）。 */
export const TOKEN_FILE = join(HERE, "..", "..", "secrets", "monitor-token");

/** 総当たりが現実的でなくなる長さ。環境変数で短いものを渡されても開かない。 */
export const MIN_TOKEN_LENGTH = 32;

/** 環境変数を優先し、無ければ secrets から読む。未生成なら作る。用意できなければ null。 */
export function loadOrCreateToken(file: string = TOKEN_FILE): string | null {
  const fromEnv = process.env.MONITOR_TOKEN?.trim();
  if (fromEnv) return fromEnv.length >= MIN_TOKEN_LENGTH ? fromEnv : null;

  try {
    const saved = readFileSync(file, "utf8").trim();
    if (saved) return saved;
  } catch (e) {
    // 権限が無くて読めない場合に作り直すと、既存端末の cookie を黙って無効にしてしまう。
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") return null;
  }

  try {
    const token = randomBytes(32).toString("hex");
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, `${token}\n`, { mode: 0o600 });
    chmodSync(file, 0o600); // 既存ファイルには writeFileSync の mode が効かないため明示する
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
