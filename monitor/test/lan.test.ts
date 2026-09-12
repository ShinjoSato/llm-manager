// LAN 接続用の案内。ループバック以外へ漏れると、認証済み端末から他人へトークンを渡せてしまう。
import { lanInfoFor, lanQrSvgFor, lanUrl, pickLanHost, qrSvg } from "../src/lan.js";

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
const TOKEN = "a".repeat(64);
const HOSTS = ["192.168.0.11"];

// ── 案内に使うホストの選び方 ──
t("家庭内の帯を選ぶ", pickLanHost(["169.254.1.1", "192.168.0.11"]), "192.168.0.11");
t("10/8 も家庭内の帯", pickLanHost(["169.254.1.1", "10.0.0.5"]), "10.0.0.5");
t("172.16/12 も家庭内の帯", pickLanHost(["169.254.1.1", "172.20.3.4"]), "172.20.3.4");
t("家庭内の帯が無ければ先頭", pickLanHost(["169.254.1.1", "100.64.0.2"]), "169.254.1.1");
t("空なら null", pickLanHost([]), null);

// ── URL の組み立て ──
t("トークン付き URL", lanUrl("192.168.0.11", PORT, TOKEN), `http://192.168.0.11:8766/?t=${TOKEN}`);
t("トークンはエスケープする", lanUrl("10.0.0.5", 80, "a b/c"), "http://10.0.0.5:80/?t=a%20b%2Fc");

// ── ループバックからだけ案内する ──
t("127.0.0.1 には返す", lanInfoFor("127.0.0.1", HOSTS, PORT, TOKEN), {
  enabled: true,
  url: `http://192.168.0.11:8766/?t=${TOKEN}`,
});
t("::1 にも返す", lanInfoFor("::1", HOSTS, PORT, TOKEN)?.enabled, true);
t("IPv4 射影のループバックにも返す", lanInfoFor("::ffff:127.0.0.1", HOSTS, PORT, TOKEN)?.enabled, true);
t("127.0.0.2 も手元", lanInfoFor("127.0.0.2", HOSTS, PORT, TOKEN)?.enabled, true);

// トークンを持つ LAN 端末でも案内しない（cookie を HttpOnly にしている意味を保つ）
t("LAN からは null", lanInfoFor("192.168.0.11", HOSTS, PORT, TOKEN), null);
t("IPv4 射影の LAN からも null", lanInfoFor("::ffff:192.168.0.11", HOSTS, PORT, TOKEN), null);
t("外部アドレスからも null", lanInfoFor("203.0.113.9", HOSTS, PORT, TOKEN), null);
t("接続元不明なら null", lanInfoFor(undefined, HOSTS, PORT, TOKEN), null);

// ── LAN 非公開のとき ──
t("トークン無しなら enabled: false", lanInfoFor("127.0.0.1", [], PORT, null), {
  enabled: false,
  url: null,
});
t("LAN の IPv4 が無ければ url は null", lanInfoFor("127.0.0.1", [], PORT, TOKEN), {
  enabled: true,
  url: null,
});

// ── QR ──
const svg = lanQrSvgFor("127.0.0.1", HOSTS, PORT, TOKEN);
t("ループバックには SVG を返す", svg?.startsWith("<?xml") || svg?.startsWith("<svg"), true);
t("SVG に描画要素がある", /<(path|rect)\b/.test(svg ?? ""), true);
t("QR にトークンは載るが SVG の文字列には出ない", svg?.includes(TOKEN), false);
t("LAN からは QR も null", lanQrSvgFor("192.168.0.11", HOSTS, PORT, TOKEN), null);
t("LAN 非公開なら QR は null", lanQrSvgFor("127.0.0.1", HOSTS, PORT, null), null);
t("LAN の IPv4 が無ければ QR は null", lanQrSvgFor("127.0.0.1", [], PORT, TOKEN), null);

// 内容が変われば絵も変わる（同じ SVG を返し続けていないこと）
t("内容ごとに別の絵になる", qrSvg("http://a") === qrSvg("http://b"), false);

console.log(`\nlan: ${ok} OK / ${ng} NG`);
if (ng > 0) process.exit(1);
