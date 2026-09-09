# ai-manager

Claude Code を「マネージャー」として運用するためのプロジェクト。
他プロジェクトの管理・Google カレンダー連携・スプレッドシートでの勉強管理を担う。

## 役割

私（Claude）はこのリポジトリにおいて、複数の対象を横断的に把握・調整する**マネージャー**として振る舞う。
ユーザーから依頼を受けたら、まず関連する登録簿・データを確認してから動く。

## 運用ルール（重要）

- **言語**: 日本語でやり取り・応答する。ドキュメント・コメントも日本語を基本とする。
- **「開発状況を確認して」= GitHub Project ボードを見る**: ユーザーが「開発状況を確認」「○○の状況」と言ったら、まず GitHub Project（ボード）を確認する。ローカル git status や PR 一覧は主役にしない（補足としてなら可）。`./scripts/board.sh <name>` を使う。
- **記録はこのプロジェクト内に残す**: マネジメントに関わるルール・方針・知見は永続メモリではなく ai-manager 内（CLAUDE.md や `docs/` 等）に記載する。それがこのプロジェクトの目的。

## 機能と現状

| 機能 | 状態 | 場所 |
|------|------|------|
| 他プロジェクト管理 | 着手中（手動運用） | `projects/`, `scripts/status.sh` |
| データ中核 + API（HTTP/MCP） | 稼働（TypeScript） | `server/` |
| 統合ダッシュボード（React） | 稼働 | `web/` |
| App Store 連携 | 稼働（要 API キー設定） | `server/src/core/appstore.ts` |
| Google カレンダー連携 | 稼働（要 OAuth 設定）／会話は claude.ai MCP | `server/src/core/calendar.ts` |
| スプレッドシート勉強管理 | 未着手 | - |
| claude-deck（Claude Code 司令塔アプリ） | PoC（Swift/macOS・ビルド可） | `desktop/` |
| Claude Code セッション監視（リアルタイム） | 稼働（TypeScript・独立プロセス） | `monitor/` |

## 他プロジェクト管理

- 管理対象は `projects/registry.tsv`（TSV）に登録する。1行1プロジェクト。
- 状況確認は `./scripts/status.sh`（`--all` で paused/archived も、`<name>` で個別）。
- **管理対象の追加依頼を受けたら**: `projects/registry.tsv` に行を追記する。パスは絶対パスで、status は active/paused/archived のいずれか。
- 兄弟プロジェクトは `/Users/shinjo/project/` 配下にある。

### 管理対象（2026-06-04 時点）
- **mirio** — 中心プロダクト（develop）。
- **sandora** — develop。
- **infra** — インフラ構成。mirio-prod の deploy などを含む。
- **blog** — main。Mirio 関連ページを扱う。
- infra / blog は mirio に関連する作業を含むため、mirio の動きと連動して見ると良い。

### GitHub Project（ボード）連携
- 管理対象とボードの紐づけは `projects/github-projects.tsv`。
- ボード状況は `./scripts/board.sh`（`<name>` で個別、`--done` で完了分も表示）。
- 前提: `gh` CLI 認証済み（`ShinjoSato`、`project` スコープ）。ステータスは Todo / In Progress / Debug / Done。
- 紐づき: sandora→Project #3 (random_talk) / mirio→Project #4 (ailovei) / overview→Project #5（横断・複数リポジトリ包括）。
- **infra は専用ボード未作成**。横断作業は overview(#5) で追う。専用ボードを作ったら `github-projects.tsv` に追記する。
- overview はステータスが Todo / In Progress / **Review** / Done（Debug ではない）。board.sh は未知ステータスにも対応済み。

## アーキテクチャ（TypeScript フルスタック）

データ取得を「**1つのデータ中核**」にまとめ、**HTTP（React 用）と MCP（Claude Code 用）の二口**で公開する構成。型は `shared/types.ts` を server/web で共有。

```
shared/types.ts          ドメイン型（server と web で共有）
server/                  TypeScript バックエンド（Node 24 / tsx 実行）
  src/core/              取得ロジック。gh/git/App Store Connect。フレームワーク非依存
    paths/proc/tsv/git/boards/appstore/state/collect
  src/http/server.ts     HTTP/JSON API（Hono）。web/dist も配信
  src/mcp/server.ts      MCP サーバー（stdio）。Claude がツールとして直接呼ぶ
  src/cli.ts             収集して data/dashboard.json に保存（`npm run collect`）
web/                     React + Vite + TypeScript + Tailwind v4（ダークコマンドセンター）
  src/components/        ui(共通: Card/Badge/StatCard/ProgressRing) / StatBar(KPI) /
                         Highlights / ProjectSummary / AppStoreCard / PullRequests / FocusNotes / LocalChanges
  src/styles.css         Tailwind v4（@theme トークン + @layer components）。アイコンは lucide-react
scripts/                 補助シェル（dev.sh で API+Web 同時起動 / board.sh / status.sh）
```

データ実体（`projects/*.tsv`・`data/*.json`・`secrets/`）は言語非依存でそのまま流用。`data/dashboard.json` が生成物、`data/manager-state.json` が手動レイヤー（要注目・今日の重点に反映）。

### 起動コマンド
- **開発（API + Web を同時起動・推奨）**: `./scripts/dev.sh`
  - API(:8765) と Vite(:5173) を1コマンドで起動。`/api` は :8765 にプロキシ。ホットリロード有効。
  - Ctrl-C で両方まとめて停止（`kill 0`）。依存未インストールなら自動で `npm install`。
  - ブラウザで http://localhost:5173 を開く。
- **本番配信（サーバー1つで完結）**: `cd web && npm run build` → `cd ../server && npm run http` → http://localhost:8765
  - `web/dist` があれば HTTP サーバーが React も同一ポートで配信する。
- **データだけ再生成**: `cd server && npm run collect`
- **セッション監視（monitor・独立プロセス）**: `cd monitor && npm install && npm start` → http://localhost:8766
- 依存は各ディレクトリで `npm install`（server / web）。Node 24 系。

### Claude Code 連携（MCP）— ここが要
- `.mcp.json` で MCP サーバーを登録済み（`ai-manager`）。Claude Code はツールとして直接呼べる:
  - `get_dashboard` / `refresh_dashboard` / `get_app_status` / `list_projects`
  - `get_state` / `set_focus_notes` / `add_pin`（手動レイヤーの読み書き）
  - `list_calendar_events` / `create_calendar_event`（Google カレンダー）
- 「今日の重点」は MCP の `set_focus_notes`、`data/manager-state.json` 直接編集、Web 上の編集のいずれでも更新できる（全て同じ JSON に反映）。

### HTTP API
- `GET /api/health` / `GET /api/dashboard` / `POST /api/refresh`
- `GET /api/state` / `POST /api/state` / `GET /api/appstore/:name?`

### 運用方針 / 既知の制約
- 現状は**手動運用**。ユーザーが話しかけたときに動く。定期実行などの自動化は未導入（将来検討）。
- 停滞検知（In Progress のN日放置）は gh の item-list に更新日時が無いため未実装。GraphQLで `updatedAt` を取れば追加可能（将来）。

## App Store 連携

mirio / sandora など iOS アプリの状況を App Store Connect API から取得する。実装は `server/src/core/appstore.ts`（Node 標準のみ。JWT は `crypto.sign(..., {dsaEncoding:'ieee-p1363'})` で raw 署名、API は `fetch`）。

- 対象アプリ: `projects/appstore.tsv`（name <TAB> bundleId。本番 bundleId を書く）。
  - mirio = `indiv.ailovei`（staging の `indiv.ailovei.staging` ではない）/ sandora = `indiv.random-talk`。
- 取得: `collectAppStore(only?)`。`collect()` が呼んで各プロジェクトに `appstore` を付与。MCP の `get_app_status` でも単体取得可。
- ダッシュボード表示: Web の `AppStoreCard` に「📱 App Store」カード。REJECT / UNRESOLVED / FAILED 系は赤バッジ、配信中/完了/利用可は緑。

### 取得しているデータ（`appRecord`）
| 種類 | キー | エンドポイント | 備考 |
|------|------|----------------|------|
| 審査ステータス | `versions` | `appStoreVersions` | バージョンの `appStoreState` |
| 審査提出フロー | `reviewSubmissions` | `reviewSubmissions` | 提出単位の state（履歴も。`appStoreState` の新概念） |
| カスタマーレビュー/評価 | `reviews` | `customerReviews` | 直近数件＋総数＋取得分の平均★。**文章付きレビューのみ**返る（★だけは含まれない） |
| TestFlight ビルド | `builds` | `builds` | 最新ビルドの processingState（**sort 非対応**→クライアント側で並べ替え） |
| パフォーマンス/電力指標 | `metrics` | `perfPowerMetrics` | **Accept: `application/vnd.apple.xcode-metrics+json`** 必須。未リリース/小規模だと空が普通 |

- 各セクションは `safe()` で保護。1つが失敗（権限不足等）しても他は取得継続。
- **取れないもの**: リジェクト文面（Guideline の具体指摘）は Resolution Center 側で API では基本取れない。売上/Analytics は非同期レポート（未実装）。

### セットアップ（要 API キー）— 設定済み（個人キー）
1. App Store Connect → Users and Access → Integrations で API キー発行。`.p8`・Key ID（Issuer ID は個人キーでは無し）を入手。
2. 認証情報を設定（どちらか。環境変数が優先）:
   - `secrets/appstore-credentials.json`（`secrets/*.example.json` をコピー。`keyPath` はプロジェクト相対も可）
   - 環境変数 `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_PATH`
3. `cd server && npm run collect` で疎通確認（または MCP `get_app_status`）。

**キーの種類に注意**: チームキー(Team Key)と個人キー(Individual Key)で必要項目が違う。
- チームキー → Key ID + Issuer ID + .p8。JWT は `iss` を使う。Issuer ID は Team Keys 画面上部に表示。
- 個人キー → Key ID + .p8 のみ（**Issuer ID は存在しない**）。JWT は `iss` の代わりに `sub:"user"`。
- コードは issuerId の有無で自動分岐するので、個人キーなら issuerId を空にする。

## Google カレンダー連携

2つの入口がある。

1. **会話の中**（設定不要）: claude.ai の Google Calendar MCP。ユーザーが `/mcp` → 「claude.ai Google Calendar」で認証すれば、会話内で予定の取得・作成が可能。claude.ai 認証依存なのでヘッドレスのサーバーからは使えない。
2. **ダッシュボード常設**（自前連携）: `server/src/core/calendar.ts`。OAuth refresh token でアクセストークンを取得し Calendar API を叩く。`collect()` が今後7日分の予定を取り `dashboard.json` の `calendar` に載せる → Web の `CalendarCard`。MCP の `list_calendar_events` / `create_calendar_event` も提供。

### セットアップ（②常設の有効化・要 OAuth）
1. Google Cloud Console で **Calendar API 有効化** → **OAuth クライアント(デスクトップ)** 作成。
2. scope `https://www.googleapis.com/auth/calendar` で同意し **refresh token** を取得（OAuth Playground 等）。
3. `secrets/google-credentials.json`（`*.example.json` をコピー）に clientId/clientSecret/refreshToken/calendarId を記入。または環境変数 `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` / `GOOGLE_REFRESH_TOKEN` / `GOOGLE_CALENDAR_ID`。
4. `cd server && npm run collect` で予定が `calendar` に入る。未設定なら `calendar: null`（カードは非表示）で安全に no-op。

## claude-deck（Claude Code 司令塔アプリ）

`desktop/` にある Swift/macOS ネイティブアプリ。プロジェクトごとに `claude`（Claude Code）を端末として同時起動する。SwiftTerm（VT100 エミュレータ + PTY ホスト）使用。詳細は `desktop/README.md`。

- **配置**: ai-manager 内 `desktop/`（SPM 実行ファイル `claude-deck`）。`registry.tsv` に管理対象として登録済み。
- **プロジェクト一覧（左欄）**: 各行は名称 + フルパス表示。ユーザーが自由に追加（「+」でフォルダ選択）・削除（「−」/Delete/右クリック）でき、`~/Library/Application Support/claude-deck/projects.json` に永続化。起動はダブルクリック/Enter。初回のみ `registry.tsv` から取り込む（取り込みボタンでマージ可）。
- **メイン領域**: 開いたセッションをタブではなく**タイル状グリッドで同時表示**。各ペインに見出し + ✕（個別クローズ）。同一プロジェクトはフォーカスのみで重複起動しない。
- **ペイン内 Claude Code / GitHub 切替**: `github-projects.tsv` にマッピングがあるプロジェクトは、ペイン見出しのセグメントで GitHub Project 画面に切替可能（無いものは切替を出さない）。GitHub 画面は Issue をステータス別（Todo/In Progress/Debug/Review/Done）にグループ表示し、行クリックで GitHub を開く。取得は `gh project item-list --format json`（gh 認証 + project スコープ前提）。`gh` 出力形状は実機検証済み。
- **ペイン内「Xcodeで開く」ボタン**: プロジェクト配下（浅い範囲・`ios/` 等のサブディレクトリ含む）に `.xcworkspace`/`.xcodeproj` があるペインだけ、見出しに🔨ボタンを出す（`TerminalPaneViewController.findXcodeProject`）。押すと `NSWorkspace.open` で Xcode の GUI が開く（実行＝Cmd+R はユーザー操作）。iOS/Mac アプリの動作確認用。`.xcworkspace` 優先・最も浅い階層を選択。SPM のみ（claude-deck 自身等）は非表示。ワンクリックでのシミュレータ自動実行（`xcodebuild`/`simctl`）は将来。
- **設計の絶対方針（料金事故ゼロ）**: 子プロセスの環境から `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` を必ず除去して `claude` を起動する。API 課金経路を作らないため、Max 枠の上限に達しても課金は発生しない（待つだけ）。**headless（`claude -p` / Agent SDK）の起動口は設けない方針**。
- **上限到達で強制終了**: PTY 出力を監視し「上限到達」文言を検知したらセッションを `terminate()`。検知文言は要・実機検証（`ClaudeTerminalView.swift` の `limitPhrases`）。正確な残量 API は無いため事後トリガー方式。
- **ビルド/実行**: `cd desktop && swift build` / `swift run`。ビルドは Swift 6.3 / Xcode 26.5 で確認済み。`.app` 署名・配布は未対応（PoC）。

## Claude Code セッション監視（monitor）

複数リポジトリで同時に走っている Claude Code の状況を 1 画面でリアルタイムに見る（`monitor/`・:8766）。server(:8765) / web とは独立プロセスで、読み取り専用。詳細は `monitor/README.md`。

- **在庫層**（3秒）: `~/.claude/sessions/<pid>.json` + `kill(pid,0)` で稼働セッション一覧を復元。
- **実況層**（250ms）: `~/.claude/projects/<slug>/<sessionId>.jsonl` の末尾差分から実行中ツール・ブランチ・作業内容・トークン量を取る。`ai-title` は先頭寄りにしか出ないため初回だけ広く遡る（`primeMeta`）。
- **フック層**（任意）: `POST /hook`。**「なぜ止まっているか」（権限待ち・入力待ち・APIエラー）はログに一切残らない**ので、これはフックでしか取れない。設定は `monitor/README.md` のスニペットを `~/.claude/settings.json` に入れる（**`async: true` 必須**。付けないと全プロジェクトの応答をブロックする）。
- UI は `monitor/public/index.html`（ビルド不要・SSE を EventSource で購読）。
- 制約: macOS ローカルのセッションのみ（クラウドセッションは映らない）。ログの粒度はターン／ツール単位で、生成中テキストは流れない。

## スプレッドシート勉強管理

- 未着手。着手時に方針をここに追記する。

## メモ
- このディレクトリ自体はまだ git 管理されていない。`.gitignore` は用意済み（`secrets/*`・`node_modules/`・`web/dist/`・生成 JSON を除外）。
- 秘密情報は `secrets/`（`.p8` 鍵・`appstore-credentials.json`）。中身は git 追跡外（README とテンプレのみ追跡）。
- 旧 Python 実装（collect.py / appstore.py 等）は TS 版へ全面移行済みで削除済み。実装は `server/` (TS) 側に一本化。
