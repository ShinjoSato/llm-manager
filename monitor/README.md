# monitor — Claude Code セッションのリアルタイム集約

複数リポジトリで同時に走っている Claude Code の状況を集約し、API と SSE で配る**独立したプロセス**。
読み取り専用で `:8766` で動く。画面は持たず、mac アプリ claude-deck がこれに接続して表示する
（claude-deck は monitor が動いていなければ自動で起動する）。

```bash
cd monitor
npm install
npm start
# → http://localhost:8766/api/health
```

**常に localhost 限定**（`127.0.0.1` にのみ bind・認証なし）。セッションへ書き込む口があるため外には出さない。
他の端末から見たい場合も穴を開けず、SSH のポートフォワード等で繋ぐ。

セッションから読むのは記録だけ。こちらから行うのは「伝言を 1 通送る」ことと、
Channels を載せたセッションの「権限確認に答える」ことの 2 つ。
伝言は受信側で**別セッションからのメッセージ**として扱われ、指示や承認にはならない
（設定変更・スラッシュコマンドの実行も不可）。権限確認は別の経路で、**手元（ループバック）からだけ**答えられる。

### 開発時（ホットリロード）

```bash
npm run dev                 # API :8766（tsx watch）
```

## 何を見ているか

Claude Code がローカルに残す記録を 3 層で集約する。

| 層 | 経路 | 取れるもの | 遅延 |
|---|---|---|---|
| 在庫 | `~/.claude/sessions/<pid>.json` + `kill(pid,0)` | 稼働中セッション一覧・cwd・起動時刻 | 3 秒 |
| 実況 | `~/.claude/projects/<slug>/<sessionId>.jsonl` の末尾差分 | 実行中ツール・ブランチ・作業内容・トークン量 | 250ms |
| 状態 | フックからの `POST /hook` | 入力待ち・権限待ち・API エラー・完了 | 即時 |
| 残量 | `data/claude-usage.json`（statusLine が書く） | 5時間 / 7日間ウィンドウの使用率・リセット時刻 | 3 秒 |

**在庫層と実況層は設定不要**で、monitor を起動するだけで全セッションが並ぶ。
フック層は任意だが、**「なぜ止まっているか」はログに残らない**ため、これを入れると精度が上がる（下記）。

### 稼働中かどうかの判定

**経過時間では測らない。** Claude Code はモデルが考えている間・長いツールの実行中・サブエージェントが
動いている間、親のログに何も書かないため、実際に稼働していても数分間無音になる。代わりに
**ログがどう終わっているか**で見る。

| ログの最後 | 意味 | 判定 |
|---|---|---|
| `tool_use` を含む assistant | ツール実行中 | 稼働中 |
| `user`（プロンプト送信 / tool_result） | 次はモデルの番 | 稼働中 |
| テキストのみの assistant | 応答完了 | 待機 |

ただし中断やクラッシュで `tool_use` が最後のまま残ることがあるので、10 分を超えて無音なら待機に落とす。
thinking だけの assistant 行では判定を変えない（応答が終わったとは限らないため）。

**サブエージェントも見る。** バックグラウンドの `Agent` を起動すると、作業は
`<sessionId>/subagents/*.jsonl` にだけ書かれ、**親は応答を終えて入力待ちになる**。
親のログだけを見ていると「待機」に見えるので、サブエージェントのログが 3 分以内に
更新されていればそのセッションは稼働中として扱い、`agents` に載せる（claude-deck はステージに並べる）。

状態の優先順位は「ログ上の活動がフック通知より新しければログを信じる」。逆にフックより古いログ行では
「権限待ち」を解除しない（古い行で待ち状態を消さないため）。終了したセッションは 5 分間「終了」として残す。

## フック連携（任意・精度向上）

`~/.claude/settings.json`（ユーザーレベル）に入れると**全プロジェクトに一括で効く**。
`async: true` を必ず付ける — 付けないとフックは同期実行され、Claude Code の応答をブロックする。
`--max-time 1` は monitor が落ちている時に各セッションを待たせないための保険。

```jsonc
{
  "hooks": {
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "async": true,
      "command": "curl -sS --max-time 1 -X POST http://localhost:8766/hook -H 'content-type: application/json' -d @- >/dev/null 2>&1" }] }],
    "Notification": [{ "matcher": "", "hooks": [{ "type": "command", "async": true,
      "command": "curl -sS --max-time 1 -X POST http://localhost:8766/hook -H 'content-type: application/json' -d @- >/dev/null 2>&1" }] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "async": true,
      "command": "curl -sS --max-time 1 -X POST http://localhost:8766/hook -H 'content-type: application/json' -d @- >/dev/null 2>&1" }] }],
    "StopFailure": [{ "matcher": "", "hooks": [{ "type": "command", "async": true,
      "command": "curl -sS --max-time 1 -X POST http://localhost:8766/hook -H 'content-type: application/json' -d @- >/dev/null 2>&1" }] }],
    "SubagentStart": [{ "matcher": "", "hooks": [{ "type": "command", "async": true,
      "command": "curl -sS --max-time 1 -X POST http://localhost:8766/hook -H 'content-type: application/json' -d @- >/dev/null 2>&1" }] }],
    "SubagentStop": [{ "matcher": "", "hooks": [{ "type": "command", "async": true,
      "command": "curl -sS --max-time 1 -X POST http://localhost:8766/hook -H 'content-type: application/json' -d @- >/dev/null 2>&1" }] }]
  }
}
```

既に `Notification` / `Stop` にフックがある場合は、同じ `hooks` 配列に要素として足す（マッチしたフックは並列実行される）。
未知の `notification_type` はライブフィードに「通知: <種別>」として出るので、届いているのに扱えていない種別に気づける。

## 上限の残量（任意・statusLine 設定が要る）

Claude Code の 5 時間ウィンドウ / 7 日間ウィンドウの使用率を `GET /api/usage` と SSE の `usage` で配る。
`/usage` と同じ公式の値で、トークンからの推定ではない。claude-deck は上限到達の強制終了の判定に使う。

値は Claude Code が `statusLine` の command に渡す JSON（`rate_limits`）にしか入っていないので、
**ステータスライン用のスクリプトを monitor 側のものに差し替える**と取れるようになる。
`~/.claude/settings.json`（ユーザーレベル）を次のようにする。

```jsonc
{
  "statusLine": {
    "type": "command",
    "command": "/Users/<you>/project/ai-manager/monitor/scripts/statusline.sh"
  }
}
```

- 既に自前のステータスラインを使っている場合は、`monitor/scripts/statusline.sh` に自分の表示を足す
  （出力先のパスはスクリプトの位置から引いているので、ai-manager の外へコピーすると書き込み先が変わる）
- スクリプトは受け取った値を `data/claude-usage.json` に**原子的に**書く（同じディレクトリに
  tmp を作って `mv`）。monitor はそれを読むだけで、プロセス間に直接の結合は無い
- **表示を先に出し切ってから書く。** 書き込みに失敗してもステータスラインは従来どおり出る
- `jq` が要る（元から使っている）。全セッションから並行して呼ばれるが、書く内容はアカウント単位で
  同じなので競合しても問題にならない
- **出すのは `rate_limits` 由来の表示だけ。** `jq` が無い環境や `rate_limits` を返さない
  Claude Code ではステータスラインが空欄になるので、他に出したいものがあればスクリプトに足す
- monitor は 3 秒ごとに読み直し、SSE の `usage` イベントで配る
- **statusLine は Claude Code が動いている間しか呼ばれない。** 全セッションが終わっている間は値が
  古いままになるので、受け手は取得時刻を見て古い値を使わない（claude-deck は取得 10 分以内の値だけ使う）
- 未設定ならファイルが無いだけで `null` を返し、他の機能には影響しない

## API

| メソッド | パス | 用途 |
|---|---|---|
| GET | `/api/health` | 疎通確認 |
| GET | `/api/sessions` | 全セッションのスナップショット |
| GET | `/api/feed` | 直近のライブフィード |
| GET | `/api/sessions/:id/transcript` | そのセッションの会話履歴（`?after=<id>` で差分。下記） |
| GET | `/api/sessions/:id/transcript/:itemId/images/:index` | 発話に添えられた画像の本体（バイナリ。下記） |
| GET | `/api/usage` | 5時間 / 7日間ウィンドウの使用量（未取得なら `null`） |
| GET | `/events` | SSE。`sessions` / `feed` / `feed-batch` / `usage` / `permissions` イベント（`?transcripts=` で `transcript` も） |
| GET | `/api/permissions` | 保留中の権限確認（**ループバック以外は 404**） |
| POST | `/api/permissions/:key` | 許可・拒否（`{"decision":"allow"\|"deny"}`・**ループバック以外は 404**） |
| POST | `/api/channel/permissions` | チャネルからの権限確認（**ループバック以外は 404**） |
| POST | `/api/sessions/:id/message` | そのセッションの受信箱へ伝言を送る |
| POST | `/api/sessions/:id/open` | そのセッションの作業場所を開く（`{"app":"vscode"\|"xcode"}`） |
| POST | `/api/sessions/:id/close` | そのセッションのワークスペースを Xcode から閉じる（`{"app":"xcode"}`） |
| POST | `/hook` | フックの JSON をそのまま受け取る |

CORS は付けていない。付けると、ブラウザで開いた任意のサイトから cwd や作業内容を読まれるうえ、
**セッションへ伝言を送られる**。同じ理由で書き込み系（`/api/sessions/:id/message`・`open`・`close`・`/hook`・
権限確認）は `content-type: application/json` を必須にしている（プリフライトを回避した cross-origin POST を弾くため）。

あわせて全エンドポイント（`/events` の SSE を含む）で `Host` / `Origin` を検証している。
`Host` はループバック名（`localhost` / `127.0.0.1` / `[::1]`）＋待ち受けポートのみ許可し、`Origin`
は付いている時だけ `http:` のループバック名＋待ち受けポート（自分自身）かを見る（`curl` や claude-deck は付けないので無ければ通す）。外れたら 403。
DNS リバインディング（攻撃者のドメインを短い TTL で `127.0.0.1` に再解決させる）で、ブラウザからは
同一オリジンに見えてしまう経路を塞ぐため。

## 会話履歴（チャット表示用）

mac アプリのトークルームが使う。jsonl を先頭から読み、チャットの単位に整形して返す（読み取り専用）。
Host / Origin 検証は他の API と同じく全体のミドルウェアで掛かる。

```
GET /api/sessions/<sessionId>/transcript            → 全件
GET /api/sessions/<sessionId>/transcript?after=<id> → その id より後だけ
```

```jsonc
{
  "sessionId": "9c5a73ea-…",
  "reset": false,          // after の id が見つからず全件を返した時 true（手元の履歴を置き換える）
  "items": [
    { "id": "bac3…:0", "kind": "user",      "at": 1790773952000, "text": "[画像]\n…", "tool": null, "parentId": null,
      "images": [{ "index": 0, "mediaType": "image/png" }] },
    { "id": "40d6…:0", "kind": "assistant", "at": 1790773954648, "text": "…", "tool": null, "parentId": null, "images": [] },
    { "id": "9c52…:0", "kind": "tool",      "at": 1790773956269, "text": null,
      "tool": { "name": "Bash", "description": "…", "target": "ls monitor" }, "parentId": "40d6…:0", "images": [] }
  ]
}
```

- `kind`: `user`（ユーザーのプロンプト。tool_result・仕組み側の注入・isMeta は除く。スラッシュコマンドは `/name args` の形）/
  `assistant`（テキスト応答。thinking は除く）/ `tool`（ツール呼び出し）
- `id`: `<行の uuid>:<ブロック番号>`。ログは追記のみなので同じ要素は常に同じ id になる
- `at`: epoch ミリ秒（無ければ null）。全フィールドが常に存在し、値が無い時は null（Swift の Codable で Optional にすればそのまま読める）
- `tool`: `target` は対象の要約（file_path / コマンド 1 行目 / パターン / URL / スキル名 / サブエージェント種別の順で 1 つ・300 文字まで）。入力の全文は返さない
- `parentId`: tool がぶら下がる直前の発話（user / assistant）の id
- `images`: user の発話に添えられた画像の目録（`index` は発話の中で何枚目の画像か・`mediaType`）。本文には base64 を載せず、
  画像ブロックの位置には従来どおり `[画像]` の印が入る（目録のある分は受け手が印を外して画像を出す）。載せるのは base64 の
  `image/png` / `image/jpeg` / `image/gif` / `image/webp` だけ（SVG 等は文書として開かれた時にスクリプトが動きうるので出さない）。
  ツール結果（Read で画像を開いた等）の画像は対象外。無ければ空配列
- ログが見つからなければ 404、sessionId の形が不正なら 400。終了済みのセッションも jsonl が残っていれば読める

**画像の本体**は `GET /api/sessions/<sessionId>/transcript/<itemId>/images/<index>`（`itemId` の `:` は `%3A` でもよい）。
`content-type` に画像の形式を付けたバイナリで返す（`x-content-type-options: nosniff`・`content-security-policy: default-src 'none'`・
`cache-control: private, max-age=86400`。発話の uuid ごとに中身は変わらない。uuid の無い行（`line<N>:<k>`）は `no-store`）。
monitor は画像を常には持たず、画像付きの行のファイル上の位置（バイト数で数える）だけを覚えておき、求められた時にその行を
非同期に読み直して取り出す（位置がずれていたら uuid で探し直して位置を覚え直す。uuid の無い行は探し直さず 404）。
直近に解析した 4 行分（合計 32MB まで）は取り出した画像を持っておき、同じ発話の複数枚は 1 回の読み込みで返す。
目録に無い番号・ログや発話が見つからなければ 404、id や番号の形が不正なら 400。Host / Origin 検証は他の API と同じ。

**追記は SSE で届く。** `/events?transcripts=<id>[,<id>…]`（全セッションなら `*`）で接続すると、
`event: transcript` / `data: {"sessionId": "…", "items": [ … ]}` が流れる。購読した時点までの内容は流さないので、
取りこぼさない順序は「SSE を張る → GET（全件 or `?after=` 手元の最後）→ 以降は SSE」。重なった分は id で捨てる。
クエリを付けない接続には流さない。

## エディタで開く

`POST /api/sessions/:id/open` で、そのセッションの作業場所を `open -a` で開く。同じパスを開き直すと
既存ウィンドウが前面に出るので、ウィンドウは増えない。

- 開く先はリクエストで受け取らず `sessionId` から引く。任意パスを受けると、ブラウザで開いた
  別サイトから任意のファイルを開かせる穴になる。
- VSCode は cwd、Xcode は `.xcworkspace` / `.xcodeproj`（浅い階層優先・workspace 優先で探索）。
  見つからないセッションは `xcodeProject` が null になる（Xcode では開けない）。
- **探索はセッションを見つけた時に 1 回だけ**行う。後から Xcode プロジェクトを作った場合、
  そのセッションでは Xcode で開けない（Claude Code を開き直すか monitor を再起動する）。

### Xcode から閉じる

`POST /api/sessions/:id/close` で、**そのセッションのワークスペースだけ**を Xcode から閉じる。
（claude-deck の「閉じる」は同じ AppleScript をアプリ側で実行しており、この API は使っていない。）

- 閉じる先も `sessionId` から引く。`osascript` にはパスを埋め込まず `on run argv` の引数で渡す
  （`"` や `\` を含むパスでスクリプトが壊れるため）。
- `tell application "Xcode"` は起動していない Xcode を立ち上げてしまうので、先に `running` を見る。
- Xcode が起動していない／そのワークスペースが開いていない場合も成功として返す（冪等）。
  応答の `state` は `closed` / `not_open` / `not_running`。
- アプリごと終了（`quit`）はしない。未保存の変更があれば Xcode が確認ダイアログを出し、
  ワークスペースは閉じずに残る。受け手は「閉じた」と断定せず「閉じるよう伝えた」と扱う。
- VSCode は対象外。Claude Code が VSCode の中で動いていること、AppleScript の辞書が無く
  「このフォルダのウィンドウだけ閉じる」を指定できないことによる。

## 権限確認に答える（Channels の permission relay）

ツール使用の権限確認（`Bash` / `Write` / `Edit` など）を claude-deck の画面に出し、そこで許可・拒否できる。
Claude Code の **Channels**（research preview）を使う。チャネル本体は `src/channel.ts`（stdio の MCP サーバー）。

セッションを起こす側のリポジトリに `.mcp.json` を置き、**`--dangerously-load-development-channels`** を付けて起動する
（自作チャネルは承認済み一覧に無いため必須）。

```json title=".mcp.json"
{
  "mcpServers": {
    "monitor": {
      "command": "node",
      "args": ["/Users/shinjo/project/ai-manager/monitor/src/channel.ts"]
    }
  }
}
```

```bash
claude --dangerously-load-development-channels server:monitor
```

チャネルは `@modelcontextprotocol/sdk` を使うので、先に `cd monitor && npm install` を済ませておく。

`node` で `.ts` をそのまま渡しているのは Node 24 の型除去に任せるため（`npx tsx` を挟むとプロセスが 1 段増え、
セッションの特定に使う親 PID がずれる）。monitor が既定の :8766 以外なら `env` に `MONITOR_URL` を足す。

- 起動時に全画面の警告（`I am using this for local development`）と、`.mcp.json` の初回同意ダイアログが出る。
- 配るのは `tool_name` / `description` / `input_preview`（`GET /api/permissions` と SSE の `permissions`）。
- **`allow` / `deny` しか返せない。**「常に許可」「今回だけ」は Channels に無い（確認ごとに ID が変わる）。
- 中継されるのは**ツール使用の承認だけ**。`AskUserQuestion`・プロジェクト信頼・MCP サーバー同意は端末に出る。
- 端末のダイアログと同時に生きていて**先に答えた方が採用される**。端末側で答えられた分は、そのセッションの
  ログが進んだ時点で保留から消える（Claude Code は取り消しを知らせてこないため、ログの進みで判断する）。
  同じターンで別のツールが先に走ってログを進めると、まだ開いている確認も消えることがある（その時は端末で答える）。

### ループバック限定にしている理由

サーバー自体がループバックでしか待ち受けないうえ、権限確認の口（`GET /api/permissions`・`POST /api/permissions/:key`・
`POST /api/channel/permissions`）は接続元アドレスも確かめ、ループバック以外には 404 で存在ごと伏せる
（SSE の `permissions` と権限確認に関するライブフィードの行も手元の接続にだけ流す）。

- ドキュメントの警告どおり「チャネル経由で返答できる者は誰でも、セッションのツール使用を許可・拒否できる」
- スマホからの承認は `claude --remote-control` が担うので、monitor 側で外からの承認を持つ必要がない

判定は Host ヘッダーではなく**接続元アドレス**（詐称できない）。

### チャネルと monitor の繋ぎ方

チャネルは monitor の `POST /api/channel/permissions` に申請を預け、**その応答が返るまで待つ**（長ポーリング）。
チャネル側は待ち受けポートを持たない（セッションごとにチャネルが起動するため、固定ポートでは 2 つ目が衝突する）。

- 1 巡 60 秒で切れ、判断が出ていなければチャネルが取り直す。monitor を再起動しても取り直しで保留が戻る
- 90 秒取りに来なければ保留を捨てる（セッションが終わった・チャネルが落ちた）
- 申請元のセッションは**チャネルの親 PID だけ**で引く（チャネルは Claude Code の子プロセスなので
  `~/.claude/sessions/<pid>.json` と一致する）。cwd では引かない——同じ場所の別セッションに付け替わると、
  見ていない確認を許可させてしまうため。引けなければ「セッション不明の権限確認」として一覧の頭に出し、
  どのリポジトリかは申請元の cwd から併記する
- 保留の鍵は**申請元 PID と `request_id` の対**（`request_id` はセッション内でしか一意でない）。判断は 2 分だけ
  取り置き、取り直しの谷間（待ち手が居ない瞬間）に押された分も次の取り直しで渡す
- monitor が 30 分戻らなければチャネルは中継を諦める（以降その確認は端末で答える）

## 伝言を送る

`POST /api/sessions/:id/message` で、そのセッションの受信箱ソケットへ 1 通送れる（claude-deck の外部ルームの「伝言」）。経路は公式に文書化された
もので（cross-session messaging の「The session's inbox socket」）、行区切りの JSON を書く。

- ソケットはレジストリの `messagingSocketPath` を優先し、無ければ `/tmp/cc-socks/<pid>.sock`
  と `/tmp/cc-socks-<uid>/<pid>.sock` を探す。いずれも `lstat` で「自分が所有する Unix ソケット」
  であることを確かめてから使う
- 上限 10 万文字。成功は「書き終えた」までの保証で、受信側が受理したかまでは分からない
- 新しいセッションの起動口（`claude --bg` / `claude -p`）は設けていない

## 構成

```
src/                 バックエンド（Node 24 / tsx 実行）
  types.ts           ドメイン型（claude-deck の MonitorModels.swift と対応）
  paths.ts           ~/.claude 配下のパス解決（jsonl はスラッグ推測 → 走査でフォールバック）
  origin.ts          Host / Origin / 接続元アドレスの判定
  permissions.ts     権限確認の保留と判断（申請の検証・セッションの引き当て・長ポーリングの待ち）
  channel.ts         Claude Code のチャネル（stdio の MCP サーバー）。権限確認を monitor へ中継する
  inventory.ts       在庫層: セッションレジストリの走査と生存判定
  transcript.ts      実況層: jsonl の末尾差分読みとパース
  transcriptApi.ts   会話履歴 API（jsonl を先頭から読みチャット単位に整形 / SSE の transcript 配信）
  hub.ts             3 層の統合・状態判定・イベント発火
  server.ts          Hono。SSE 配信 / API / フック受け口（127.0.0.1 のみ）
scripts/statusline.sh  上限の残量を data/claude-usage.json に残す statusLine
```

ステージ（段々のピラミッドとドット絵のキャラ）は claude-deck が SceneKit で描く（`mac/Sources/MonitorKit/Stage/`）。

## 制約

- macOS ローカルのセッションのみ。クラウドセッションは `~/.claude/sessions` に現れないため映らない。
- ログに書かれるのはターン／ツール呼び出し単位で、生成中のテキストがトークン単位で流れてくるわけではない。
- 認証無しの `localhost` 限定。外からは使えない（必要なら SSH のポートフォワード等で繋ぐ）。
