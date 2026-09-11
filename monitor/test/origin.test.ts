// Host / Origin の判定。迂回されると cwd や作業内容が外部サイトから読めるので境界を押さえる。
import { isAllowedHost, isAllowedOrigin, splitHostPort } from "../src/origin.js";

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
t("同一オリジン", isAllowedOrigin("http://localhost:8766"), true);
t("Vite の開発ポート", isAllowedOrigin("http://localhost:5174"), true);
t("127.0.0.1", isAllowedOrigin("http://127.0.0.1:8766"), true);
t("IPv6", isAllowedOrigin("http://[::1]:8766"), true);
t("外部ドメイン", isAllowedOrigin("https://evil.example.com"), false);
// ユーザー情報部はホスト名ではない
t("localhost@evil.com は弾く", isAllowedOrigin("http://localhost@evil.com"), false);
t("localhost.evil.com は弾く", isAllowedOrigin("http://localhost.evil.com"), false);
t("Origin: null は弾く", isAllowedOrigin("null"), false);
t("空文字は弾く", isAllowedOrigin(""), false);
t("http/https 以外は弾く", isAllowedOrigin("chrome-extension://abcdef"), false);
t("file: は弾く", isAllowedOrigin("file:///etc/passwd"), false);

console.log(`\n  ${ng === 0 ? "PASS" : "FAIL"}: ${ok} 件成功 / ${ng} 件失敗`);
if (ng) process.exitCode = 1;
