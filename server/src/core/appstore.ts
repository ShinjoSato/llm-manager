import { readFileSync, existsSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { sign as cryptoSign } from "node:crypto";
import { ROOT, APPS_TSV, CRED_JSON } from "./paths.js";
import { readTsv } from "./tsv.js";
import type {
  AppRecord, AppVersion, ReviewSubmission, Reviews, AppBuild, MetricCategory,
} from "../../../shared/types.js";

const API = "https://api.appstoreconnect.apple.com";

const STATE_LABELS: Record<string, string> = {
  PREPARE_FOR_SUBMISSION: "提出準備中",
  READY_FOR_REVIEW: "審査提出可",
  WAITING_FOR_REVIEW: "審査待ち",
  IN_REVIEW: "審査中",
  PENDING_DEVELOPER_RELEASE: "承認済み・リリース待ち",
  PENDING_APPLE_RELEASE: "承認済み・Apple公開待ち",
  PROCESSING_FOR_APP_STORE: "配信処理中",
  READY_FOR_SALE: "配信中",
  READY_FOR_DISTRIBUTION: "配信中",
  REJECTED: "🔴 リジェクト",
  METADATA_REJECTED: "🔴 メタデータ却下",
  DEVELOPER_REJECTED: "取り下げ（開発者）",
  INVALID_BINARY: "バイナリ不正",
  DEVELOPER_REMOVED_FROM_SALE: "販売停止",
  REPLACED_WITH_NEW_VERSION: "新バージョンに置換",
};

const SUBMISSION_LABELS: Record<string, string> = {
  READY_FOR_REVIEW: "提出可",
  WAITING_FOR_REVIEW: "審査待ち",
  IN_REVIEW: "審査中",
  UNRESOLVED_ISSUES: "🔴 未解決の指摘",
  CANCELING: "取消中",
  COMPLETING: "完了処理中",
  COMPLETE: "完了",
};

const BUILD_STATE_LABELS: Record<string, string> = {
  PROCESSING: "処理中",
  FAILED: "🔴 失敗",
  INVALID: "🔴 無効",
  VALID: "利用可",
};

export interface Credentials {
  keyId: string;
  issuerId: string | null;
  keyPath: string;
}

/** 環境変数 → secrets/appstore-credentials.json の順で解決。無ければ null。 */
export function loadCredentials(): Credentials | null {
  let keyId = process.env.ASC_KEY_ID;
  let issuer = process.env.ASC_ISSUER_ID;
  let keyPath = process.env.ASC_KEY_PATH;
  if (!(keyId && keyPath) && existsSync(CRED_JSON)) {
    const c = JSON.parse(readFileSync(CRED_JSON, "utf-8"));
    keyId = keyId || c.keyId;
    issuer = issuer || c.issuerId;
    keyPath = keyPath || c.keyPath;
  }
  if (!keyId || !keyPath) return null; // 個人キーは issuerId 不要
  const resolved = isAbsolute(keyPath) ? keyPath : join(ROOT, keyPath);
  if (!existsSync(resolved)) throw new Error(`.p8 鍵が見つかりません: ${resolved}`);
  return { keyId, issuerId: issuer || null, keyPath: resolved };
}

function b64url(buf: Buffer): string {
  return buf.toString("base64url");
}

/** ES256 JWT。Node の ieee-p1363 で raw 署名を直接得る（openssl/DER 変換が不要）。 */
export function makeJwt(creds: Credentials): string {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: creds.keyId, typ: "JWT" };
  const payload: Record<string, unknown> = {
    iat: now,
    exp: now + 15 * 60, // 上限20分・余裕を見て15分
    aud: "appstoreconnect-v1",
  };
  if (creds.issuerId) payload.iss = creds.issuerId; // チームキー
  else payload.sub = "user"; // 個人キー（Issuer ID 無し）

  const signingInput =
    b64url(Buffer.from(JSON.stringify(header))) + "." +
    b64url(Buffer.from(JSON.stringify(payload)));
  const pem = readFileSync(creds.keyPath, "utf-8");
  const sig = cryptoSign("sha256", Buffer.from(signingInput), {
    key: pem,
    dsaEncoding: "ieee-p1363",
  });
  return signingInput + "." + b64url(sig);
}

async function apiGet(
  token: string, path: string, accept = "application/json",
): Promise<any> {
  const url = path.startsWith("http") ? path : API + path;
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${token}`, Accept: accept },
  });
  if (!res.ok) {
    let detail = await res.text();
    try {
      const errs = JSON.parse(detail).errors;
      if (errs?.length) detail = errs.map((e: any) => e.detail || e.title || "").join("; ");
    } catch { /* テキストのまま */ }
    throw new Error(`API ${res.status}: ${detail.slice(0, 300)}`);
  }
  return res.json();
}

async function safe<T>(fn: () => Promise<T>, fallback: T): Promise<T> {
  try {
    return await fn();
  } catch (e) {
    if (fallback && typeof fallback === "object") {
      return { ...(fallback as object), error: String(e) } as T;
    }
    return fallback;
  }
}

async function fetchVersions(token: string, appId: string): Promise<AppVersion[]> {
  const data = (await apiGet(
    token,
    `/v1/apps/${appId}/appStoreVersions?limit=5` +
      "&fields[appStoreVersions]=versionString,appStoreState,appVersionState,platform,createdDate",
  )).data ?? [];
  return data.map((v: any) => {
    const a = v.attributes ?? {};
    const state = a.appStoreState || a.appVersionState || "UNKNOWN";
    return {
      version: a.versionString ?? null,
      platform: a.platform ?? null,
      state,
      stateLabel: STATE_LABELS[state] ?? state,
      createdDate: (a.createdDate || "").slice(0, 10),
    };
  });
}

async function fetchReviewSubmissions(token: string, appId: string): Promise<ReviewSubmission[]> {
  const data = (await apiGet(
    token,
    `/v1/apps/${appId}/reviewSubmissions?limit=10` +
      "&fields[reviewSubmissions]=state,platform,submittedDate",
  )).data ?? [];
  const subs: ReviewSubmission[] = data.map((s: any) => {
    const a = s.attributes ?? {};
    const st = a.state || "UNKNOWN";
    return {
      state: st,
      stateLabel: SUBMISSION_LABELS[st] ?? st,
      platform: a.platform ?? null,
      submittedDate: (a.submittedDate || "").slice(0, 10),
    };
  });
  subs.sort((x, y) => (y.submittedDate || "").localeCompare(x.submittedDate || ""));
  return subs.slice(0, 5);
}

async function fetchReviews(token: string, appId: string, limit = 5): Promise<Reviews> {
  const res = await apiGet(
    token,
    `/v1/apps/${appId}/customerReviews?sort=-createdDate&limit=${limit}` +
      "&fields[customerReviews]=rating,title,body,reviewerNickname,createdDate,territory",
  );
  const items = (res.data ?? []).map((r: any) => {
    const a = r.attributes ?? {};
    return {
      rating: a.rating ?? null,
      title: a.title || "",
      body: (a.body || "").replace(/\n/g, " ").slice(0, 160),
      nickname: a.reviewerNickname || "",
      territory: a.territory || "",
      createdDate: (a.createdDate || "").slice(0, 10),
    };
  });
  const rated = items.map((i: any) => i.rating).filter((r: any) => typeof r === "number");
  const avg = rated.length
    ? Math.round((rated.reduce((s: number, r: number) => s + r, 0) / rated.length) * 10) / 10
    : null;
  return { total: res.meta?.paging?.total ?? null, avgOfRecent: avg, items };
}

async function fetchBuilds(token: string, appId: string, limit = 5): Promise<AppBuild[]> {
  // builds は sort 非対応 → クライアント側で uploadedDate 降順
  const data = (await apiGet(
    token,
    `/v1/apps/${appId}/builds?limit=20` +
      "&fields[builds]=version,processingState,expired,uploadedDate,expirationDate",
  )).data ?? [];
  const out = data.map((b: any) => {
    const a = b.attributes ?? {};
    const st = a.processingState || "UNKNOWN";
    return {
      build: a.version ?? null,
      state: st,
      stateLabel: BUILD_STATE_LABELS[st] ?? st,
      expired: !!a.expired,
      uploadedDate: (a.uploadedDate || "").slice(0, 10),
      _sort: a.uploadedDate || "",
    };
  });
  out.sort((x: any, y: any) => (y._sort as string).localeCompare(x._sort as string));
  return out.slice(0, limit).map(({ _sort, ...rest }: any) => rest);
}

async function fetchMetrics(token: string, appId: string): Promise<{ categories: MetricCategory[] }> {
  // perfPowerMetrics は専用 Accept が必須。未リリースだと空が普通。
  const res = await apiGet(
    token, `/v1/apps/${appId}/perfPowerMetrics`,
    "application/vnd.apple.xcode-metrics+json",
  );
  const cats: MetricCategory[] = [];
  for (const prod of res.productData ?? []) {
    for (const cat of prod.metricCategories ?? []) {
      const metrics = cat.metrics ?? [];
      if (!metrics.length) continue;
      const m0 = metrics[0];
      const unit = m0.unit?.displayName ?? "";
      let sample: string | null = null;
      for (const ds of m0.datasets ?? []) {
        const pts = ds.points ?? [];
        const p50 = pts.find((p: any) => p.percentile === 50) ?? pts[0];
        if (p50) { sample = `${p50.value}${unit}`; break; }
      }
      cats.push({ category: cat.identifier ?? "?", metric: m0.identifier ?? null, sample });
    }
  }
  return { categories: cats };
}

export async function appRecord(token: string, bundleId: string): Promise<AppRecord> {
  const apps = (await apiGet(
    token, `/v1/apps?filter[bundleId]=${bundleId}&fields[apps]=name,bundleId`,
  )).data ?? [];
  if (!apps.length) {
    return { bundleId, error: "該当アプリが見つかりません" } as AppRecord;
  }
  const app = apps[0];
  const appId = app.id;
  const [versions, reviewSubmissions, reviews, builds, metrics] = await Promise.all([
    safe(() => fetchVersions(token, appId), [] as AppVersion[]),
    safe(() => fetchReviewSubmissions(token, appId), [] as ReviewSubmission[]),
    safe(() => fetchReviews(token, appId), { total: null, avgOfRecent: null, items: [] } as Reviews),
    safe(() => fetchBuilds(token, appId), [] as AppBuild[]),
    safe(() => fetchMetrics(token, appId), { categories: [] }),
  ]);
  return {
    appName: app.attributes?.name ?? "",
    appId,
    bundleId,
    versions,
    reviewSubmissions,
    reviews,
    builds,
    metrics,
  };
}

/** 登録アプリ全件（または指定名）の状況を {projectName: AppRecord} で返す。認証なしは {}。 */
export async function collectAppStore(only?: string): Promise<Record<string, AppRecord>> {
  const creds = loadCredentials();
  if (!creds) return {};
  let apps = readTsv(APPS_TSV).filter((r) => r.length >= 2).map((r) => [r[0], r[1]] as const);
  if (only) apps = apps.filter(([name]) => name === only);
  if (!apps.length) return {};
  const token = makeJwt(creds);
  const result: Record<string, AppRecord> = {};
  for (const [name, bundleId] of apps) {
    try {
      result[name] = await appRecord(token, bundleId);
    } catch (e) {
      result[name] = { bundleId, error: String(e) } as AppRecord;
    }
  }
  return result;
}
