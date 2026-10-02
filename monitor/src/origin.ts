// DNS リバインディング対策の判定。攻撃者のドメインを 127.0.0.1 に向けても
// Host は攻撃者のもののままなので、ここで弾ける。

/** ループバックを指すホスト名。これ以外は外部のドメイン。 */
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);

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

export function isAllowedHost(value: string | undefined, port: number): boolean {
  if (!value) return false; // Host 無し（HTTP/1.0 等）は塞ぐ側に倒す。
  const { host, port: hostPort } = splitHostPort(value.toLowerCase()); // ホスト名は大文字小文字を区別しない
  if (!LOOPBACK_HOSTS.has(host)) return false;
  // 既定ポート(80)で待つ時だけクライアントがポートを省く。
  return hostPort === String(port) || (hostPort === "" && port === 80);
}

export function isAllowedOrigin(value: string): boolean {
  let url: URL;
  try {
    url = new URL(value); // Origin: null（sandbox iframe 等）はここで弾かれる。
  } catch {
    return false;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return false;
  // 手元のページだけ通す。書き込み口は content-type: application/json 必須なので、別ポートのページからもプリフライトで止まる。
  return LOOPBACK_HOSTS.has(url.hostname);
}

/** 接続元が手元かどうか。Host は詐称できるのでソケットのアドレスで判定する。 */
export function isLoopbackAddress(value: string | undefined): boolean {
  if (!value) return false;
  const addr = value.startsWith("::ffff:") ? value.slice("::ffff:".length) : value; // IPv4 射影アドレス
  return addr === "::1" || /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(addr);
}
