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

読み取り専用で、セッションへの操作・送信は一切しない。

### 開発時（ホットリロード）

```bash
npm run dev                 # API :8766（tsx watch）
cd ui && npm run dev        # UI  :5174（/api・/events を :8766 にプロキシ）
```

## 何を見ているか

Claude Code がローカルに残す記録を 3 層で集約する。

| 層 | 経路 | 取れるもの | 遅延 |
|---|---|---|---|
| 在庫 | `~/.claude/sessions/<pid>.json` + `kill(pid,0)` | 稼働中セッション一覧・cwd・起動時刻 | 3 秒 |
| 実況 | `~/.claude/projects/<slug>/<sessionId>.jsonl` の末尾差分 | 実行中ツール・ブランチ・作業内容・トークン量 | 250ms |
| 状態 | フックからの `POST /hook` | 入力待ち・権限待ち・API エラー・完了 | 即時 |

**在庫層と実況層は設定不要**で、monitor を起動するだけで全セッションが並ぶ。
フック層は任意だが、**「なぜ止まっているか」はログに残らない**ため、これを入れると精度が上がる（下記）。

状態の優先順位は「ログ上の活動がフック通知より新しければ稼働中」。逆にフックより古いログ行では
「権限待ち」を解除しない（古い行で待ち状態を消さないため）。フックを入れない場合は
最終活動から 15 秒以内を稼働中とみなす。終了したセッションは 5 分間「終了」として残す。

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
| POST | `/hook` | フックの JSON をそのまま受け取る |

CORS は付けていない（UI は同一オリジン配信、開発時は Vite の proxy 経由）。
付けると、ブラウザで開いた任意のサイトから cwd や作業内容を読めてしまうため。

## 構成

```
src/                 バックエンド（Node 24 / tsx 実行）
  types.ts           ドメイン型（ui からも参照する）
  paths.ts           ~/.claude 配下のパス解決（jsonl はスラッグ推測 → 走査でフォールバック）
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
- 認証は無い。`localhost` 限定で使う。
