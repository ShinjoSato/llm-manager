# iPhone 向けの口（Remote API v1）

claude-deck（mac アプリ）が**同じ Wi-Fi の iPhone アプリ**に出す API。iPhone アプリ（#121）はこの文書に従う。
外部サービスは使わない（通知だけは iCloud 経由。#122）。

- 型（Codable）は `Sources/MonitorKit/Remote/API/`（`RemoteAPIModels.swift`・`RemotePinning.swift`）と
  `Sources/MonitorKit/MonitorModels.swift`（`SessionSnapshot`・`PendingPermission`・`TranscriptItem` 等）。
  この 3 ファイルは Foundation / Security / CryptoKit だけに依存するので、共有パッケージへそのまま切り出せる。
- サーバー側は `Sources/MonitorKit/Remote/Server/`、mac の画面と操作の受け手は `Sources/ClaudeDeck/Remote/`。

## 口の開け方

- **既定は無効**。mac アプリのメニュー「claude-deck → iPhone 連携…」で有効にした時だけ開く（設定は UserDefaults）。
- 待ち受けは**選んだ LAN のインターフェースの IPv4 アドレスだけ**（既定は自動: `en*`（Wi-Fi / 有線）を優先）。
  `0.0.0.0` では待ち受けない。ポートは既定 **8767**（設定で変更可。1024 未満と 8766 は不可）。
  アドレスは 10 秒ごとに確かめ、替わっていれば開き直す（QR に載せたアドレスも替わるので、iPhone は下の予備の名前か再ペアリングで追う）。
- フック・チャネルの口（`127.0.0.1:8766`・`/hook`・`/api/channel/permissions`）は**別のサーバー**で、LAN には出さない
  （この口で叩いても 404）。
- **TLS のみ**（平文の HTTP は出さない）。最低 TLS 1.2。

## TLS とピン留め

- mac アプリが初回に P-256 の鍵と自己署名の証明書（ECDSA-SHA256・CN `claude-deck <Mac の名前>`・期限 20 年）を作り、
  `~/Library/Application Support/claude-deck/remote/`（0700）に `tls-key.bin` / `tls-cert.der`（0600）で置く。
  キーチェーンは使わない（読み込む時に `SecIdentityCreate` で手元に組む）。壊れていれば作り直す（指紋が変わるので再ペアリング）。
- iPhone は **CA の検証をせず、証明書（DER）の SHA-256 が QR の `fp` と一致する時だけ**信頼する。
  `URLSession` なら `urlSession(_:didReceive:completionHandler:)` で `RemotePinning.matches(serverTrust, pinned:)` を見て、
  一致すれば `.useCredential`、違えば `.cancelAuthenticationChallenge`。
  `NWConnection` なら `sec_protocol_options_set_verify_block` で同じ判定をする（どちらも `RemoteServerTests` で確かめている）。
- 期限で繋がらなくなることは無い（信頼は指紋で決める）。

## ペアリング

1. mac で「QR を出す」→ QR に `claude-deck://pair?v=1&host=<IPv4>&port=<port>&token=<一時トークン>&fp=<SHA-256 16進64桁>&name=<Mac の名前>&exp=<epoch ミリ秒>&local=<xxx.local>`
   （`RemotePairingPayload(url:)` で解ける）。一時トークンは 256bit の乱数（base64url）で **5 分で失効・1 回限り**。
   新しい QR を出すと前のものは使えなくなる。`local` は mDNS の名前（IP が替わった時の予備の接続先。無いこともある）。
2. iPhone は `POST /v1/pair` に一時トークンと端末名を送り、**端末トークン**（256bit・base64url）を受け取る。
   端末トークンはこの応答でしか返らない（mac には SHA-256 のハッシュだけを `devices.json`（0600）に残す）。キーチェーン等に保存すること。
3. 以降の全 API は `Authorization: Bearer <端末トークン>`。mac の「iPhone 連携」ウィンドウで端末一覧（名前・最後に使った時刻・接続中）と取り消しができる。
   取り消すとそのトークンは 401 になり、開いているストリームも切れる。端末は最大 20 台。

## 認証・上限

| 条件 | 応答 |
|---|---|
| トークン無し・不正・取り消し済み | 401（`WWW-Authenticate: Bearer`） |
| 同じ接続元から 5 分間に 10 回の失敗（認証・ペアリング） | 以降 5 分間 429（正しいトークンでも） |
| `Origin` ヘッダー付き（ブラウザ） | 403 |
| POST の `content-type` が `application/json` でない | 415 |
| 本文 256KB 超 / ヘッダー 64KB 超 | 413 / 431 |
| `Transfer-Encoding: chunked` の本文 | 501 |
| 同時接続 32 超 | 即切断 |
| 送り切らない相手 | 15 秒で 408 |
| ストリームが端末あたり 4 本・全体 16 本を超える | 429 |

失敗の本文は `RemoteErrorBody`: `{"ok":false,"error":"<code>","message":"<日本語>"}`。

## エンドポイント

| メソッド | パス | 本文 → 応答 |
|---|---|---|
| POST | `/v1/pair` | `RemotePairRequest {token, deviceName}` → `RemotePairResponse {deviceId, deviceToken, serverName, apiVersion}`（認証不要。外れ・期限切れ・使用済みは 401 `pairing_rejected`、台数超過は 409） |
| GET | `/v1/info` | → `RemoteInfo {apiVersion, serverName, device}` |
| POST | `/v1/unpair` | → `RemoteActionResult`（自分の端末を取り消す） |
| GET | `/v1/rooms` | → `RemoteState`（下記） |
| GET | `/v1/events?transcripts=<*\|id,id,...>` | Server-Sent Events（下記） |
| GET | `/v1/sessions/{sessionId}/transcript?after=<itemId>` | → `TranscriptResponse`（`after` 無しは全件。`after` が見つからなければ全件で `reset: true`）。無ければ 404 |
| GET | `/v1/sessions/{sessionId}/items/{itemId}/images/{index}` | → 画像のバイナリ（`Content-Type` は `image/png` 等。`Cache-Control: private, max-age=86400`）。目録は `TranscriptItem.images` |
| POST | `/v1/permissions/decision` | `RemotePermissionDecisionRequest {key, decision: allow\|deny}` → `RemoteActionResult`（Channels の権限確認。`key` は `PendingPermission.key`） |
| POST | `/v1/rooms/{roomId}/permission` | `RemoteTerminalPermissionRequest {promptId, decision}` → `RemoteActionResult`（端末画面の権限プロンプト） |
| POST | `/v1/rooms/{roomId}/menu` | `RemoteMenuAnswerRequest {menuId, choice?, cancel?, confirmExit?}` → `RemoteActionResult`（`choice` か `cancel: true` のどちらか一方） |
| POST | `/v1/rooms/{roomId}/menu/tab` | `RemoteMenuTabRequest {menuId, direction: next\|previous}` → `RemoteActionResult` |
| POST | `/v1/rooms/{roomId}/menu/dismiss` | `RemoteMenuDismissRequest {menuId, confirmExit?}` → `RemoteActionResult`（中身を読めないメニューを Esc で閉じる） |
| POST | `/v1/rooms/{roomId}/messages` | `RemoteMessageRequest {text}` → `RemoteActionResult`（添付は受けない。本文 32KB まで） |

`roomId` は `h:<UUID>`（mac がホスト中のセッション）か `e:<sessionId>`（外部セッション）。

### `RemoteState`（一覧と状態・要対応）

```jsonc
{
  "monitoring": true,                 // mac の監視が動いているか（false の間は古い）
  "usage": { "fetchedAt": 0, "fiveHour": { "usedPercentage": 40, "resetsAt": 0 }, "sevenDay": null },
  "rooms": [                          // 要対応 → 稼働中 → 待機、各グループ内は新しく動いた順（mac の一覧と同じ。検索の絞り込みは掛けない）
    {
      "id": "h:…", "kind": "hosted|external", "phase": "attention|active|idle",
      "name": "mirio", "branch": "develop", "status": "working|waiting|permission|idle|error|stopped",
      "line": "直近の一行", "activityAt": 0, "sessionId": "…|null", "cwd": "/…",
      "ended": "exited|limitReached|launchFailed|null",     // ホスト中のセッションが終わった理由
      "session": { /* SessionSnapshot（外部・ホスト中とも、監視に出ていれば） */ },
      "permissions": [ /* PendingPermission（Channels）。あれば最優先で出す */ ],
      "terminalPermission": { "promptId": "…", "title": "Bash command", "lines": ["…"] },
      "menu": { "menuId": "…", "context": [], "question": "…", "options": [{ "index": 0, "number": 1, "label": "Yes", "detail": [], "checked": null, "isSubmit": false, "selectable": true }],
                "cursor": 0, "footer": "…", "tabs": null, "isMultiSelect": false, "isReview": false, "cancelExits": false },
      "unreadableMenu": { "menuId": "…", "lines": ["…"], "cancelExits": false },
      "busy": false,                  // mac か iPhone から操作を送っている最中（終わるまで押させない）
      "send": { "mode": "input|relay", "disabledReason": "…|null" }
    }
  ]
}
```

カードの出し方は mac の会話末尾と同じ: `permissions`（Channels）があればそれ、無ければ `terminalPermission`、
それも無ければ `menu`（読めなければ `unreadableMenu`）。外部セッションは `permissions` だけ（無ければ答えられない）。

### `/v1/events`（Server-Sent Events）

- `Content-Type: text/event-stream`、chunked で流し続ける。`URLSession.bytes(for:)` で行ごとに読む。
- `event: state` / `data: <RemoteState の JSON>` … 接続直後に 1 回、以後は変わった時だけ（300ms ごとに比べる）。
- `event: transcript` / `data: <TranscriptEvent の JSON>` … `transcripts=` で指定したセッション（`*` は全部、最大 32 件）の会話の追記。
  取りこぼさないよう、**先にストリームを張ってから** `GET …/transcript` で全件を取り、id で重複を除いて足す（mac のチャット画面と同じ順）。
- 15 秒何も送らなければ `: ping`（コメント行）を送る。受け取りが遅れて 4MB 溜まった相手は切る。
- 端末を取り消す・口を閉じると切れる。iPhone は間を空けて張り直す（張り直したら `state` が届き、会話は全件を取り直す）。

## 操作の結果（`RemoteActionResult`）

`{"ok": true|false, "code": "<code>", "message": "<日本語|null>"}`。HTTP の状態は `ok` なら 200、
`not_found` 404・`invalid` 400・`app_unavailable` 503・`failed` 502・それ以外の失敗は 409。

| 操作 | 成功の code | 主な失敗の code |
|---|---|---|
| 権限（Channels） | `decided` | `not_found`（もう待っていない）・`busy` |
| 権限（端末） | `allowed` / `denied` | `gone`・`changed`（`promptId` が今のプロンプトと違う）・`busy` |
| 選択肢 | `confirmed` / `toggled`（複数選択のチェック切り替え）/ `cancelled` | `gone`・`changed`（`menuId` 違い・途中で替わった）・`unavailable`（文字入力の選択肢）・`confirm_required`（`cancelExits` なのに `confirmExit` が無い）・`stuck`・`vanished`・`settling`・`ended`・`busy` |
| タブ | `moved` | 同上 |
| 送信（ホスト中） | `submitted` | `blocked_permission` / `blocked_menu`（選択待ち。Enter が選択の確定になるため送らない）・`leftover`・`aborted`・`busy`・`ended` |
| 送信（外部） | `relayed` | `failed`（受信箱に届かない）・`unavailable` |

## mac 側の安全策（iPhone からの操作も同じ経路）

- 操作はすべて mac アプリの `ChatModel` の既存の処理を通す（`ChatModel+Remote.swift`）。迂回する口は無い。
  - 権限（Channels）: `MonitorStore.decide`（画面の権限カードと同じ）。
  - 権限（端末）: `promptId` が今のプロンプトと一致した時だけ、画面と同じ `answerOnTerminal`（端末の画面と再照合してから `1` / `Esc`）。
  - 選択肢: `menuId`（❯ の位置以外の中身から作る）が一致した時だけ、画面と同じ `answerMenu`（`MenuNavigator` で 1 行ずつ動かし、
    着いたのを確かめてから Enter）。押し間違いを避けるため、iPhone の画面も古い `menuId` のまま押させないこと。
  - 送信: 画面と同じ `HostedSession.send`（貼り付け前と Enter 直前に選択待ちを判定して止める・取りやめた本文の残りを確かめる）。
    mac の入力欄の書きかけ・添付には触れない。外部セッションは画面と同じ伝言（mac にも点線の吹き出しで出る）。
- iPhone からの失敗は mac に警告を出さず、結果だけを返す。
- 料金事故ゼロの方針は変わらない（新しい claude の起動口・headless の口は無い。API キーも使わない）。
