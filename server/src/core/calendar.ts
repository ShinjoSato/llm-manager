import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { ROOT } from "./paths.js";
import type { CalendarData, CalendarEvent } from "../../../shared/types.js";

// 認証情報（秘密）の置き場。App Store と同じく secrets/ に置く。
//   secrets/google-credentials.json
//   { "clientId": "...", "clientSecret": "...", "refreshToken": "...", "calendarId": "primary" }
// 環境変数 GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET / GOOGLE_REFRESH_TOKEN / GOOGLE_CALENDAR_ID でも可。
const CRED_JSON = join(ROOT, "secrets", "google-credentials.json");

interface Credentials {
  clientId: string;
  clientSecret: string;
  refreshToken: string;
  calendarId: string;
}

export function loadCredentials(): Credentials | null {
  let clientId = process.env.GOOGLE_CLIENT_ID;
  let clientSecret = process.env.GOOGLE_CLIENT_SECRET;
  let refreshToken = process.env.GOOGLE_REFRESH_TOKEN;
  let calendarId = process.env.GOOGLE_CALENDAR_ID;
  if (!(clientId && clientSecret && refreshToken) && existsSync(CRED_JSON)) {
    const c = JSON.parse(readFileSync(CRED_JSON, "utf-8"));
    clientId = clientId || c.clientId;
    clientSecret = clientSecret || c.clientSecret;
    refreshToken = refreshToken || c.refreshToken;
    calendarId = calendarId || c.calendarId;
  }
  if (!clientId || !clientSecret || !refreshToken) return null;
  return { clientId, clientSecret, refreshToken, calendarId: calendarId || "primary" };
}

/** refresh token から短命のアクセストークンを取得。 */
async function accessToken(c: Credentials): Promise<string> {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: c.clientId,
      client_secret: c.clientSecret,
      refresh_token: c.refreshToken,
      grant_type: "refresh_token",
    }),
  });
  if (!res.ok) throw new Error(`token ${res.status}: ${(await res.text()).slice(0, 200)}`);
  return ((await res.json()) as { access_token: string }).access_token;
}

function toEvent(e: any): CalendarEvent {
  const allDay = !!e.start?.date;
  return {
    id: e.id,
    title: e.summary || "(無題)",
    start: e.start?.dateTime || e.start?.date || "",
    end: e.end?.dateTime || e.end?.date || "",
    allDay,
    location: e.location || "",
    url: e.htmlLink || null,
  };
}

/** これから rangeDays 日分の予定を取得。認証情報が無ければ null（= 未設定）。 */
export async function collectCalendar(rangeDays = 30): Promise<CalendarData | null> {
  const creds = loadCredentials();
  if (!creds) return null;
  try {
    const token = await accessToken(creds);
    const now = new Date();
    const timeMin = now.toISOString();
    const timeMax = new Date(now.getTime() + rangeDays * 86400_000).toISOString();
    const url =
      `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(creds.calendarId)}/events` +
      `?timeMin=${encodeURIComponent(timeMin)}&timeMax=${encodeURIComponent(timeMax)}` +
      `&singleEvents=true&orderBy=startTime&maxResults=20`;
    const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
    if (!res.ok) throw new Error(`events ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const data = (await res.json()) as { items?: any[] };
    return { events: (data.items ?? []).map(toEvent), rangeDays };
  } catch (e) {
    return { events: [], rangeDays, error: String(e) };
  }
}

/** 予定を作成。MCP の create_event 用。start/end は ISO 文字列。 */
export async function createEvent(args: {
  title: string;
  start: string;
  end: string;
  location?: string;
}): Promise<CalendarEvent> {
  const creds = loadCredentials();
  if (!creds) throw new Error("Google カレンダー未設定（secrets/google-credentials.json）");
  const token = await accessToken(creds);
  const url = `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(creds.calendarId)}/events`;
  const res = await fetch(url, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      summary: args.title,
      location: args.location,
      start: { dateTime: args.start },
      end: { dateTime: args.end },
    }),
  });
  if (!res.ok) throw new Error(`create ${res.status}: ${(await res.text()).slice(0, 200)}`);
  return toEvent(await res.json());
}
