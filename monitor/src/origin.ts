// DNS リバインディング対策の判定。攻撃者のドメインを 127.0.0.1 に向けても
// Host は攻撃者のもののままなので、ここで弾ける。
import { networkInterfaces } from "node:os";

/** ループバックを指すホスト名。これ以外は外部のドメイン。 */
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);

/** LAN 公開時に追加で許可するホスト。既定は空でループバックのみ。 */
const NO_EXTRA: ReadonlySet<string> = new Set();

/** `host:port` をホストとポートに割る。`[::1]:8766` のブラケット形式も扱う。 */
export function splitHostPort(value: string): { host: string; port: string } {
  if (value.startsWith("[")) {
    const end = value.indexOf("]");
    if (end < 0 || (value.length > end + 1 && value[end + 1] !== ":")) {
      return { host: value, port: "" };
    }
    return { host: value.slice(0, end + 1), port: value.slice(end + 2) };
  }
  const sep = value.lastIndexOf(":");
  return sep < 0
    ? { host: value, port: "" }
    : { host: value.slice(0, sep), port: value.slice(sep + 1) };
}

export function isAllowedHost(
  value: string | undefined,
  port: number,
  extra: ReadonlySet<string> = NO_EXTRA,
): boolean {
  if (!value) return false; // Host 無し（HTTP/1.0 等）は塞ぐ側に倒す。ブラウザは必ず付ける。
  const { host, port: hostPort } = splitHostPort(value.toLowerCase()); // ホスト名は大文字小文字を区別しない
  if (!LOOPBACK_HOSTS.has(host) && !extra.has(host)) return false;
  // 既定ポート(80)で待つ時だけブラウザがポートを省く。
  return hostPort === String(port) || (hostPort === "" && port === 80);
}

export function isAllowedOrigin(value: string, extra: ReadonlySet<string> = NO_EXTRA): boolean {
  let url: URL;
  try {
    url = new URL(value); // Origin: null（sandbox iframe 等）はここで弾かれる。
  } catch {
    return false;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return false;
  // 開発時の Vite は別ポートで配信するので、ループバックならポートは問わない。
  return LOOPBACK_HOSTS.has(url.hostname) || extra.has(url.hostname);
}

/** 接続元が手元かどうか。Host は詐称できるのでソケットのアドレスで判定する。 */
export function isLoopbackAddress(value: string | undefined): boolean {
  if (!value) return false;
  const addr = value.startsWith("::ffff:") ? value.slice("::ffff:".length) : value; // IPv4 射影アドレス
  return addr === "::1" || /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(addr);
}

/** 自分の非ループバック IPv4。LAN 公開時の許可ホストと案内 URL に使う。 */
export function localIPv4Addresses(): string[] {
  return Object.values(networkInterfaces())
    .flatMap((entries) => entries ?? [])
    .filter((entry) => entry.family === "IPv4" && !entry.internal)
    .map((entry) => entry.address);
}
