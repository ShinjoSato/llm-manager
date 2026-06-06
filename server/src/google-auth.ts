// Google カレンダーの refresh token を取得する一回限りのヘルパー（loopback 方式）。
//
//   cd server && npm run google-auth                 読み取り専用(calendar.readonly)
//   cd server && npm run google-auth -- --write      予定の作成も可(calendar.events)
//
// clientId / clientSecret は次の優先順で解決:
//   1. 引数 --client-id / --client-secret
//   2. 環境変数 GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET
//   3. secrets/google-credentials.json（先に id/secret だけ書いておいてもOK）
//
// 成功すると refresh token を secrets/google-credentials.json に書き込む。
import { createServer } from "node:http";
import { exec } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { ROOT } from "./core/paths.js";

const CRED = join(ROOT, "secrets", "google-credentials.json");
const PORT = 4571;
const REDIRECT = `http://localhost:${PORT}`;

const args = process.argv.slice(2);
const argVal = (name: string) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const wantWrite = args.includes("--write");
const SCOPE = argVal("--scope") ||
  (wantWrite
    ? "https://www.googleapis.com/auth/calendar.events"
    : "https://www.googleapis.com/auth/calendar.readonly");

const existing: Record<string, string> = existsSync(CRED)
  ? JSON.parse(readFileSync(CRED, "utf-8"))
  : {};
const clientId = argVal("--client-id") || process.env.GOOGLE_CLIENT_ID || existing.clientId;
const clientSecret = argVal("--client-secret") || process.env.GOOGLE_CLIENT_SECRET || existing.clientSecret;
const calendarId = argVal("--calendar-id") || process.env.GOOGLE_CALENDAR_ID || existing.calendarId || "primary";

if (!clientId || !clientSecret) {
  console.error("✗ clientId / clientSecret が見つかりません。");
  console.error("  secrets/google-credentials.json に書くか、--client-id / --client-secret で渡してください。");
  process.exit(1);
}

const authUrl =
  "https://accounts.google.com/o/oauth2/v2/auth?" +
  new URLSearchParams({
    client_id: clientId,
    redirect_uri: REDIRECT,
    response_type: "code",
    scope: SCOPE,
    access_type: "offline",
    prompt: "consent", // refresh token を確実に得るため毎回同意
  });

console.log(`\nscope: ${SCOPE}`);
console.log("ブラウザで同意してください（開かない場合は次のURLを手動で開く）:");
console.log(authUrl + "\n");
exec(`open "${authUrl}"`); // macOS

const server = createServer(async (req, res) => {
  const url = new URL(req.url || "/", REDIRECT);
  const code = url.searchParams.get("code");
  if (!code) {
    res.writeHead(200).end("待機中…");
    return;
  }
  try {
    const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code,
        client_id: clientId,
        client_secret: clientSecret,
        redirect_uri: REDIRECT,
        grant_type: "authorization_code",
      }),
    });
    const data = (await tokenRes.json()) as { refresh_token?: string; error?: string };
    if (!data.refresh_token) {
      throw new Error(`refresh_token が返りませんでした: ${JSON.stringify(data)}`);
    }
    mkdirSync(dirname(CRED), { recursive: true });
    writeFileSync(
      CRED,
      JSON.stringify({ clientId, clientSecret, refreshToken: data.refresh_token, calendarId }, null, 2) + "\n",
    );
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" })
      .end("<h2>✅ 認証完了。このタブを閉じて構いません。</h2>");
    console.log(`✅ refresh token を取得し ${CRED} に保存しました。`);
    console.log("   次: cd server && npm run collect");
    server.close();
    process.exit(0);
  } catch (e) {
    res.writeHead(500).end(String(e));
    console.error("✗", e);
    server.close();
    process.exit(1);
  }
});

server.listen(PORT, () => console.log(`コールバック待機: ${REDIRECT}`));
