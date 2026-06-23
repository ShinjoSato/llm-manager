#!/usr/bin/env -S npx tsx
/**
 * App Store Connect 書き込みレイヤー（ポータブル CLI） — Issue #20
 *
 * ASC API への「可逆な準備作業のみ」を行う単体起動 CLI。
 * ai-manager の web サーバ常駐(:8765)に依存しない。どこからでも `tsx` で起動できる。
 *
 * 【重要・スコープ制約】
 *   審査提出（submit-review / reviewSubmissions）と公開（リリース）は **絶対に実装しない**。
 *   万一自動化が暴走しても審査・公開まで進まない設計。扱うのは可逆操作のみ。
 *
 * 【安全装置】
 *   create / update-metadata / set-build は既定で dry-run。
 *   `--apply` を明示しない限り、対象と差分を表示するだけで POST/PATCH は行わない。
 *   update-metadata では releaseType=MANUAL をセットでき、承認後も手動リリースに固定できる。
 *
 * 認証は既存 core/appstore.ts の loadCredentials / makeJwt をそのまま再利用
 * （環境変数 ASC_KEY_ID / ASC_KEY_PATH / ASC_ISSUER_ID、または secrets/appstore-credentials.json）。
 */
import {
  loadCredentials,
  makeJwt,
  apiGet,
  type Credentials,
} from "./core/appstore.js";

const API = "https://api.appstoreconnect.apple.com";

// ───────────────────────── 引数パース ─────────────────────────

interface Args {
  _: string[]; // 位置引数（サブコマンド等）
  flags: Record<string, string | boolean>;
}

function parseArgs(argv: string[]): Args {
  const _: string[] = [];
  const flags: Record<string, string | boolean> = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) {
        flags[key] = true; // 真偽フラグ
      } else {
        flags[key] = next;
        i++;
      }
    } else {
      _.push(a);
    }
  }
  return { _, flags };
}

function str(flags: Args["flags"], key: string): string | undefined {
  const v = flags[key];
  return typeof v === "string" ? v : undefined;
}

// ───────────────────────── 書き込み HTTP ─────────────────────────

/** ASC API への書き込み（POST / PATCH）。403 など権限不足も読みやすく整形して throw。 */
async function apiWrite(
  token: string,
  method: "POST" | "PATCH",
  path: string,
  body: unknown,
): Promise<any> {
  const url = path.startsWith("http") ? path : API + path;
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    let detail = await res.text();
    try {
      const errs = JSON.parse(detail).errors;
      if (errs?.length) {
        detail = errs
          .map((e: any) => [e.title, e.detail].filter(Boolean).join(": "))
          .join(" / ");
      }
    } catch {
      /* テキストのまま */
    }
    const hint =
      res.status === 403
        ? "（403: API キーのロール不足の可能性。書き込みには App Manager 以上が必要です）"
        : "";
    throw new Error(`API ${res.status}: ${detail.slice(0, 400)} ${hint}`.trim());
  }
  // 204 No Content（relationships PATCH 等）は本文なし
  if (res.status === 204) return null;
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

// ───────────────────────── 共通解決ヘルパー ─────────────────────────

/** bundleId → ASC の appId。core 側の apiGet を再利用（書き込み専用ロジックは持たない）。 */
async function resolveAppId(
  token: string,
  bundleId: string,
): Promise<{ appId: string; appName: string }> {
  const apps =
    (
      await apiGet(
        token,
        `/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}&fields[apps]=name,bundleId`,
      )
    ).data ?? [];
  if (!apps.length) throw new Error(`bundleId に該当するアプリが見つかりません: ${bundleId}`);
  return { appId: apps[0].id, appName: apps[0].attributes?.name ?? "" };
}

/** アプリの appStoreVersion 一覧（書き込み対象の特定に使う）。 */
async function listVersions(token: string, appId: string): Promise<any[]> {
  return (
    (
      await apiGet(
        token,
        `/v1/apps/${appId}/appStoreVersions?limit=20` +
          "&fields[appStoreVersions]=versionString,appStoreState,appVersionState,platform,releaseType,createdDate",
      )
    ).data ?? []
  );
}

/**
 * 操作対象の appStoreVersion を特定する。
 * --version-id 優先。無ければ --version-string + --platform で一致するものを探す。
 */
async function resolveVersion(
  token: string,
  appId: string,
  flags: Args["flags"],
): Promise<any> {
  const versionId = str(flags, "version-id");
  if (versionId) {
    return (
      await apiGet(
        token,
        `/v1/appStoreVersions/${versionId}` +
          "?fields[appStoreVersions]=versionString,appStoreState,appVersionState,platform,releaseType",
      )
    ).data;
  }
  const versions = await listVersions(token, appId);
  const vstr = str(flags, "version-string");
  const platform = (str(flags, "platform") ?? "IOS").toUpperCase();
  const cand = versions.filter((v) => {
    const a = v.attributes ?? {};
    if (vstr && a.versionString !== vstr) return false;
    if (a.platform && a.platform !== platform) return false;
    return true;
  });
  if (!cand.length) {
    throw new Error(
      "対象バージョンを特定できません。--version-id か --version-string（+ --platform）を指定してください。" +
        `\n  現在のバージョン: ${versions.map((v) => `${v.attributes?.versionString}(${v.attributes?.platform},${v.id})`).join(", ") || "なし"}`,
    );
  }
  if (cand.length > 1) {
    throw new Error(
      "対象バージョンが複数一致しました。--version-id で一意に指定してください。" +
        `\n  候補: ${cand.map((v) => `${v.attributes?.versionString}(${v.attributes?.platform},${v.id})`).join(", ")}`,
    );
  }
  return cand[0];
}

// ───────────────────────── dry-run ガード ─────────────────────────

/**
 * 対象と差分を表示し、--apply が無ければ false を返して呼び出し側に書き込みをスキップさせる。
 * すべての書き込みサブコマンドの直前で必ず通す安全装置。
 */
function confirmApply(label: string, payload: unknown, flags: Args["flags"]): boolean {
  console.log(`\n■ 実行予定: ${label}`);
  console.log("  送信ボディ:");
  console.log(
    JSON.stringify(payload, null, 2)
      .split("\n")
      .map((l) => "    " + l)
      .join("\n"),
  );
  if (!flags["apply"]) {
    console.log(
      "\n[dry-run] --apply が無いため実行しません。内容を確認のうえ --apply を付けて再実行してください。",
    );
    return false;
  }
  console.log("\n--apply 指定あり: 実行します。");
  return true;
}

// ───────────────────────── サブコマンド ─────────────────────────

/** create-version: 新規バージョンを作成（POST /v1/appStoreVersions）。可逆（作っただけでは公開されない）。 */
async function cmdCreateVersion(token: string, flags: Args["flags"]) {
  const bundleId = requireFlag(flags, "bundle-id");
  const versionString = requireFlag(flags, "version-string");
  const platform = (str(flags, "platform") ?? "IOS").toUpperCase();
  const { appId, appName } = await resolveAppId(token, bundleId);
  console.log(`対象アプリ: ${appName} (${bundleId}, appId=${appId})`);

  const attributes: Record<string, unknown> = { platform, versionString };
  // releaseType 既定は MANUAL（承認後も手動リリースに固定する安全側の既定）
  const releaseType = (str(flags, "release-type") ?? "MANUAL").toUpperCase();
  attributes.releaseType = releaseType;

  const payload = {
    data: {
      type: "appStoreVersions",
      attributes,
      relationships: { app: { data: { type: "apps", id: appId } } },
    },
  };
  if (!confirmApply(`create-version ${versionString} (${platform}, releaseType=${releaseType})`, payload, flags)) return;
  const res = await apiWrite(token, "POST", "/v1/appStoreVersions", payload);
  console.log(`\n作成完了: appStoreVersion id=${res?.data?.id}`);
}

/** update-metadata: ローカライズのメタデータ（What's New / 説明 等）を PATCH。
 *  releaseType（MANUAL 等）は appStoreVersions 側の属性なので、指定時はそちらも PATCH する。 */
async function cmdUpdateMetadata(token: string, flags: Args["flags"]) {
  const bundleId = requireFlag(flags, "bundle-id");
  const { appId, appName } = await resolveAppId(token, bundleId);
  console.log(`対象アプリ: ${appName} (${bundleId}, appId=${appId})`);
  const version = await resolveVersion(token, appId, flags);
  const versionId = version.id;
  console.log(
    `対象バージョン: ${version.attributes?.versionString} (${version.attributes?.platform}, id=${versionId}, state=${version.attributes?.appStoreState ?? version.attributes?.appVersionState})`,
  );

  // ── (A) releaseType を appStoreVersions 側で更新（公開を手動に固定する安全装置）
  const releaseTypeFlag = str(flags, "release-type");
  if (releaseTypeFlag) {
    const releaseType = releaseTypeFlag.toUpperCase();
    const verPayload = {
      data: { type: "appStoreVersions", id: versionId, attributes: { releaseType } },
    };
    if (confirmApply(`update appStoreVersion releaseType=${releaseType}`, verPayload, flags)) {
      await apiWrite(token, "PATCH", `/v1/appStoreVersions/${versionId}`, verPayload);
      console.log("releaseType を更新しました。");
    }
  }

  // ── (B) ローカライズのテキスト更新
  const locale = str(flags, "locale");
  const whatsNew = str(flags, "whats-new");
  const description = str(flags, "description");
  const keywords = str(flags, "keywords");
  const promotionalText = str(flags, "promotional-text");
  const hasText = whatsNew || description || keywords || promotionalText;
  if (!hasText) {
    if (!releaseTypeFlag) {
      console.log(
        "\n更新する項目がありません。--whats-new / --description / --keywords / --promotional-text / --release-type のいずれかを指定してください。",
      );
    }
    return;
  }
  if (!locale) {
    throw new Error("テキスト更新には --locale（例: ja, en-US）が必要です。");
  }

  // 対象 localization を特定
  const locs =
    (
      await apiGet(
        token,
        `/v1/appStoreVersions/${versionId}/appStoreVersionLocalizations?limit=50` +
          "&fields[appStoreVersionLocalizations]=locale,whatsNew,description,keywords,promotionalText",
      )
    ).data ?? [];
  const loc = locs.find((l: any) => (l.attributes?.locale ?? "").toLowerCase() === locale.toLowerCase());
  if (!loc) {
    throw new Error(
      `locale=${locale} のローカライズが見つかりません。存在する locale: ${locs.map((l: any) => l.attributes?.locale).join(", ") || "なし"}`,
    );
  }

  const attributes: Record<string, unknown> = {};
  if (whatsNew !== undefined) attributes.whatsNew = whatsNew;
  if (description !== undefined) attributes.description = description;
  if (keywords !== undefined) attributes.keywords = keywords;
  if (promotionalText !== undefined) attributes.promotionalText = promotionalText;

  const payload = {
    data: { type: "appStoreVersionLocalizations", id: loc.id, attributes },
  };
  // 現状との差分を見せる
  console.log(`\n現在値 (locale=${locale}):`);
  for (const k of Object.keys(attributes)) {
    const before = (loc.attributes?.[k] ?? "").toString().replace(/\n/g, "\\n").slice(0, 80);
    console.log(`    ${k}: "${before}"`);
  }
  if (!confirmApply(`update-metadata locale=${locale}`, payload, flags)) return;
  await apiWrite(token, "PATCH", `/v1/appStoreVersionLocalizations/${loc.id}`, payload);
  console.log("\nメタデータを更新しました。");
}

/** set-build: 配信ビルドを紐付け（PATCH .../relationships/build）。可逆（差し替え・解除可）。 */
async function cmdSetBuild(token: string, flags: Args["flags"]) {
  const bundleId = requireFlag(flags, "bundle-id");
  const buildId = requireFlag(flags, "build-id");
  const { appId, appName } = await resolveAppId(token, bundleId);
  console.log(`対象アプリ: ${appName} (${bundleId}, appId=${appId})`);
  const version = await resolveVersion(token, appId, flags);
  const versionId = version.id;
  console.log(
    `対象バージョン: ${version.attributes?.versionString} (${version.attributes?.platform}, id=${versionId})`,
  );

  const payload = { data: { type: "builds", id: buildId } };
  if (!confirmApply(`set-build version=${versionId} → build=${buildId}`, payload, flags)) return;
  await apiWrite(
    token,
    "PATCH",
    `/v1/appStoreVersions/${versionId}/relationships/build`,
    payload,
  );
  console.log("\nビルドを紐付けました。");
}

/** status: 既存の読み取りを CLI からも。準備状況の確認用（書き込みなし）。 */
async function cmdStatus(token: string, flags: Args["flags"]) {
  const bundleId = requireFlag(flags, "bundle-id");
  const { appId, appName } = await resolveAppId(token, bundleId);
  console.log(`アプリ: ${appName} (${bundleId}, appId=${appId})\n`);
  const versions = await listVersions(token, appId);
  if (!versions.length) {
    console.log("バージョンなし");
    return;
  }
  console.log("バージョン一覧:");
  for (const v of versions) {
    const a = v.attributes ?? {};
    console.log(
      `  - ${a.versionString} [${a.platform}] state=${a.appStoreState ?? a.appVersionState} releaseType=${a.releaseType ?? "-"} id=${v.id}`,
    );
  }
}

// ───────────────────────── 補助 ─────────────────────────

function requireFlag(flags: Args["flags"], key: string): string {
  const v = str(flags, key);
  if (!v) throw new Error(`--${key} は必須です。`);
  return v;
}

function printHelp() {
  console.log(`App Store Connect 書き込み CLI（可逆な準備作業のみ・審査提出/公開は非対応）

使い方:
  npm run asc -- <subcommand> [options]

サブコマンド:
  status           バージョン一覧と state / releaseType を表示（読み取りのみ）
  create-version   新規バージョンを作成（POST /v1/appStoreVersions）
  update-metadata  ローカライズのメタデータ更新（PATCH appStoreVersionLocalizations）
                   + releaseType も更新可能（appStoreVersions 側に PATCH）
  set-build        配信ビルドを紐付け（PATCH appStoreVersions/{id}/relationships/build）

共通オプション:
  --bundle-id <id>        対象アプリの本番 bundleId（必須）
  --apply                 これが無いと dry-run（送信ボディを表示するだけで実行しない）

バージョン指定（update-metadata / set-build で対象を特定）:
  --version-id <id>       appStoreVersion の id を直接指定（最優先）
  --version-string <ver>  バージョン番号で特定（例: 1.2.0）
  --platform <IOS|...>    プラットフォーム（既定 IOS）

create-version:
  --version-string <ver>  作成するバージョン番号（必須）
  --platform <IOS|...>    既定 IOS
  --release-type <type>   既定 MANUAL（承認後も手動でリリースボタンを押すまで公開されない）

update-metadata:
  --locale <locale>       例: ja, en-US（テキスト更新時は必須）
  --whats-new <text>      What's New
  --description <text>    説明文
  --keywords <text>       キーワード（カンマ区切り）
  --promotional-text <t>  プロモーションテキスト
  --release-type <type>   公開方式（MANUAL を推奨）。テキスト更新と同時/単独どちらも可

set-build:
  --build-id <id>         紐付ける build の id（必須）

認証:
  環境変数 ASC_KEY_ID / ASC_KEY_PATH（個人キー）/ ASC_ISSUER_ID（チームキー）
  または secrets/appstore-credentials.json
  ※書き込みには API キーに App Manager 以上のロールが必要。

例:
  npm run asc -- status --bundle-id indiv.random-talk
  npm run asc -- create-version --bundle-id indiv.random-talk --version-string 1.3.0
  npm run asc -- create-version --bundle-id indiv.random-talk --version-string 1.3.0 --apply
  npm run asc -- update-metadata --bundle-id indiv.random-talk --version-string 1.3.0 \\
      --locale ja --whats-new "不具合を修正しました" --release-type MANUAL --apply
  npm run asc -- set-build --bundle-id indiv.random-talk --version-string 1.3.0 --build-id <buildId> --apply
`);
}

// ───────────────────────── エントリポイント ─────────────────────────

async function main() {
  const { _, flags } = parseArgs(process.argv.slice(2));
  const sub = _[0];

  if (!sub || flags["help"] || sub === "help") {
    printHelp();
    return;
  }

  // 認証は help の後に解決（--help は鍵が無くても表示できるように）
  let creds: Credentials | null;
  try {
    creds = loadCredentials();
  } catch (e) {
    console.error(`認証情報エラー: ${String(e)}`);
    process.exit(1);
  }
  if (!creds) {
    console.error(
      "認証情報が見つかりません。ASC_KEY_ID / ASC_KEY_PATH を設定するか secrets/appstore-credentials.json を用意してください。",
    );
    process.exit(1);
  }
  const token = makeJwt(creds);

  try {
    switch (sub) {
      case "status":
        await cmdStatus(token, flags);
        break;
      case "create-version":
        await cmdCreateVersion(token, flags);
        break;
      case "update-metadata":
        await cmdUpdateMetadata(token, flags);
        break;
      case "set-build":
        await cmdSetBuild(token, flags);
        break;
      // 提出/公開は意図的に未実装（スコープ外）。
      case "submit-review":
      case "release":
      case "publish":
        console.error(
          `「${sub}」は意図的に未対応です。審査提出・公開は App Store Connect 上で人間が手動で行ってください。`,
        );
        process.exit(2);
        break;
      default:
        console.error(`未知のサブコマンド: ${sub}\n`);
        printHelp();
        process.exit(2);
    }
  } catch (e) {
    console.error(`\nエラー: ${e instanceof Error ? e.message : String(e)}`);
    process.exit(1);
  }
}

main();
