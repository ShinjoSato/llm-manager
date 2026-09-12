# monitor — Claude Code セッションのリアルタイム集約

複数リポジトリで同時に走っている Claude Code の状況を 1 画面で見るためのダッシュボード。
ai-manager の他の機能（`server` :8765 / `web`）とは**独立したプロセス**で、`:8766` で動く。

```bash
cd monitor
npm install
npm run build   # UI（ui/）をビルド。ui の依存もここで入る
npm start
# → http://localhost:8766
```

既定は **localhost 限定**（`127.0.0.1` にのみ bind・認証なし）。同じ Wi-Fi の別端末から見たい時だけ
`MONITOR_LAN=1` で開ける（下記）。セッションへ書き込む口があるため、それ以外では外に出さない。

セッションから読むのは記録だけで、こちらから行うのは「伝言を 1 通送る」ことだけ。
届いたテキストは受信側で**別セッションからのメッセージ**として扱われ、指示や承認にはならない
（権限の承認・設定変更・スラッシュコマンドの実行はいずれも不可）。

### 開発時（ホットリロード）

```bash
npm run dev                 # API :8766（tsx watch）
cd ui && npm run dev        # UI  :5174（/api・/events を :8766 にプロキシ）
```

## 同じ Wi-Fi の別端末から見る（iPad など）

```bash
MONITOR_LAN=1 npm start
```

`0.0.0.0` で待ち受け、起動時に案内 URL と **QR コード**をターミナルに出す。iPad のカメラで読めば開く。

```
  LAN: http://192.168.0.11:8766/?t=<64 文字の hex>
  █▀▀▀▀▀█ … （QR）
```

- **トークンを持つ端末だけ通す。** `?t=` が一致すると **HttpOnly cookie** を置き、`?t=` の無い URL に
  リダイレクトする（履歴やスクリーンショットにトークンが残りにくい）。以降は cookie だけで通る
- cookie にしているのは、**`EventSource` がカスタムヘッダーを付けられない**ため。ヘッダー方式にすると
  SSE（ライブ更新）が通らない
- 不一致・未提示は 401
- **手元（ループバック）からは今までどおりトークン不要。** 判定は Host ヘッダーではなく接続元アドレスで
  行う（Host は詐称できる）
- トークンは `secrets/monitor-token`（`.gitignore` 済み・0600）。無ければ起動時に生成する。
  環境変数 `MONITOR_TOKEN` があればそちらを優先。漏れたらファイルを消して再起動すれば新しくなる
- **トークンが用意できない状態で `MONITOR_LAN=1` なら起動を中止する。** 設定ミスで無防備に開くのを構造的に防ぐ

**HTTPS ではないので、トークンも画面の内容も LAN 上を平文で流れる。** 家庭内の Wi-Fi 前提で許容している。
同じ Wi-Fi にいるのは自分の端末だけとは限らない（来客のスマホ・IoT 機器）ので、LAN を信頼境界とは
見なさずトークンで絞っている。信頼できないネットワークでは `MONITOR_LAN` を付けない。

## 何を見ているか

Claude Code がローカルに残す記録を 3 層で集約する。

| 層 | 経路 | 取れるもの | 遅延 |
|---|---|---|---|
| 在庫 | `~/.claude/sessions/<pid>.json` + `kill(pid,0)` | 稼働中セッション一覧・cwd・起動時刻 | 3 秒 |
| 実況 | `~/.claude/projects/<slug>/<sessionId>.jsonl` の末尾差分 | 実行中ツール・ブランチ・作業内容・トークン量 | 250ms |
| 状態 | フックからの `POST /hook` | 入力待ち・権限待ち・API エラー・完了 | 即時 |

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
更新されていればそのセッションは稼働中として扱い、カードに「サブエージェント N 実行中」と出す。

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

## API

| メソッド | パス | 用途 |
|---|---|---|
| GET | `/api/health` | 疎通確認 |
| GET | `/api/sessions` | 全セッションのスナップショット |
| GET | `/api/feed` | 直近のライブフィード |
| GET | `/events` | SSE。`sessions` / `feed` / `feed-batch` イベント |
| POST | `/api/sessions/:id/message` | そのセッションの受信箱へ伝言を送る |
| POST | `/api/sessions/:id/open` | そのセッションの作業場所を開く（`{"app":"vscode"\|"xcode"}`） |
| POST | `/hook` | フックの JSON をそのまま受け取る |

CORS は付けていない（UI は同一オリジン配信、開発時は Vite の proxy 経由）。付けると、
ブラウザで開いた任意のサイトから cwd や作業内容を読まれるうえ、**セッションへ伝言を送られる**。
同じ理由で `/api/sessions/:id/message` と `/api/sessions/:id/open` は `content-type: application/json`
を必須にしている（プリフライトを回避した cross-origin POST を弾くため）。

あわせて全エンドポイント（`/events` の SSE と静的配信を含む）で `Host` / `Origin` を検証している。
`Host` はループバック名（`localhost` / `127.0.0.1` / `[::1]`）＋待ち受けポートのみ許可し、`Origin`
は付いている時だけループバック名かを見る（`curl` は付けないので無ければ通す）。外れたら 403。
DNS リバインディング（攻撃者のドメインを短い TTL で `127.0.0.1` に再解決させる）で、ブラウザからは
同一オリジンに見えてしまう経路を塞ぐため。`MONITOR_LAN=1` の時は、起動時に列挙した自分の非ループバック
IPv4 も許可に加える。cookie は**ホスト名**に紐づくので、攻撃者ドメイン（`evil.com`）の文脈では
トークン cookie が送られない（**cookie 方式はリバインディング対策としても効く**）。ただし
**cookie はポートを区別しない**ので、同じ IP の別ポートで動くサービスとは cookie を共有する。
そのため LAN 側の Origin 検証だけはポートまで一致を求めている。

開発サーバーを `vite --host` で LAN に出すと、proxy がループバック経由で monitor に繋ぐため
トークンを要求されない踏み台になる。`MONITOR_LAN=1` を使う間は `--host` を付けないこと。

## エディタで開く

各カードのボタンから、そのセッションの作業場所を `open -a` で開く。同じパスを開き直すと
既存ウィンドウが前面に出るので、ウィンドウは増えない。

- 開く先はリクエストで受け取らず `sessionId` から引く。任意パスを受けると、ブラウザで開いた
  別サイトから任意のファイルを開かせる穴になる。
- VSCode は cwd、Xcode は `.xcworkspace` / `.xcodeproj`（浅い階層優先・workspace 優先で探索）。
  見つからないセッションでは Xcode ボタンを出さない。
- **探索はセッションを見つけた時に 1 回だけ**行う。後から Xcode プロジェクトを作った場合、
  そのセッションでは Xcode ボタンが出ない（Claude Code を開き直すか monitor を再起動する）。

## 伝言を送る

各カードの入力欄から、そのセッションの受信箱ソケットへ 1 通送れる。経路は公式に文書化された
もので（cross-session messaging の「The session's inbox socket」）、行区切りの JSON を書く。

- ソケットはレジストリの `messagingSocketPath` を優先し、無ければ `/tmp/cc-socks/<pid>.sock`
  と `/tmp/cc-socks-<uid>/<pid>.sock` を探す。いずれも `lstat` で「自分が所有する Unix ソケット」
  であることを確かめてから使う
- 上限 10 万文字。成功は「書き終えた」までの保証で、受信側が受理したかまでは分からない
- 新しいセッションの起動口（`claude --bg` / `claude -p`）は設けていない

## 構成

```
src/                 バックエンド（Node 24 / tsx 実行）
  types.ts           ドメイン型（ui からも参照する）
  paths.ts           ~/.claude 配下のパス解決（jsonl はスラッグ推測 → 走査でフォールバック）
  origin.ts          Host / Origin / 接続元アドレスの判定（LAN 公開時の許可ホストも）
  token.ts           LAN 公開時の共有トークン（生成・読み出し・固定時間比較）
  inventory.ts       在庫層: セッションレジストリの走査と生存判定
  transcript.ts      実況層: jsonl の末尾差分読みとパース
  hub.ts             3 層の統合・状態判定・イベント発火
  server.ts          Hono。SSE 配信 / API / フック受け口 / ui/dist 配信
ui/                  React + Vite + TypeScript + Tailwind v4（web/ と同じデザイントークン）
  src/App.tsx        レイアウトと KPI
  src/useMonitor.ts  SSE 購読フック
  src/status.ts      状態ごとの色・ラベル・並び順
  src/components/    SessionCard / LiveFeed / ui(StatCard)
```

## 制約

- macOS ローカルのセッションのみ。クラウドセッションは `~/.claude/sessions` に現れないため映らない。
- ログに書かれるのはターン／ツール呼び出し単位で、生成中のテキストがトークン単位で流れてくるわけではない。
- 既定は認証無しの `localhost` 限定。LAN に出すのは `MONITOR_LAN=1` の時だけで、そこはトークンで絞る。
- HTTPS ではない。LAN 公開時、トークンも画面の内容も平文で流れる（家庭内 Wi-Fi 前提）。外出先からは使えない。
