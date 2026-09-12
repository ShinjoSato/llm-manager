// Host / Origin の判定。迂回されると cwd や作業内容が外部サイトから読めるので境界を押さえる。
import {
  isAllowedHost,
  isAllowedOrigin,
  isPrivateIPv4,
  isLoopbackAddress,
  localIPv4Addresses,
  splitHostPort,
} from "../src/origin.js";

let ok = 0;
let ng = 0;

function t(name: string, got: unknown, want: unknown): void {
  const pass = JSON.stringify(got) === JSON.stringify(want);
  pass ? ok++ : ng++;
  console.log(
    `  ${pass ? "OK  " : "NG  "}${name.padEnd(50)}${pass ? "" : `期待 ${JSON.stringify(want)} / 実際 ${JSON.stringify(got)}`}`,
  );
}

const PORT = 8766;

// ── ホストとポートの分割 ──
t("ふつうの host:port", splitHostPort("localhost:8766"), { host: "localhost", port: "8766" });
t("ポート無し", splitHostPort("localhost"), { host: "localhost", port: "" });
t("IPv6 のブラケット形式", splitHostPort("[::1]:8766"), { host: "[::1]", port: "8766" });
t("ブラケットのみ", splitHostPort("[::1]"), { host: "[::1]", port: "" });
t("閉じていないブラケットは割らない", splitHostPort("[::1:8766"), { host: "[::1:8766", port: "" });
// `]` の次が `:` でなければポートとして読まない
t("区切りが : でなければ割らない", splitHostPort("[::1]x8766"), { host: "[::1]x8766", port: "" });

// ── 通すべき Host ──
t("localhost:8766", isAllowedHost("localhost:8766", PORT), true);
t("127.0.0.1:8766", isAllowedHost("127.0.0.1:8766", PORT), true);
t("[::1]:8766", isAllowedHost("[::1]:8766", PORT), true);
t("大文字でも通す", isAllowedHost("LocalHost:8766", PORT), true);

// ── 弾くべき Host ──
t("外部ドメイン", isAllowedHost("evil.example.com:8766", PORT), false);
t("ループバックに似せた部分一致", isAllowedHost("localhost.evil.com:8766", PORT), false);
t("前に付けた形", isAllowedHost("evil-localhost:8766", PORT), false);
t("ポートが違う", isAllowedHost("localhost:8765", PORT), false);
t("ポート省略（既定 80 以外）", isAllowedHost("localhost", PORT), false);
t("Host 無し", isAllowedHost(undefined, PORT), false);
t("空文字", isAllowedHost("", PORT), false);
t("末尾ドット", isAllowedHost("localhost.:8766", PORT), false);
t("ブラケット無しの ::1", isAllowedHost("::1:8766", PORT), false);

// 既定ポートで待つ時だけポート省略を許す
t("80 番ならポート省略を通す", isAllowedHost("localhost", 80), true);
t("80 番でも外部ドメインは弾く", isAllowedHost("evil.com", 80), false);

// PORT=0（OS 任せ）で実ポートが確定した後も通ること
t("実ポートで判定できる", isAllowedHost("localhost:49152", 49152), true);

// ── Origin ──
t("同一オリジン", isAllowedOrigin("http://localhost:8766", PORT), true);
t("Vite の開発ポート", isAllowedOrigin("http://localhost:5174", PORT), true);
t("127.0.0.1", isAllowedOrigin("http://127.0.0.1:8766", PORT), true);
t("IPv6", isAllowedOrigin("http://[::1]:8766", PORT), true);
t("外部ドメイン", isAllowedOrigin("https://evil.example.com", PORT), false);
// ユーザー情報部はホスト名ではない
t("localhost@evil.com は弾く", isAllowedOrigin("http://localhost@evil.com", PORT), false);
t("localhost.evil.com は弾く", isAllowedOrigin("http://localhost.evil.com", PORT), false);
t("Origin: null は弾く", isAllowedOrigin("null", PORT), false);
t("空文字は弾く", isAllowedOrigin("", PORT), false);
t("http/https 以外は弾く", isAllowedOrigin("chrome-extension://abcdef", PORT), false);
t("file: は弾く", isAllowedOrigin("file:///etc/passwd", PORT), false);

// ── LAN 公開時の追加ホスト ──
const LAN = new Set(["192.168.0.11"]);

t("LAN IP を通す", isAllowedHost("192.168.0.11:8766", PORT, LAN), true);
t("LAN IP でもポートが違えば弾く", isAllowedHost("192.168.0.11:8765", PORT, LAN), false);
t("許可に無い LAN IP は弾く", isAllowedHost("192.168.0.12:8766", PORT, LAN), false);
t("LAN 公開でもループバックは通す", isAllowedHost("localhost:8766", PORT, LAN), true);
t("LAN 公開でも外部ドメインは弾く", isAllowedHost("evil.example.com:8766", PORT, LAN), false);
t("追加ホスト無しなら LAN IP は弾く", isAllowedHost("192.168.0.11:8766", PORT), false);
t("LAN IP の Origin を通す", isAllowedOrigin("http://192.168.0.11:8766", PORT, LAN), true);
t("追加ホスト無しなら LAN IP の Origin は弾く", isAllowedOrigin("http://192.168.0.11:8766", PORT), false);
t("LAN 公開でも外部 Origin は弾く", isAllowedOrigin("https://evil.example.com", PORT, LAN), false);
// 同じ IP の別ポートで動く別サービスとは cookie を共有するので、LAN 側はポートまで見る
t("LAN IP でもポートが違えば弾く", isAllowedOrigin("http://192.168.0.11:3000", PORT, LAN), false);
t("ループバックはポートを問わない（Vite）", isAllowedOrigin("http://localhost:5174", PORT, LAN), true);

// 案内 URL に出す IP の絞り込み
t("192.168 は家庭内の帯", isPrivateIPv4("192.168.0.11"), true);
t("10 系も家庭内の帯", isPrivateIPv4("10.0.1.5"), true);
t("172.16〜31 は家庭内の帯", isPrivateIPv4("172.20.0.3"), true);
t("172.15 は範囲外", isPrivateIPv4("172.15.0.3"), false);
t("グローバル IP は外す", isPrivateIPv4("203.0.113.5"), false);
t("VPN の 100 系は外す", isPrivateIPv4("100.64.0.1"), false);

// ── 接続元アドレスの判定（Host は詐称できるのでこちらで手元かを見る） ──
t("127.0.0.1 は手元", isLoopbackAddress("127.0.0.1"), true);
t("127.x の別アドレスも手元", isLoopbackAddress("127.1.2.3"), true);
t("::1 は手元", isLoopbackAddress("::1"), true);
t("IPv4 射影の 127.0.0.1 は手元", isLoopbackAddress("::ffff:127.0.0.1"), true);
t("LAN IP は手元ではない", isLoopbackAddress("192.168.0.11"), false);
t("IPv4 射影の LAN IP も手元ではない", isLoopbackAddress("::ffff:192.168.0.11"), false);
t("127 で始まる別アドレスは手元ではない", isLoopbackAddress("1270.0.0.1"), false);
t("アドレス不明は手元ではない", isLoopbackAddress(undefined), false);
t("空文字は手元ではない", isLoopbackAddress(""), false);

// 列挙した自分の IPv4 にループバックが混ざると、トークン無しで通る穴になる
t(
  "自分の IPv4 にループバックは含まれない",
  localIPv4Addresses().some(isLoopbackAddress),
  false,
);

console.log(`\n  ${ng === 0 ? "PASS" : "FAIL"}: ${ok} 件成功 / ${ng} 件失敗`);
if (ng) process.exitCode = 1;
