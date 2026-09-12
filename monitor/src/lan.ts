// LAN 接続用の案内（URL と QR）の組み立て。
import QRCode from "qrcode-svg";
import { isLoopbackAddress, isPrivateIPv4 } from "./origin.js";

export interface LanInfo {
  /** LAN 公開中か（`MONITOR_LAN=1`）。 */
  enabled: boolean;
  /** 接続用 URL。LAN の IPv4 が見つからなければ null。 */
  url: string | null;
}

/** 案内に使う 1 本。VPN や Docker の仮想 IF より家庭内の帯を先に選ぶ。 */
export function pickLanHost(hosts: Iterable<string>): string | null {
  const all = [...hosts];
  return all.find(isPrivateIPv4) ?? all[0] ?? null;
}

export function lanUrl(host: string, port: number, token: string): string {
  return `http://${host}:${port}/?t=${encodeURIComponent(token)}`;
}

/**
 * 案内を返す。ループバック以外には null（＝呼び出し側で 404）。
 * 認証済みの LAN 端末にも見せると、その端末から他人へトークンを渡せてしまい、
 * cookie を HttpOnly にして JS からトークンを隠している意味が薄れる。
 */
export function lanInfoFor(
  remoteAddress: string | undefined,
  hosts: Iterable<string>,
  port: number,
  token: string | null,
): LanInfo | null {
  if (!isLoopbackAddress(remoteAddress)) return null;
  if (!token) return { enabled: false, url: null };
  const host = pickLanHost(hosts);
  return { enabled: true, url: host ? lanUrl(host, port, token) : null };
}

/** QR の SVG。ループバック以外・LAN 非公開・LAN の IPv4 なしはいずれも null。 */
export function lanQrSvgFor(
  remoteAddress: string | undefined,
  hosts: Iterable<string>,
  port: number,
  token: string | null,
): string | null {
  const info = lanInfoFor(remoteAddress, hosts, port, token);
  if (!info?.enabled || !info.url) return null;
  return qrSvg(info.url);
}

/** join で 1 本の path にまとめる。モジュールを個別の rect で描くと SVG が数百要素に膨らむ。 */
export function qrSvg(content: string): string {
  return new QRCode({ content, padding: 2, width: 320, height: 320, ecl: "M", join: true }).svg();
}
