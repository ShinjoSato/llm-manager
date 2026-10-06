# claude-deck

プロジェクトごとに **Claude Code を同時起動**し、セッションを**チャット（トークルーム）**として扱う macOS ネイティブ司令塔アプリ（PoC）。
ai-manager の管理対象プロジェクト一覧と連携し、各プロジェクトのディレクトリで `claude` を端末として起動する。

SwiftTerm（VT100/Xterm エミュレータ + PTY ホスト）を使い、Terminal.app 同等の操作感を持たせている。

## 設計上の方針（重要）

- **料金事故ゼロ**: 子プロセスの環境から `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` を必ず除去して `claude` を起動する。API 課金経路が存在しないため、Max 枠の上限に達しても「待つ」だけで課金は発生しない。さらにログインシェル側でも `unset` してから `exec claude` する二重防御。
- **headless 不採用**: `claude -p` / Agent SDK の起動口は一切設けない（別枠課金や非対話実行を避ける）。
- **上限到達で強制終了**: 次のどちらかで上限到達とみなし、アプリでホストしている全セッションを `terminate()` で強制終了して警告ダイアログを出す。判定は `Sources/MonitorKit/LimitGuard.swift`（テストあり）、残量の購読は `Sources/ClaudeDeck/LimitWatch.swift`。
  1. **公式の残量（主）**: statusLine の `rate_limits`（`mac/scripts/statusline.sh` が `~/Library/Application Support/claude-deck/usage.json` に書く）をアプリ内の監視が読んだ `MonitorStore.usage` で、5 時間 / 7 日間のどちらかが 100% 以上、かつ取得から 10 分以内。古い値・未取得では落とさない（statusLine 未設定なら この経路は働かない。設定は下の「Claude Code 側の設定」）。一度到達したらそのウィンドウのリセット時刻まで覚えておき、その間に起動したセッションも起動直後に止める（新しい値で 100% 未満になれば解除）。
  2. **画面の上限表示（補助）**: 生の出力ではなく端末の実画面の末尾だけを見る。入力欄より下（フッター）、入力欄直上の最後の `⎿` 行（API エラー表示）、上限到達時に自動で開くメニューの「Stop and wait for limit to reset」。会話本文に同じ文言が出ても落ちない。文言は Claude Code v2.1.286 のバイナリ内で上限判定に使われている書き出し（`You've hit your` / `You've reached your` / `You're out of usage credits` / `You're now using usage credits` 等の課金枠切替 / `Usage limit reached`）に絞っている。
  - 起動直後（対話 zsh が `claude` に exec する前）は SIGTERM が効かないので、1.5 秒後に残っていれば SIGKILL する。

## 構成

```
mac/
  Package.swift                 SPM。SwiftTerm を依存に持つ実行ファイル "claude-deck"（SwiftTerm はリビジョン固定。更新時は Package.swift の revision を書き換える）
                                と、チャネルの実行ファイル "claude-deck-channel"
  Sources/ClaudeDeck/
    main.swift                  NSApplication 起動
    AppDelegate.swift           ウィンドウ + メニュー
    MainViewController.swift    メインウィンドウ = チャット画面（SwiftUI を NSHostingView で載せる）
    Chat/                       チャット画面（ルーム一覧・会話・入力欄・権限カード・選択肢カード）
      ChatRootView.swift          3 カラムの骨組み（ルーム一覧 | 会話 | 右パネルの差し込み口）
      ChatModel.swift             ルーム（監視のセッション + ホスト中のセッション）・会話履歴・権限確認の状態
      HostedSession.swift         アプリが PTY でホストする claude 1 つ（端末ビューは画面に載せず、PTY の受信と画面読み取りに使う）
      RoomListView.swift          ルーム一覧・検索・「+」（新しいルーム・プロジェクト一覧の管理）・監視 / フックの受け口の状態
      ConversationView.swift      見出し・吹き出し・ツール行・権限カード・選択肢カード
      Composer.swift              入力欄（⏎ 送信 / ⇧⏎ 改行・外部ルームでは「伝言」モード・添付（ボタン / ⌘V / ドロップ）とチップ）
      ChatImageViews.swift        吹き出しの画像（サムネイルの格子・拡大表示のシート・表示時に読み込んで NSCache に持つ ChatImageLoader）
      MarkdownView.swift          Claude の吹き出しの Markdown 描画（表の列幅揃え・横スクロール・解析結果のキャッシュ）
      ExternalSessionViews.swift  外部ルームのバナー（アプリに引き継ぐ）・伝言の点線吹き出し・Channels 未設定の案内
      ChatTheme.swift             色・文字・時刻の書式のトークン（ダーク固定。AppKit 側の色も）
    Stage/                      右側のステージパネル（360px）
      StagePanel.swift            見出し（開閉）・ステージ・いまの動き・随伴するサブエージェント・ライブフィード
      StageSceneView.swift        ステージの 3D を描く SCNView（表示中だけ回す・動きを減らす設定で止める）とウィンドウ幅の監視
    ClaudeTerminalView.swift    PTY ホスト + 環境からの API キー除去 + 画面の読み取り（ScreenState）+ 画面末尾の上限表示の監視
    LimitWatch.swift            公式の残量で上限到達を見て、ホスト中の全端末を止める
    MonitorBridge.swift         アプリ全体で 1 つの MonitorStore（監視とフックの受け口はアプリの中で 1 つ）+ 終了シグナルの配線
    Settings/                   設定画面（⌘,）。タブ: プロジェクト・GitHub・iPhone 連携・書き出し / 読み込み
    Remote/                     iPhone 連携（設定画面のタブの中身・QR・端末一覧・iPhone からの操作を ChatModel の既存の処理へ繋ぐ ChatModel+Remote）
  Sources/MonitorKit/           セッション監視・会話・フックの受け口（アプリ内）。UI 無し・テスト可能な library
    DeckCoreExport.swift        共有パッケージ DeckCore（../packages/DeckCore）を再公開する（監視のドメイン型・Remote API の型・
                                Markdown の解析・会話の組み立て・ルームのグループ化・ドット絵は DeckCore にある。iPhone アプリと共有）
    MonitorEvent.swift          監視からストアへ流れる変化（sessions / feed / usage / permissions / transcript）
    MonitorConfiguration.swift  読み取り元（CLAUDE_HOME）・使用量ファイル・受け口のポート・デバッグ出力
    MonitorStore.swift          @Observable ストア（監視の状態・受け口の状態・セッション・フィード・残量・権限確認・pid 対応付け）
    Hub/                        監視の本体
      SessionHub.swift            在庫層・実況層・フック層を束ねる actor（状態の合成・フィード・要対応・権限の中継・伝言）
      SessionInventory.swift      在庫層: ~/.claude/sessions/<pid>.json + kill(pid,0)
      TranscriptTail.swift        実況層: jsonl の末尾差分（ツール・ブランチ・トークン・ai-title の遡り primeMeta）
      Attention.swift             要対応の判定・待ち始めの時刻・権限待ちの説明
      PermissionRegistry.swift    Channels の権限確認の保留・長ポーリングの待ち手・取り置き
      TranscriptLog.swift         会話履歴の整形（発話・応答・ツール）と画像の取り出し（行の位置を覚えて読み直す）
      TranscriptStore.swift       会話履歴の取得と追記の購読（250ms）を持つ actor
      SessionMessaging.swift      受信箱ソケットへの伝言（Unix ソケット・自分の所有のソケットだけ）
      UsageReader.swift           使用量ファイル（statusline.sh が書く）の読み取り
      XcodeFinder.swift           作業場所の .xcworkspace / .xcodeproj 探し（会話の見出しの「Xcode」「閉じる」と iPhone の API が使う）
      ClaudeHome.swift            ~/.claude のパス・スラッグ・transcript の場所
    Server/                     フック等を受けるアプリ内の HTTP サーバー
      HTTPServer.swift            最小の HTTP/1.1（Network.framework・外部ライブラリなし）。既定は 127.0.0.1・平文。
                                  `HTTPServerOptions` で待ち受けるアドレス・TLS・検査・上限を変えられ、chunked で流し続ける応答（SSE）も出せる
      HookServerRoutes.swift      /hook・/api/channel/permissions・/api/health と、全口に掛ける Host / Origin / 接続元の検査
      LoopbackGuard.swift         Host / Origin / 接続元アドレスの判定
    Remote/                     iPhone 向けの口（同じ Wi-Fi・TLS・端末トークン）。仕様は docs/remote-api.md
      Server/                     SelfSignedCertificate（DER で X.509 を組む・鍵と証明書のファイル）・RemotePairingStore・
                                  RemoteAuthThrottle・RemoteRoutes（/v1 の振り分け）・RemoteEventHub（SSE）・RemoteControl（アプリへ頼む操作と照合）・
                                  RemoteAccessService（口の開け閉め・QR の中身・端末一覧）・LANInterfaces
    Channel/                    チャネル（claude-deck-channel）の中身。実行ファイルからはこれを呼ぶだけ
    Settings/                   設定（settings.json）の型・読み書き（0600・原子的・読めないファイルは上書きしない）・検証・
                                projects.json からの移行・旧 TSV / 書き出したものの取り込み・「+」と設定画面が共有するストア（SettingsStore）・
                                ルームとプロジェクトの対応と GitHub の URL（GitHubLinks）
      ChannelProtocol.swift       stdio の MCP（改行区切りの JSON-RPC 2.0）の読み解きと応答（initialize / ping / 未対応メソッド / 権限確認の通知）
      ChannelRelay.swift          受け口への長ポーリング（再試行 5 秒・30 分で諦める）と応答の読み分け
      ChannelServer.swift         stdin を行で読み、中継して判断を stdout に返す（ログは stderr）
    Support/                    SecureFile（0600・置き換えで書く）・DeckPaths（Application Support / Caches / Logs の claude-deck）
    TerminationSignals.swift    SIGTERM / SIGINT を何もしないハンドラで捕まえる（子に SIG_IGN を漏らさない）
    ClaudeSessionRegistry.swift ~/.claude/sessions/<pid>.json から sessionId を引く
    Stage/                      ステージパネルの文言・判定（StageLogic）、3D の寸法・配置・動き（StageBlueprint / StageScene）、
                                SceneKit のノードへの起こし（StageSceneRig）
    LimitGuard.swift            上限到達の判定（公式の残量 / 画面末尾の上限表示）
    EditorActions.swift         見出しの「VS Code / GitHub / Xcode / 閉じる」の結果の文言と、Xcode からワークスペースだけを閉じる AppleScript（osascript）
    Chat/                       チャット画面の UI に依らないロジック（テスト対象）
      RelayNotes+Failure.swift    伝言の送信失敗の理由（監視の失敗種別を言葉にする。伝言そのものは DeckCore）
      SessionHandover.swift       アプリに引き継ぐ: sessionId の検証・終了対象の確認（pid / sessionId / 起動時刻 / プロセス）・SIGINT → SIGTERM
      Attachments.swift           添付: 送る形の組み立て（画像パスの貼り付け用エスケープ・本文へのパスの一覧）・ペーストボードからの拾い出し・一時保存と掃除
      AttachmentPasteTextView.swift 添付を受ける文字欄（⌘V のメニュー検証・貼り付け・ドロップ）。入力欄の SubmitTextView の土台
      PTYInput.swift              PTY に送るキー列（貼り付け・Enter・権限の Yes / Esc・矢印・制御文字の除去）と、画面からの権限プロンプト / 選択メニューの判定
      MenuPrompt.swift            選択メニューの中身の読み取り（ChoiceMenu.parse）と、矢印で選択肢まで動かして Enter する手順（MenuNavigator）・問いのタブを移る手順（MenuTabMover）
      MenuScreenLog.swift         選択肢カードを出した・読めなかった画面の写しを直近数件残す
      ScreenPane.swift            画面の右に縦線で区切って出る別の欄（差分パネル）を除いて左だけにする
    Stage/
      StageLogic.swift            ステージパネルの文言（いまの動き・職業名・フィード）・プレースホルダー・開閉の判定
  Sources/ClaudeDeckChannel/    Claude Code が子プロセスで起動するチャネル（stdio の MCP サーバー・実行ファイル claude-deck-channel）
  Tests/ClaudeDeckTests/        MonitorKit のテスト（swift test。共通の補助は TestSupport.swift・FakeClaudeHome.swift）
  docs/remote-api.md            iPhone 向けの口の仕様（エンドポイント・型・ペアリング・TLS・上限）
  Resources/Info.plist          .app 用 Info.plist の雛形（バンドル ID・iCloud コンテナは bundle.sh が config/ の値で埋める）
  scripts/bundle.sh             claude-deck.app を組み立てて署名する（プロファイルがあれば Apple Development + iCloud、無ければ ad-hoc。チャネルの実行ファイルも同梱）
  scripts/statusline.sh         Claude Code の statusLine。表示に加えて使用量を Application Support に残す
```

## セッション監視とフックの受け口（MonitorKit・アプリ内）

セッション監視とフックの受け口は**アプリの中で動く**。起動時に `MonitorBridge.start()` → `MonitorStore.start()` が
監視（`SessionHub` / `TranscriptStore`）と受け口（`HTTPServer`）を動かし、UI は HTTP / SSE を経由せず
ストアから直接読む。重い I/O は actor 上で行い、メインスレッドには載せない。

- **在庫層**（3 秒）: `~/.claude/sessions/<pid>.json` + `kill(pid,0)`。**実況層**（250ms）: `~/.claude/projects/<slug>/<sessionId>.jsonl`
  の末尾差分（初回は末尾 512KB・`ai-title` / `last-prompt` は初回だけ最大 32MB 遡る `primeMeta`）。サブエージェントは 2 秒ごと。
  状態の合成・終了後 5 分の保持・要対応の時刻（`attentionSince`）・権限待ちの説明・未知の通知のフィード化は `SessionHub`。
  `primeMeta` と Xcode プロジェクトの走査は actor の外で行い、結果だけ戻す。初回の末尾読みのうちアプリ起動前に書かれた行は
  フィードに積まない（起動のたびに未読数が膨らまないように）
- **会話**: `TranscriptStore`（250ms で追記を読む actor）。購読するのは直近に開いたルームだけ（`watchTranscripts`）で、
  開いていないセッションのログは読まない・持たない。ルームを開いたら購読を張ってから `fetchTranscript` で全件、
  以降は追記を id で重複除去して足す。購読の張り替えは 1 回の呼び出しで行い、間の追記を落とさない。画像は `imageSource`（行の位置を覚えて読み直す。base64 の PNG / JPEG / GIF / WebP のみ）
- **使用量**: `~/Library/Application Support/claude-deck/usage.json`（`scripts/statusline.sh` が書く）を 3 秒ごとに読む（`CLAUDE_DECK_USAGE_FILE` で差し替え。スクリプトと同じ変数）
- **伝言**: 受信箱ソケット（自分が所有する Unix ソケットだけ）へ行区切りの JSON を 1 行書く。失敗は `HubFailure`（`not_found` / `not_alive` / `no_socket` / `unreachable`）
- 読み取り元は `CLAUDE_HOME`（既定 `~/.claude`）。読むだけで書かない。デバッグ出力は `CLAUDE_DECK_MONITOR_DEBUG=1`
- アプリで起動した claude の pid を `registerHostedProcess(pid:)` で登録し、`~/.claude/sessions/<pid>.json` の
  sessionId で監視のセッションと対応付ける（`sessionId(forHostedPid:)` / `hostedSessionIds`）。
  `/clear` で sessionId が替わるので sessions を受けるたびに読み直す

### アプリ内サーバー（:8766）

`~/.claude/settings.json` のフック（`curl … http://localhost:8766/hook`）と Channels の `claude-deck-channel`
（`http://127.0.0.1:8766/api/channel/permissions`）の宛先。出すのは**外から叩かれる口だけ**。

| メソッド | パス | 用途 |
|---|---|---|
| GET | `/api/health` | 疎通確認（`{"ok":true,"sessions":N,"server":"claude-deck"}`） |
| POST | `/hook` | フックの JSON を受けて 200 を返し、反映は届いた順に後から流す（未知のセッションでも 200） |
| POST | `/api/channel/permissions` | チャネルからの権限確認。判断が出るまで最大 60 秒待たせる（`allow` / `deny` / `timeout` / `dropped`） |

- `127.0.0.1` でだけ待ち受け、全口で `Host`（ループバック名 + 待ち受けポート）・`Origin`（付いている時は自分自身のみ）・
  接続元アドレス（ループバック以外は 404）を確かめる。CORS は付けない。POST は `content-type: application/json` 必須（415）。
  本文は 8MB まで（413）、ヘッダーは 64KB まで（431）、`Content-Length` は数字だけ・ヘッダー名に空白があれば 400、
  `Transfer-Encoding: chunked` は受けない（501）、`Expect: 100-continue` には Host / Origin / 接続元を確かめてから応える。
  同時接続は 64 まで（超えた分は即切断。長ポーリング中の接続も数える）。振り分け後に相手の FIN が来ても
  切断とはみなさず（送信後に `shutdown(SHUT_WR)` する相手にも応答を返す）、長ポーリングだけは取り消して `timeout` を
  早めに返す。全閉じの相手はその送信の失敗で閉じる。いずれも待ち手は外す（判断はチャネルの取り直しに渡るよう取り置く）
- フックの反映は待ち行列（4096 件）で順に流す。時刻は受け口に届いた時刻で数え（反映が遅れてもログ行との前後を誤らない）、
  未知のセッションは在庫だけ取り込んで先へ進む（メタ情報・Xcode の走査は後から埋め、待たない）。溢れて押し出した分は
  件数をログとそのセッションのフィードに出す
- `allowLocalEndpointReuse` は付けたまま。0.0.0.0 / `[::]` で待ち受ける別プロセス（SO_REUSEADDR の有無とも）が居ても
  127.0.0.1 では bind できず「使用中」になることを試験で確かめている
- ポートは `CLAUDE_DECK_SERVER_PORT`（既定 8766。`off` で待ち受けない）
- **ポートが使われている時**（別のプロセスが待ち受けている）: 奪わない・止めない。ルーム一覧の検索欄の下に
  「ポート 8766 を別のプロセスが使っているため、フック（権限待ち・入力待ち）が届きません」と出し、
  監視（一覧・会話・使用量）は続ける。5 秒ごとに取り直すので、そのプロセスを止めれば自動で引き継ぐ（`MonitorStore.serverState`）
- アプリが起動していない間のフックは届かない（curl は `--max-time 1` で諦めるだけで、Claude Code 側は止まらない）。
  取りこぼしてよい扱いにしている: 権限待ち・入力待ちはフックでしか分からないが、次のフックかログの追記で状態は戻る
- SIGTERM / SIGINT は `SIG_IGN` ではなく何もしないハンドラ（`TerminationSignals`）で既定動作だけ外し、通常の終了経路に乗せる。
  `SIG_IGN` は exec を越えて子に残り、ホスト中の claude（SwiftTerm の forkpty 経路）が SIGTERM を無視して
  上限到達時の `terminate()` が効かなくなるため。ハンドラは exec で既定に戻るので子に漏れない（`TerminationSignalsTests`）

## iPhone 連携（同じ Wi-Fi・`docs/remote-api.md`）

同じ Wi-Fi の iPhone アプリから、ルーム一覧・状態・要対応・会話（画像も）を見て、許可 / 拒否・選択肢への回答・メッセージ送信ができる口。
iPhone アプリは `ios/`（`ios/README.md`）、型とクライアントは共有パッケージ `packages/DeckCore`。
**既定は無効**で、設定画面の「iPhone 連携」タブ（メニュー「claude-deck → iPhone 連携…」でも開く）で有効にした時だけ開く。

- **口**: フック・チャネルの口（127.0.0.1:8766）とは別のサーバー・別のポート（既定 8767・変更可。1024 未満と 8766 は不可）。
  選んだ LAN のインターフェース（既定は自動: `en*` を優先。ポイントツーポイント・VPN（utun / tun / tap）・AirDrop（awdl / llw）・
  仮想マシンや共有のブリッジ（bridge / vmnet / vmenet / vnic / feth）等は候補に出さない）の IPv4 アドレスだけで待ち受け、
  `0.0.0.0`・マルチキャスト・ブロードキャストには開かない。10 秒ごとにアドレスを確かめ、替わっていれば開き直す。開けなければ（ポート使用中等）10 秒ごとに取り直す。
  **有効にした時のネットワーク**（インターフェースのアドレス帯 + 取れれば既定のルーターの MAC。SSID は位置情報の許可が要るので使わない）を覚え、
  別のネットワーク（外出先の Wi-Fi 等）では開かずに止めて、ウィンドウに「このネットワークで開く」を出す（判定は `LANNetwork.decide`）。
  口を閉じる時はポートを手放すのを画面のスレッドの外で待つ。
  `/hook` 等はこの口には無い（404）。設定は UserDefaults（`remoteAccess.enabled` / `remoteAccess.port` / `remoteAccess.interface` / `remoteAccess.network`）。
- **TLS**: 初回に P-256 の鍵と自己署名の証明書を作り、`~/Library/Application Support/claude-deck/remote/`（毎回 0700 に締め直す。`CLAUDE_DECK_REMOTE_DIR` で差し替え）に
  0600 で置く（作った瞬間から 0600 の一時ファイルに書いて置き換える。キーチェーンは使わない）。証明書は DER を自前で組み（`SelfSignedCertificate`）、CryptoKit で署名、`SecIdentityCreate` で手元に組む。
  平文の口は出さない（TLS の設定を組めなければ開かずに失敗にする）。iPhone は QR の SHA-256 指紋でピン留めする（ウィンドウにも指紋を出す）。
- **ペアリング**: 「QR を出す」で `claude-deck://pair?...`（接続先・一時トークン（5 分・1 回限り）・指紋・Mac の名前・mDNS 名）を出す。
  iPhone が `POST /v1/pair` で一時トークンを出すと端末トークン（256bit）を返し、mac にはそのハッシュだけを `devices.json`（0600）に残す。
  ウィンドウに端末一覧（名前・接続中・最後に使った時刻・ペアリング日時）と「取り消す」（確認あり。開いているストリームも切る）。
  取り消しを `devices.json` に書き出せなければ、メモリ上は取り消したままウィンドウに出し、5 秒ごとに書き直す。
- **認証と上限**: 全 API で `Authorization: Bearer`。失敗（認証・ペアリング）は接続元ごとに 5 分で 10 回まで（超えたら 5 分、その接続元の接続は受け入れた時点で切る）。
  `Origin` 付きは 403。本文 256KB・ヘッダー 64KB・同時接続 32（接続元ごとに 8）・読み取り 5 秒・TCP keepalive・
  ストリームは端末あたり 4 本（超えたら同じ端末の最も古いものを閉じて受ける）/ 全体 16 本。
- **操作は既存の経路だけ**: iPhone からの許可 / 拒否・選択肢・送信は `ChatModel+Remote.swift` が画面のカード・入力欄と同じ処理
  （`MonitorStore.decide`・`answerOnTerminal`・`answerMenu`（`MenuNavigator`）・`HostedSession.send`・伝言）に渡す。
  端末のプロンプトとメニューは iPhone が見ていたもの（`promptId` / `menuId`）と今のものが一致した時だけ送り、その後の画面との再照合も画面の時と同じ。
  ID には表示の世代を混ぜる（`HostedSession.promptTracker`。確認が消えるか替わるたびに進むので、同じ文面で出し直された次の確認には古い表示から答えられない）。
  答えた ID（mac・iPhone どちらから答えても）の押し直しは送らずに `answered` を返す。Channels の確認が出ている間は端末の権限・選択肢を iPhone から扱わない。
  操作の待ちは 30 秒で `timeout` を返す（操作自体は続きうる）。カードの組み立てと照合の純粋な部分は MonitorKit（`RemoteTerminalCard`・`RemoteRoomCards`・`RemoteChecks`）。
  選択待ちの間は送信しない。iPhone からの失敗は mac に警告を出さず結果で返す。mac の入力欄の書きかけ・添付には触れない。
  新しい claude を起動する口・headless の口は無い（料金事故ゼロの方針はそのまま）。
- **実機で確かめること**: 初めて有効にした時の macOS の「受信接続を許可しますか？」（アプリケーションファイアウォールが有効な場合）と
  ローカルネットワークの許可（`NSLocalNetworkUsageDescription` を Info.plist に入れてある）。ad-hoc 署名のため、`.app` を作り直すと
  ファイアウォールの許可を取り直すことがある。
- **テスト**: `RemoteAccessUnitTests`（証明書・DER・ペアリング・回数制限・照合・表示の世代と押し直し・カードの優先順・QR の中身・
  インターフェースの除外・ネットワークの判定・鍵ファイルの権限・取り消しの書き直し・TLS の設定・操作の待ちの上限）と `RemoteServerTests`
  （ループバックの OS 割り当てのポートに TLS で立て、指紋でピン留めした URLSession / NWConnection で叩く。別の指紋・平文は繋がらない・
  未認証 / 不正 / 取り消し後は 401・回数制限・接続元ごとの上限・ストリームの入れ替え・各 API・SSE・Channels の答えが `MonitorStore.decide` を通ること）。LAN には立てない。

## iPhone への通知（iCloud・CloudKit）

要対応（権限待ち・入力待ち・エラー）を、自分の iCloud（CloudKit の**プライベート DB**・既定のゾーン）を経由して iPhone に知らせる。
同じ Wi-Fi にいなくても・iPhone アプリを閉じていても届く。コンテナ・チーム ID・バンドル ID は `config/Local.xcconfig` に書く（下の「署名・識別子」）。

**現在は保留中（既定で無効）**。iCloud コンテナは作ると削除できないため、登録は見送っている。コンテナ（`DECK_ICLOUD_CONTAINER`）が空なら mac・iPhone とも「iCloud コンテナが設定されていない」旨を出して機能を止める。mac は macOS のプロファイルが無ければ ad-hoc で署名して機能を止め、iPhone アプリの通常のビルドは iCloud のエンタイトルメントを付けない（`ios/README.md`）。有効にする時は下の手順で登録し、iPhone アプリの `CODE_SIGN_ENTITLEMENTS` に `ClaudeDeck.iCloud.entitlements` を設定する。

- **mac（書き手）**: `ClaudeDeck/Notify/AttentionNotifier.swift` が 1 秒ごとにルーム一覧（`ChatModel.rooms`。ホスト中の端末の権限プロンプト・選択待ちも含む）を見て、
  `AttentionNoticePlanner`（DeckCore）で書く・消すを決め、`AttentionNoticeSync`（DeckCore）が `CloudKitNoticeStore`（MonitorKit）へ順に送る。
  - 書く時機: 要対応が **5 秒**続いたら（mac の前ですぐ答えたものは送らない）。その時に待っている他のルームも **1 件にまとめ**、見出し（と開くルーム）は
    5 秒続いたルームの中で一番新しいもの（「mirio ほか 2 件」。まだ 5 秒経っていないルームは「ほか」に回す）。
  - 1 件書いたら **30 秒**は次を書かず、その間に増えた要対応は明けた時に 1 件にまとめる。
  - 同じ要対応（待ち始めから解消まで。権限待ち→入力待ちのように種類が変わっても同じ）は 1 回だけ。解消は **3 秒**続けて要対応でなくなってから確定する
    （その間に戻れば同じ要対応のまま。状態の揺れで消して出し直さない）。まとめた全ルームが解消したらレコードを消す。
  - ルーム名はホスト中のルームなら登録したプロジェクト名、外部セッションはフォルダ名（`~/.claude/sessions/<pid>.json` の name は会話から付くことがあるので使わない）。
  - レコード（型 `AttentionNotice`）: `roomId`・`sessionId`・`roomName`・`kind`（permission / waiting / error）・`summary`（定型文。権限待ちはツール名だけ添える）・
    `title`・`body`・`since`（epoch ミリ秒）・`roomIds`・`macName`・`version`。**会話の本文・一覧の一行・タイトル・ツールの入力や説明は載せない**
    （ツール名は権限待ちの時だけ、Channels・フックの `tool_name`・通知文 `… permission to use X` のどれかから取り、`Bash`・`mcp__x__y` の形だけ通す。`AttentionNoticeText`）。
  - 書き込みの失敗は 2・4・8…最大 300 秒の間隔で静かに送り直す。iCloud の判定は 1 秒ごとに続け、送信は別に流す（応答待ちで判定を止めない）。
  - 書く名前は**送る前に** UserDefaults（`attentionNotice.written`）に覚える（失敗・タイムアウトでも実は書けていることがあるため）。一度でも送ろうとした知らせは
    解消したら必ず消しに行き、送っている最中に終了しても次の起動で消す。
  - 状態は設定画面の「iPhone 連携」タブの下の「要対応を iCloud 経由で iPhone に知らせる」（入り切り・既定は入）に小さく出す。切ると置いてある知らせも消す。
  - コンテナは `.app` の Info.plist の `DeckICloudContainer`（bundle.sh が埋める）から読む。空・未定義（`swift run` を含む）なら無効で理由を出す。
  - **エンタイトルメントが無い起動（ad-hoc 署名の `.app`）では無効**（`CKContainer` を作る前に `SecTask` で
    `com.apple.developer.icloud-services` / `icloud-container-identifiers` にそのコンテナがあるかを確かめ、無ければ理由を出す）。
- **iPhone（受け手）**: 設定の「要対応を通知する」（既定は切）で通知の許可を求め、`CKQuerySubscription`（`firesOnRecordCreation` のみ・ID `attention-notice-created`）を作る。
  見出し・本文はレコードの `title` / `body`（`ATTENTION_TITLE` / `ATTENTION_BODY` = `%@`）、同じルームの通知は `collapseIDKey = roomId` で置き換え、
  `desiredKeys`（roomId・sessionId・macName）で開く先を受け取る。切ると購読を消す（以後プッシュは来ない）。詳細は `ios/README.md`。
- **料金事故ゼロの方針はそのまま**（API キー・headless の口は無い。iCloud は自分のアカウントのプライベート DB だけ）。

### 署名とエンタイトルメント

- mac: `mac/Resources/claude-deck.entitlements` は雛形（`com.apple.application-identifier` = `$(DEVELOPMENT_TEAM).$(DECK_BUNDLE_PREFIX)`・team-identifier・
  `icloud-container-identifiers` = `$(DECK_ICLOUD_CONTAINER)`・`icloud-services` = CloudKit）で、bundle.sh が `config/` の値で埋めてから署名に使う。mac は書くだけなので `aps-environment` は入れない（プロファイルに無いと起動できなくなるため）。
- `scripts/bundle.sh` は次の順でこのアプリ用のプロファイルを探す。条件は Platform が OSX・App ID 一致・コンテナ入り・期限内・この Mac の Provisioning UDID が
  `ProvisionedDevices` に入っている（`ProvisionsAllDevices` なら不要）・`DeveloperCertificates` の SHA-1 がキーチェーンの `Apple Development:` の
  署名 ID（`security find-identity -v -p codesigning`）と一致する。チーム ID かコンテナが空ならプロファイルを探さずに ad-hoc にする。見つかれば `Contents/embedded.provisionprofile` に入れて、**一致した証明書**で署名する
  （チャネルはエンタイトルメント無しで先に署名。`CLAUDE_DECK_SIGN_IDENTITY` でハッシュか名前の一部に絞れる）。見つからなければ従来どおり ad-hoc（iCloud は無効）。
  `--adhoc` で強制。`--profile` / `CLAUDE_DECK_PROFILE` で指定したものが合わない時は理由を出して止まる（ad-hoc には落とさない）。
  1. `--profile <path>` / 環境変数 `CLAUDE_DECK_PROFILE`
  2. `mac/Resources/claude-deck.provisionprofile`（git 管理外）
  3. `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` と `~/Library/MobileDevice/Provisioning Profiles/` の `*.provisionprofile` / `*.mobileprovision`（新しい順）
- iOS: `ios/ClaudeDeck.iCloud.entitlements`（`aps-environment` = development・コンテナ `$(DECK_ICLOUD_CONTAINER)`・CloudKit）。既定のビルドには付けない（`ios/README.md`）。

### ユーザーが行う登録（Apple Developer。コンテナは作ると消せない）

0. `config/Local.xcconfig` に `DEVELOPMENT_TEAM`・`DECK_BUNDLE_PREFIX`・`DECK_ICLOUD_CONTAINER` を書く（下の「署名・識別子」）。以下の `<prefix>` / `<container>` はその値。
1. **iCloud コンテナ**: Xcode で `ios/ClaudeDeck.xcodeproj` を開き、ClaudeDeck ターゲット → Signing & Capabilities → iCloud の
   Containers で「+」→ `<container>` を作ってチェック（または developer.apple.com → Identifiers → iCloud Containers）。
2. **iOS の App ID / プロファイル**: 同じ画面で Push Notifications と iCloud（CloudKit）が有効なことを確かめ、自動署名に任せる
   （コマンドなら `xcodebuild -project ios/ClaudeDeck.xcodeproj -scheme ClaudeDeck -destination 'generic/platform=iOS' -allowProvisioningUpdates build`）。
3. **mac の App ID**: developer.apple.com → Identifiers で `<prefix>`（macOS）を作り、iCloud（CloudKit・上のコンテナを割り当て）を有効にする。
   SPM の実行ファイルは Xcode の自動署名が使えないので、Profiles で **macOS App Development** のプロファイルを作り（この Mac を Devices に登録・
   証明書は自分の `Apple Development:`）、ダウンロードして `mac/Resources/claude-deck.provisionprofile` に置く（またはダブルクリックで
   `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` に入れる）。
4. `mac/scripts/bundle.sh` → 「署名: Apple Development（iCloud 有効）」と出ることを確かめ、`open mac/dist/claude-deck.app`。
5. **CloudKit のスキーマ**: 開発環境（Development）はレコードを初めて保存した時に型とフィールドが自動で作られる（mac で一度要対応を 5 秒以上出す）。
   その後 iPhone で通知を入れる（型が無いうちは購読を作れず、画面に理由が出る）。購読の作成に失敗する場合は CloudKit Console
   （icloud.developer.apple.com）→ Schema → Indexes で `AttentionNotice` の `recordName` に Queryable を足す。
   Xcode から入れた iPhone と Apple Development 署名の mac はどちらも **Development** 環境を使う。TestFlight / App Store 版の iPhone は
   **Production** を使うので、その前に CloudKit Console の「Deploy Schema Changes」で本番へ反映し、mac も本番の環境で書く必要がある
   （`com.apple.developer.icloud-container-environment` = Production。今の bundle.sh は Development のみ）。

## Claude Code 側の設定（フック・statusLine・Channels）

どれも任意。入れなくても一覧・会話・ステージは動く。`~/.claude/settings.json` はユーザーの設定なので、アプリやスクリプトは書き換えない（下の手順で手で入れる）。

### フック（権限待ち・入力待ち・API エラー）

**「なぜ止まっているか」はログに一切残らない**ので、フックでしか取れない。`~/.claude/settings.json`（ユーザーレベル）に入れると全プロジェクトに効く。
**`async: true` を必ず付ける**（付けないとフックが同期実行され、全プロジェクトで Claude Code の応答をブロックする）。
`--max-time 1` はアプリが動いていない時に各セッションを待たせないための保険（その間のフックは取りこぼす）。

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

- 既に同じイベントにフックがある場合は、同じ `hooks` 配列に要素として足す（マッチしたフックは並列実行される）。
- 宛先は `http://localhost:8766/hook`。
- 未知の `notification_type` はライブフィードに「通知: <種別>」として出る。

### statusLine（上限の残量）

5 時間 / 7 日間ウィンドウの使用率は Claude Code が `statusLine` の command に渡す JSON（`rate_limits`）にしか入っていない。
`mac/scripts/statusline.sh` はそれを表示（`セッション: 43% (リセット: 2時間5分後) | 週間: 61%`）したうえで、
`~/Library/Application Support/claude-deck/usage.json` に**原子的に**書く（同じディレクトリに一時ファイルを作って `mv`。
作るディレクトリは 0700・ファイルは 0600）。アプリはそれを 3 秒ごとに読み、上限到達の強制終了に使う。

`~/.claude/settings.json` の `statusLine` を次のように指定する。

```jsonc
{
  "statusLine": {
    "type": "command",
    "command": "/Users/shinjo/project/ai-manager/mac/scripts/statusline.sh"
  }
}
```

- 保存先は環境変数 `CLAUDE_DECK_USAGE_FILE` で差し替えられる（アプリ側も同じ変数を読む。Finder から起動したアプリには環境変数が渡らないので、通常は既定の場所のまま使う）。
- **表示を先に出し切ってから書く。** 書き込みに失敗してもステータスラインは出る。値が 1 つも無い入力では記録を上書きしない。
- `jq` が要る。出すのは `rate_limits` 由来の表示だけなので、他に出したいものがあればスクリプトに足す。
- statusLine は Claude Code が動いている間しか呼ばれない。全セッションが止まると値が古くなるので、アプリは取得 10 分以内の値だけ使う。

### Channels（権限確認をアプリから許可 / 拒否）

ツール使用の権限確認（`Bash` / `Write` / `Edit` など）を claude-deck の画面に出し、そこで許可・拒否できる。
Claude Code の **Channels**（research preview の permission relay）を使う。チャネル本体は `claude-deck-channel`
（stdio の MCP サーバー。`Sources/ClaudeDeckChannel`・中身は `Sources/MonitorKit/Channel`。外部ライブラリなし）。

1. 実行ファイルを用意する。`.app` を使うなら `./scripts/bundle.sh` で `dist/claude-deck.app/Contents/MacOS/claude-deck-channel` に入る。
   `.app` を使わないなら `swift build -c release --product claude-deck-channel` → `.build/release/claude-deck-channel`。
2. セッションを起こす側のリポジトリの `.mcp.json` に、**実行ファイルの絶対パス**で登録する。

   ```json title=".mcp.json"
   {
     "mcpServers": {
       "claude-deck": {
         "command": "/Users/shinjo/project/ai-manager/mac/dist/claude-deck.app/Contents/MacOS/claude-deck-channel"
       }
     }
   }
   ```

3. **`--dangerously-load-development-channels`** を付けて起動する（自作チャネルは承認済み一覧に無いため必須）。

   ```bash
   claude --dangerously-load-development-channels server:claude-deck
   ```

- 起動時に全画面の警告（`I am using this for local development`）と、`.mcp.json` の初回同意ダイアログが出る。
- `command` は実行ファイルを直接指す（シェルや `env` を挟まない）。申請元のセッションを**チャネルの親 PID**で引くため、間にプロセスが 1 段増えるとずれる。
- 宛先は既定 `http://127.0.0.1:8766`。アプリのポートを変えた時だけ `.mcp.json` の `env` に `CLAUDE_DECK_URL` を足す。受け付けるのは `http://127.0.0.1` / `http://localhost` / `http://[::1]`（ポートのみ指定可）だけで、それ以外は既定に戻して stderr に理由を出す。リダイレクトとシステムのプロキシには従わない。
- **`allow` / `deny` しか返せない。**「常に許可」「今回だけ」は Channels に無い（確認ごとに ID が変わる）。
- 中継されるのは**ツール使用の承認だけ**。`AskUserQuestion`・プロジェクト信頼・MCP サーバー同意は端末に出る（アプリでホスト中のセッションなら選択肢カードで答えられる）。
- 端末のダイアログと同時に生きていて**先に答えた方が採用される**。端末側で答えられた分は、そのセッションのログが進んだ時点で保留から消える
  （Claude Code は取り消しを知らせてこないため）。同じターンで別のツールが先に走ってログを進めると、まだ開いている確認も消えることがある（その時は端末で答える）。
- MCP の応答は `@modelcontextprotocol/sdk` 1.30 の Server と同じにしてある: `initialize` は求められた版が対応表
  （`2025-11-25` / `2025-06-18` / `2025-03-26` / `2024-11-05` / `2024-10-07`）にあればそのまま、無ければ `2025-11-25` で答え、
  capabilities は `experimental` の `claude/channel` と `claude/channel/permission` だけ。`ping` は空の結果、tools / prompts 等の
  未対応メソッドは `-32601 Method not found`、壊れた行と知らない通知は黙って捨てる。stdin が閉じたら終わる。

#### チャネルとアプリの繋ぎ方

チャネルはアプリの `POST /api/channel/permissions` に申請を預け、**その応答が返るまで待つ**（長ポーリング）。
チャネル側は待ち受けポートを持たない（セッションごとにチャネルが起動するため、固定ポートでは 2 つ目が衝突する）。

- 1 巡 60 秒で切れ、判断が出ていなければチャネルがすぐ取り直す（1 回の上限は 90 秒）。アプリを再起動しても取り直しで保留が戻る。
- アプリに繋がらない間は 5 秒ごとに取り直し（ログは初回と約 1 分ごと・stderr）、30 分戻らなければ中継を諦める（以降その確認は端末で答える）。
  4xx は形が悪い申請なので取り直さずに諦め、5xx は繋がらない扱いで取り直す。
- 90 秒取りに来なければアプリは保留を捨てる（セッションが終わった・チャネルが落ちた）。
- 申請元のセッションは**チャネルの親 PID だけ**で引く（`~/.claude/sessions/<pid>.json` と一致する）。cwd では引かない——同じ場所の
  別セッションに付け替わると、見ていない確認を許可させてしまうため。引けなければ「セッション不明の権限確認」として出す。
- 保留の鍵は**申請元 PID と `request_id` の対**（`request_id` はセッション内でしか一意でない）。判断は 2 分だけ取り置き、
  取り直しの谷間に押された分も次の取り直しで渡す。
- **答えられるのは手元（ループバック）だけ**。受け口は接続元アドレスも確かめ、ループバック以外には 404 で存在ごと伏せる。
  チャネル経由で返答できる者は誰でもセッションのツール使用を許可・拒否できるため。スマホからの承認は `claude --remote-control` が担う。

## プロジェクト一覧（ユーザー管理 + 永続化）

チャット画面の「+」で選ぶプロジェクトの一覧。**ユーザーが自由に追加でき、永続化される**。

- 追加: 「+」→「フォルダを追加…」（複数可）。選んだディレクトリで `claude` を起動するエントリになる。
- 削除: 「+」の一覧で各行の「…」（または右クリック）→「一覧から削除」。一覧から外すだけでフォルダは消さない。
- 編集: 「+」の下部「設定を開く…」（またはメニュー「claude-deck → 設定…」⌘,）。名前・状態・メモ・並び順・GitHub の紐づけは設定画面で変える。
  「+」と設定画面は同じデータ（`SettingsStore`）を見るので、どちらで変えてもすぐ揃う。
- 同じプロジェクトを選ぶと、動いているルームがあれば新しく起動せずそのルームに移る（終了済みのルームしか無ければ新しく起動する）。
- 保存先・取り込みは下記（「設定（settings.json）」）。

## メイン画面: チャット

Claude Code のセッションを**チャットアプリの操作感**で扱う。セッション 1 つ = トークルーム 1 つ。
右側はステージパネル（`MainViewController` で `ChatRootView(model:) { StagePanel(model:) }` として差し込む）。

### ルーム一覧（左 312px）

- 監視が見つけたセッション + アプリでホスト中のセッションを **要対応（権限待ち・入力待ち）/ 稼働中 / 待機** に分けて並べる。
  各グループ内は最後に動いた順。状態は監視の `SessionSnapshot.status`。監視の開始前は、ホスト中のセッションだけ
  端末画面からのローカル判定（作業中 / 権限プロンプト / 待機）で代わりに出す。
- 各行: ドット絵キャラのアイコン・名前・ブランチ・状態ラベル + 直近の一行・時刻・未読数
  （開いていない間に届いた応答の数）。アプリの外で動いているセッションには「外部」タグ（伝言・引き継ぎは下記「外部セッション」）。
  - キャラはステージの 3D と同じ絵と配色（`packages/DeckCore/Sources/DeckCore/Pixel/PixelCharacter.swift`。マークの大きさ・位置・跳ね幅だけは小さいアイコンで読めるよう変えている）。稼働中=立ち・緑で跳ねる / 権限待ち=立ち・amber で「!」が点滅 / 入力待ち=立ち・青で「?」が点滅 / エラー=うずくまり・赤 / 待機=座り・灰で Zz が浮き沈み / 終了=座り・暗い灰 / 状態不明=座り・灰（マーク無し）
  - SwiftUI の Canvas で整数ポイントのマスを補間なしに塗る。動く状態だけ、画面に出ている間だけ `TimelineView(.periodic)` で 4fps で描き直す（起点を固定時刻にして全行が同じ境目でコマを切り替える）。「動きを減らす」設定では止める。行と見出しでは状態名を隣の文字が読むので、アイコン自体は読み上げない
  - 会話の見出しのアイコンも同じキャラ。「+」のプロジェクト一覧はセッションを持たないので頭文字アイコンのまま
- 上部: 検索（名前・ブランチ・タイトル・直近の一行。空白区切りで AND）と **「+」**（プロジェクト一覧から選んで `claude` を起動 = 新しいルーム。
  一覧の追加・削除・取り込みもここ）。右クリック → 「ルームを閉じる（claude を終了）」。
- 検索欄の下: 監視の開始中はその旨、フックの受け口（:8766）を開けない時（別のプロセスが使用中）はフックが届かない旨を出す。
- 上限の残り% は出さない（statusLine はターミナル起動の Claude Code でしか更新されず、VS Code 拡張だけ動いていると古い値が残るため）。
  上限到達の強制終了（`LimitGuard` / `LimitWatch`）は従来どおり `MonitorStore.usage`（取得 10 分以内の値だけ）を使う。

### ステージパネル（右 360px）

選択中のルームのセッションを、アプリが SceneKit で描くステージ（3D）と監視のデータで見せる。
文言・判定は `Sources/MonitorKit/Stage/StageLogic.swift`、ステージの組み立ては `StageBlueprint.swift`・`StageScene.swift`、
SceneKit への起こしは `StageSceneRig.swift`（いずれも MonitorKit・テストあり）、画面は `Sources/ClaudeDeck/Stage/`。

- **見出し**: 「ステージ」・畳むボタン。ステージは 3D 表示だけ（以前の 2D / 3D の保存値 `stagePanel.mode` はパネル表示時に消す）。
- **ステージ**: セッション 1 つ分の段々のピラミッド（議事堂）を描く。寸法・色・ボクセルの厚み・カメラの画角（縦 34°・見下ろし 0.42rad）と
  収め方・跳ね・脈・光り方の数値は、three.js で描いていた頃の見た目に合わせてある。
  - 親エージェントは最上段に立つ（状態で姿勢と色が変わる: 稼働中=立ち・緑 / 権限待ち=立ち・amber / 入力待ち=立ち・青 /
    エラー=うずくまり・赤 / 待機=座り・灰 / 終了=座り・暗い灰）。稼働中は 2 コマで跳ね、使っているツールの持ち物
    （端末・本・槌・巻物・望遠鏡・問いかけ・画布・紙）を右手に持って緑の光を添える。
  - サブエージェントは 1 つ下の段に最大 4 体、職業の色（Explore=紫 など）で並び、1 体ずつずらして跳ねる。
  - 要対応（権限待ち・入力待ち・エラー）は右肩に「!」/「?」のマークを立てて跳ねさせ、光を添え、足元の光の輪を強める。
  - 段の縁取りは状態の色で光り、要対応ほど強く速く脈打つ。待機・終了は脈打たず暗く光るだけ。
  - three.js（react-three-fiber）の見え方に合わせ、全材質に ACES のトーンマッピングを掛け、光の強さは物理単位（÷π）から直す。
    半透明の光の輪と足し算の光は three.js が sRGB のまま重ねるので、その結果に合わせて塗る（`StageSceneRig` のシェーダー）。
  - 中身（`StageSceneModel`）が変わった時だけノードを組み直す。描画は表示中・ウィンドウが見えている（隠れていない・
    しまわれていない）・動くものがある時だけ 30fps で回し、それ以外は止める。「動きを減らす」設定では静止の姿勢で止める。
  - 背景は透過（`SCNView.backgroundColor = .clear`）で、パネルの地色が地平線の上に見える。
  - 見た目の確認: `STAGE_SNAPSHOT_DIR=<dir> swift test --filter StageSceneTests/testRigRendersOffscreen` で
    状態ごとの画像をオフスクリーン（`SCNRenderer`）で書き出せる。
- **プレースホルダー**: 監視の開始中・ルーム未選択・ホスト中で sessionId 未解決（「セッションを確認しています…」）・
  監視がまだそのセッションを見つけていない、の各状態で文言を出す。
- **いまの動き**: スキル『…』> `currentAction` > ツールの動作（「端末を叩いている」等）の順で 1 つ。
  作業中でなければ `statusDetail` か状態名。下に「最終活動 N秒前 · 稼働 N分」（1 秒ごとに更新）と作業タイトル。
- **随伴するサブエージェント**: `agents` を id 順で、職業名（例: Explore → 斥候）・種別・状態
  （ログ更新が 15 秒以内なら「作業中」、それ以外は最終更新からの経過）。
- **ライブフィード**: そのセッションの feed の直近 60 件を新しい順（新着が先頭に入る）。時刻・種別（ツール / 指示 / 応答 / 状態 / セッション / 随伴）・内容を mono で。
- **開閉**: 見出しのボタンで畳む（幅 36px の帯になり、帯のボタンで開く。UserDefaults `stagePanel.open`）。
  ウィンドウ幅が 1100px 未満なら自動で畳む。狭いまま開いた時はそれに従い（パネルは最小 240px まで縮む）、広げれば通常に戻る。

### 会話（中央）

- 見出し: アイコン・名前・ブランチ・状態バッジ・「VS Code」「GitHub」「Xcode」「閉じる」。表示の切替は無く、どのルームも常にチャット。
  「Xcode」「閉じる」は `.xcworkspace` / `.xcodeproj` があるルームだけ出す（`XcodeFinder`。`.xcworkspace` 優先・最も浅い階層）。「閉じる」は確認ダイアログの後、
  AppleScript をアプリから `osascript` で実行し、Xcode からそのワークスペースだけを閉じる
  （Xcode は終了しない・起動していなければ立ち上げない。パスは argv で渡す）。ホスト中のルームでも使える。
  結果（開きました / 閉じるよう伝えました / Xcode では開いていません / Xcode は起動していません / エラー）をボタンの左に数秒出す。
  初回は macOS が「claude-deck が Xcode を操作する」許可（オートメーション）を求める。拒否するとエラー（-1743）になる。
  「GitHub」は、ルームの cwd が設定のプロジェクトの path と一致するか配下にあり（いちばん深いものを採る。`/a/b` は `/a/bc` に当たらない）、
  そのプロジェクトに GitHub の紐づけがある時だけ出す。Project 番号とリポジトリの両方があればメニューで選び、片方ならそのまま既定のブラウザで開く。
  ボードは owner の種類を `https://api.github.com/users/<owner>` の `type` で引いて `users/` か `orgs/` の URL にする
  （認証なし・3 秒で諦める・owner ごとにアプリが動いている間だけ覚える・取れなければ `users/`）。判定と URL は `Settings/GitHubLinks.swift`。
  ルームを移っても各ルームの PTY と claude は生きたまま。claude が終了したルームも、最後に分かった sessionId で会話を出し続ける。
- 端末ビュー（`ClaudeTerminalView`）は画面に載せない。PTY の受信は main キューで端末バッファに流れ、状態・権限プロンプト・選択待ち・上限表示は
  0.3 秒ごとのタイマーと受信時にバッファ末尾の `rows` 行を読むので、ビュー階層に無くても動く。桁数は作成時の 960×640pt のまま固定。
- 会話はアプリ内の `TranscriptStore` から組み立てる。ルームを開いた時に、直近に開いた 4 ルームを対象に追記の購読を張り直してから
  `fetchTranscript` で全件、以降は追記を id で重複除去して足す（それより前に開いたルームの会話は手放し、開き直した時に取り直す）。
  監視を始め直した（`connectionEpoch` の増加）後は**全件を取り直して置き換える**。最初の発話前でログが無い時は空のまま追記を待つ。
- 表示: 自分の発話は右の青い吹き出し、Claude の応答は左の暗色の吹き出し。Claude の応答は Markdown を描く（見出し・表・箇条書き / 番号付きリスト（入れ子）・引用・区切り線・コードブロック、インラインの太字・斜体・コード・リンク）。リンクは http / https だけ開き、`file://` やカスタムスキームは開かない（会話ビュー全体で判定は `ChatMarkdown.isOpenableLink`）。コードブロック内のタブはそのまま保つ。表は寄せ指定に従い、列幅は中身に合わせて長いセルは折り返し、吹き出しより広い時だけ横スクロール。解析は自前（`ChatMarkdown`・外部ライブラリなし）で本文ごとにキャッシュし、描画は `Chat/MarkdownView.swift`。自分の発話と伝言はインライン装飾のみ。
  ツール呼び出しは直前の発話の下に「ツール N件 ▸」の 1 行に畳み、開くとツール名と対象を並べる。実行中のものは緑で強調。
  新着で末尾へ自動スクロールし、上に遡っている間は止める（macOS 15 以降）。
- 作業中に送った指示は Claude Code 側でキューに入り、ログに「ユーザーの発話」として残らないため吹き出しには出ない（応答には反映される）。

### 入力欄と PTY への送信

- **⏎ 送信 / ⇧⏎（⌥⏎）改行**。日本語の変換中の ⏎ は確定に使われる。
- ホスト中のセッションには PTY に書き込む（本人のキー入力と同じ扱い）。本文は **bracketed paste**（`ESC[200~ … ESC[201~`）で
  入力欄に貼り付け、0.3 秒空けて Enter を送る（同時に送ると Enter が貼り付けに飲まれる）。改行を含む本文もそのまま 1 通で届く。
  作業中でも送れる（Claude Code がキューに積む）。
- **端末で選択待ちの間は送らない**。権限プロンプトだけでなく、plan の承認・AskUserQuestion・フォルダの trust 確認など
  「❯」で選ぶメニューが出ている間に Enter を送ると、選択中の項目が確定してしまうため。判定は端末の実画面の末尾
  （「❯ n.」の近くに n±1 の選択肢がある、または `Enter to confirm` / `Enter to select` / `Esc to cancel` 等の操作案内が行頭にある。
  入力欄より上の履歴は見ない。画面下の空行は落としてから見るので、縦に長いウィンドウで上詰めに描かれたメニューも拾う）で行う。
  「❯ n.」の選択肢の形の行は、罫線の直下にあっても入力欄とは見なさない。ただし下を罫線で閉じていて後ろに操作案内が無ければ
  入力欄（番号付きの文を入力中）とみなし、欄の中はメニューを探さない（入力欄は上下に罫線、メニューは ❯ の下を罫線で閉じない。v2.1.286）。
  画面の右に縦線 `│` で区切った別の欄（差分パネル `N files changed` 等）が出ている時は、同じ桁の縦線が 8 行以上続く所を区切りとして
  左だけを読む（`TerminalScreen.mainPane`。全幅の罫線で途切れた先は切らない。左端も縦線で始まる表・20 桁より左の縦線は区切りにしない）。
  文言だけで決めた「入力待ち」はバッジ表示用で、
  送信は止めない（返答本文が「Do you want to proceed …?」で終わるだけの画面で送れなくならないように）。入力欄は同じ条件で無効にし、
  権限なら「権限の確認に答えると送れます」、それ以外は「上の選択肢に答えると送れます」と出す。
  権限プロンプトには権限カード、plan の承認・AskUserQuestion・trust 確認などのメニューには選択肢カードで答える（下記）。
- 判定は**貼り付けの前**と、**Enter の直前**の 2 回。貼り付けた後に止めた場合は本文が Claude Code の入力欄に残る
  （安全に消すキーが無い。Esc はメニューの取り消しになる）ので、その旨を知らせ、チャット欄の下書きには戻さない（送り直しで二重にしない）。
  取りやめが起きたセッションでは、次の送信の前に端末の入力欄（罫線の間の ❯ 行）が空かを画面から確かめ、残っていれば送らずに
  「端末側の入力欄に前回の本文が残っているようです」と知らせる（前回の本文にくっつけないため）。警告は 1 回だけで、
  もう一度送ると送れる（未知の薄字表示を本文と誤認しても、チャットから送れないまま固まらないため）。
  空欄の時に薄字で出る例文（`Try "…"`）は空とみなす。
- 判定は SwiftTerm の表示位置 `yDisp` ではなく、バッファ末尾の `rows` 行（= 実画面）を読む。
- 本文からは改行・タブ以外の制御文字（C0・DEL・C1）を落としてから送る（ESC や Ctrl-C が端末操作として効かないように）。

#### 添付（画像・ファイル）

- 入れ方: 入力欄左のクリップ（NSOpenPanel・複数選択可）、**⌘V**（クリップボードにファイル URL があればそのファイル、文字列が無く画像（PNG / JPEG / HEIC / TIFF 等）だけならその画像。
  文字列を含むコピーは従来どおり文字として貼る。⌥⇧⌘V 等の pasteAsPlainText も同じ）、入力欄へのドラッグ＆ドロップ（ファイル・画像のデータ表現。ファイルプロミスは対象外）。入力欄の上にチップ（画像はサムネイル、
  それ以外は名前とアイコン、× で外す）。下書きと同じくルームごとに保持し（`ChatModel.attachments`）、1 通 20 個まで。本文が空でも添付だけで送れる。
  ルームを閉じた時・外部ルームが一覧から消えた時（監視の開始前・引き継ぎ中を除く）は、送る前の添付・サムネイル・一時ファイルを片付ける。
- ⌘V のメニュー検証: 文字専用の NSTextView（`isRichText = false`・`importsGraphics = false`）は、クリップボードに読める型
  （文字列・RTF・ファイル名等の `readablePasteboardTypes`）が無いと「ペースト」を無効にする。スクリーンショット（`public.png` / `public.tiff` だけ）
  では ⌘V のメニューごと無効になり、`paste(_:)` が呼ばれなかった。添付にできるクリップボードの時は `validateMenuItem` /
  `validateUserInterfaceItem` で有効にする（`AttachmentPasteTextView`。読むペーストボードは差し替え可能で、テストは専用のものを使う）。
- 取り込み: 写し（`FileManager.copyItem`）・変換・サムネイル作りはバックグラウンドで行い、終わるまでチップに「読み込み中…」を出して送信を止める。
  **画像は 1 件 20MB まで**（超えたら理由を出して添付しない。画像以外は写さないので大きさを問わない）。
- 保存: **画像は `~/Library/Caches/claude-deck/attachments/` に写す**（ディレクトリ 0700・ファイル 0600・名前は UUID）。元が消える一時ファイル
  （スクリーンショットのドラッグ等）・パスの空白・TUI が読めない形式（HEIC / TIFF / BMP は PNG に変換）でも取り込めるようにするため。
  クリップボード・ドロップの画像は PNG / JPEG / GIF / WebP ならそのまま、それ以外は PNG にして保存。**画像以外は写さず元のパス**を使う（Claude が Read で読む）。7 日より古い一時ファイルは起動時に消す。
  × で外した画像の一時ファイルはその場で消す（送った分は受け手が後から読むことがあるので残す）。
- 送り方（ホスト中のセッション）: Claude Code（v2.1.286 のバイナリで確認）は **貼り付けの中身が画像ファイルのパス**
  （拡張子 `png / jpg / jpeg / gif / webp`・大文字小文字無視、絶対パスで実在、中身も画像）だと、ファイルを読んで `[Image #N]` の添付に変える。
  貼り付けは「空白 + `/`」と改行で区切って複数パスを扱い、各片の前後の引用符を外し `\x` を `x` に戻してから判定する。
  ただし同じ貼り付けに画像パスがあると、それ以外の部分を行に割って繋ぎ直す（本文が崩れる）ので、
  **画像のパスだけを先に 1 回で貼り**（空白・引用符は `\` でエスケープ）、入力欄に `[Image #N]` が増えたのを画面で確かめてから（最大 5 秒）
  本文を貼り、0.3 秒後に Enter。取り込み中の Enter は TUI に捨てられるため待つ。確かめられずに進んだ時は次の送信前に入力欄の残りを確かめる。
  画像以外のファイルは本文の末尾に `添付:` に続けてパスを 1 行ずつ書く（空白を含むパスは `"…"` で囲む）。
  貼り付けモードでない端末では画像もパスの一覧に入れる。選択待ちでの停止は、画像の貼り付け前・本文の貼り付け前・Enter の直前で判定する。
  `[Image #N]` は入力欄の折り返しで割れても数えられるよう、空白・改行を除いてから数える。
- 送信中（画像の取り込み待ち〜Enter・最大 5 秒強）は次の送信を受けず、入力欄に「送信中…」を出す（書くことはできる）。結末は送信後に返り、
  **本文を貼る前に選択待ちで取りやめた時**は端末には画像だけが残るので、本文と添付を入力欄に戻してその旨を出す（そのまま送り直すと画像が二重に付く）。
  **本文を貼った後に取りやめた時**は本文が端末に残るので戻さない（戻すと二重に送るため）。どちらも次の送信の前に端末の入力欄の残りを確かめる。
- 外部セッション（伝言）: 画像も含めて本文の末尾にパスの一覧を添える（受け手が Read で開く）。点線の吹き出しにも一覧と、添えた画像（手元の一時ファイル）が出る。
- 会話の吹き出し: transcript の発話の `images`（監視の画像の目録）があれば、吹き出しの上に画像のサムネイル（最大 3 列・角丸・1 枚なら 200pt 角、
  複数なら 120pt 角。枠の大きさは枚数だけで決め、読み込みの前後でスクロール位置を揺らさない）を出し、本文の `[画像]` の印はその枚数ぶん外す。
  クリックで拡大表示（シート・Esc で閉じる）。画像は表示された時にだけ `GET /api/sessions/:id/transcript/:itemId/images/:n` で取り、
  縮小（長辺 480px）してから `NSCache`（300 枚・128MB）に持つ。同じ画像の同時の読み込みは 1 回にまとめる。VS Code 等から送った画像付きの発話も同じく出る。
  アプリから画像を添えて送った発話は、transcript に載るまでの間も端末へ画像として貼った分（手元の一時ファイル）を薄い吹き出しで出す
  （`ChatModel.sentImages`）。パスとして本文に回った画像（貼り付けモードでない端末・貼れない形のパス）だけなら記録に画像が付かないので出さない。
  送信後の本人の発話で、画像の枚数と本文（`[Image #N]`・`[画像]` の印と空白を除いたもの）が一致するものが transcript に載ったら消す
  （1 件の発話は 1 通にだけ対応・時計のずれ 5 秒まで許す。ターミナルから直接送った別の画像付き発話では消さない）。
  Enter まで届かなかった送信は出さず、3 分経っても載らなければ（キューの取り下げ・捨てられた Enter 等）下げる。
  ファイルは本文のパス一覧がそのまま出る。TUI の Ctrl+V（クリップボードを osascript / Bun で読む）は使わない（アプリがクリップボードを介さずに済むため）。

### 権限カード

- 権限待ちは会話の末尾に amber の枠のカードで出す（ツール名・見出し・コマンド等のプレビュー・許可 / 拒否）。
- 監視の `permissions`（Channels 経由）があれば `store.decide` で返す。無ければホスト中のセッションの端末画面から
  プロンプトを読み取り、**許可 = `1`（1. Yes）/ 拒否 = `Esc`** を PTY に送る（選択肢の数で「No」の番号が変わるため拒否は Esc）。
  キーは Claude Code v2.1.251 / v2.1.286 の実際の TUI で確認した。画面にプロンプトが無ければ何も送らない。
  押した時のカードの内容と今の画面のプロンプトが違う（別の確認に替わった）場合も何も送らず、カードを今の内容に更新する。
- 押してから結果が出るまでは、そのカードのボタンを無効にして二度押しを防ぐ。

### 選択肢カード

- ホスト中のセッションの端末に「❯」で選ぶメニュー（plan の承認・AskUserQuestion・フォルダの trust 確認など）が出たら、
  権限カードと同じ位置（会話の末尾）に amber の枠のカードで出す。中身は端末の実画面から読む（`ChoiceMenu.parse`）:
  問いより上の本文（plan の中身・trust 確認のフォルダ・質問の見出し）、問い（選択肢の直前の行）、選択肢（番号・文言・下の字下げの説明行）、
  今「❯」が付いている行。選択肢は「❯ n.」から番号が 1 ずつ続く範囲だけを取る（plan 本文の番号付きリストを混ぜない）。
  番号の無いメニュー（trust 確認）は「❯」の行と、空行を挟まずに同じ字下げで並ぶ行を選択肢とする。
  「❯」の行は操作案内（`Enter to … · Esc to …`。無ければ画面の末尾）から上へ 24 行以内だけ探し、会話の返答（`⏺`）の行に当たれば探すのをやめる
  （履歴の発話 `❯ …` を選択肢と読まないため）。番号の無い「❯」の行は操作案内が出ている時だけ選択肢とみなす。
  本文は上の罫線までの囲み。罫線が見当たらなければ空行・会話の行（`⏺` / `❯`）・経過表示（`✻ … (3s)` 等）の手前で止める（照合に使うので変わる行を入れない）。
- 押すと **矢印キー（↑/↓）で「❯」を 1 行ずつ動かし、目的の行に着いたのを画面で確かめてから Enter** を送る（`MenuNavigator`）。
  番号キーは使わない（trust 確認には番号が無く、番号キーが「移動」か「即決定」かもメニューごとに違って、押した結果を確かめてから確定できないため）。
  矢印は端末のモードに合わせて CSI（`ESC[A`/`ESC[B`）か、アプリケーションカーソルモードなら SS3（`ESC O A`/`ESC O B`）で送る。
  0.1 秒ごとに画面を読み直し、「❯」が動くのを待ってから次の矢印を送る（画面が追いつく前に送り重ねて行き過ぎないため）。
  「❯」の変化は、送った向きへちょうど 1 行動いた時だけ受け入れる。送っていないのに動いた・2 行以上動いた・逆に動いた時は、
  数えていない入力がある証拠なので戻さずに Enter を押さずにやめる。目的の行に着いても、次の読み取りで位置が変わらないのを確かめてから Enter を送る。
  未反映の矢印は常に 0 か 1 個で、これは**ナビゲーションをまたいでも**保つ: 約 1 秒待っても「❯」が動かなければ**再送せずに**やめ、
  未反映の矢印を残してやめた時は印（`PendingArrowHold`）を残して、次に押しても「反映待ち」として動かさない。印は「❯」が動いた
  （残りの矢印が反映された）・端末の出力が 1.5 秒止まった・5 秒経った時に外す（残りの矢印を次の移動の 1 歩と数えて 1 行先で確定しないため）。
  やめた後もカードのボタンは 1.5 秒押せないままにする。
- 最初に、押した時のカードと今の画面のメニュー（本文・問い・選択肢の文言。「❯」の位置は除く）が同じかを確かめ、違えば何も送らない。
  動かしている途中で問い・本文・選択肢の数が変わったら Enter を押さずにやめる。着いた時も全体を照合してから Enter を送る。
  「❯」が動かない・メニューが消えた時も Enter を押さずにやめて理由を出す（矢印で「❯」を動かした分は端末に残る）。
  理由は「押した時に選択肢が無い（答え終わった等）」「動かしている途中で読めなくなった」「内容が替わった」「位置を合わせられない」
  「claude が終わった・端末ビューが無くなった（終了・上限到達）」で文言を分ける。
- 「キャンセル（Esc）」は今のメニューがカードと同じで、Esc が終了になるかどうかも同じ時だけ `Esc` を送る。Esc が claude の終了になるメニュー
  （操作案内が `Esc to exit`、またはフォルダの trust 確認）では、ボタンを「終了（Esc）」にして確認ダイアログを挟む。
  確認中にメニューが差し替わっても、照合は確認を開いた時のメニューで行う（カードは中身が替わると作り直す）。
- 自由入力の行に「❯」が乗って文字が空（`❯ 3.`）でも、前後に続き番号の選択肢があればメニューとみなし、入力欄からの送信を止める。
- **文字を入力する選択肢**（AskUserQuestion の「Type something.」、plan の「Tell Claude what to change」）はカードからは選べない
  （選ぶと端末側の文字入力に移り、本文を安全に渡せないため）。「キャンセル」で閉じてから入力欄で伝える旨を出す。
- AskUserQuestion の複数選択（選択肢の行頭に `[ ]` / `[✔]` 等のチェック欄があるもの）は「複数選択: 押すとチェックを切り替えます」と出し、
  押した後は「チェックを切り替えました」と出す（Enter はチェックの切り替えで、メニューは閉じない）。
- **複数選択・複数の問い（タブ）**（TUI v2.1.286 のバイナリの描画コードで確認。本物の claude での目視は未確認）:
  - 複数選択では選択肢（最後は「Type something」）の下に番号の無い **`Submit`**（最後の問い）/ **`Next`** の行が出る。Enter はチェックの切り替えで、
    この行で Enter を押すと次の問い（最後なら Submit タブ）へ進む。カードではこの行を「Submit（回答の確認へ）」/「Next（次の問いへ）」の選択肢として出し、
    ほかの選択肢と同じく ↑/↓ で 1 行ずつ動かして着いたのを確かめてから Enter を送る（「❯」がこの行にある画面も読める）。
    自由入力の行に「❯」が乗ると例文が消えて `❯ 4. [ ]` になるので、チェック欄だけの行も文字入力の選択肢として扱う。
  - 問いの上のタブ行 `←  ☒ 見出し  ☐ 見出し  ✔ Submit  →`（☒ 回答済み・☐ 未回答・最後が Submit タブ）を読み、本文とは分けて
    カードの上部にタブとして出す。今のタブは文字では分からず背景色だけで示されるので、端末のセルの背景色から読む（読めなければ「読み取れません」）。
    問いが 1 つの単一選択は矢印も Submit タブも無い `☐ 見出し` だけで、タブの移動は出さない。
  - 「← 前の問い」「次の問い →」は **→ / ← を 1 回だけ送り、画面の問いが替わったのを確かめて終える**（`MenuTabMover`。Tab キーは複数選択で
    選択肢の移動に取られるので使わない）。押した時のカードと今のメニューが同じで、「❯」が文字入力の行に無い時だけ送る（文字入力中は ←/→ が
    文字の操作になる）。替わらないまま約 1.5 秒経つ・読めないままになると再送せずにやめ、矢印と同じ `PendingArrowHold` で次の操作を待たせる。
  - Submit タブ（`Review your answers` … `Ready to submit your answers?`）の「1. Submit answers / 2. Cancel」は通常の選択肢として答える
    （Cancel は質問ごと取り消し）。回答の一覧は本文として出す。
  - 80 桁を超える・改行のある問いは左の縦線 `│ ` 付きで折り返して出るので、続く縦線の行をまとめて 1 つの問いにする
    （英数字どうしの折り返しは空白を戻し、和文はそのままつなぐ）。
- 端末ビューは画面に載せないので、起動前に枠を広げて **約 160 桁** にする（960pt のままでは桁が足りず、問いや説明が折り返す）。
  起動前に決めるので PTY の大きさは最初から 160 桁で伝わり、途中のサイズ変更は起きない。
- 調べ用に、選択肢カードを出した時（中身が替わった時だけ）・読めなかった時の端末画面の写しを `~/Library/Logs/claude-deck/menu-screens.log` に
  **直近 5 件だけ**残す（`MenuScreenLog`。会話の本文が入りうるので 0600・一時ファイルからの置き換え・外へは送らない）。
- 文字入力の行をまたがないと届かない選択肢では、通り抜ける途中で画面が選択肢として読めなくなる・選択肢の並びが変わって見えると、
  Enter を押さずに止まる旨をカードに出す。
- 中身を読み取れないメニューは、その旨と「キャンセル（Esc）」だけのカードを出す。押した時のカードと今の画面が同じ「読めないメニュー」
  （メニューの範囲の行の写し `UnreadableMenu`）の時だけ送る。Esc が終了になるメニューでは同じく確認を挟む。
- 押してから結果が出るまではカードのボタンを無効にして二度押しを防ぐ（端末ビューが途中で無くなっても送信中の印は外す）。外部セッションは対象外。

### 外部セッション（ターミナル等で起動したもの）

アプリの外で起動した claude には本人の入力として届く経路が無い。ここから出来るのは **伝言** と **権限の許可・拒否（Channels のみ）**、
そして **アプリに引き継ぐ**（アプリの PTY で同じ会話を再開して、以降は通常のルームとして操作する）の 3 つ。

- 見出しに「外部セッション」タグ、その下にバナー（起動元に応じた説明と「アプリに引き継ぐ」ボタン）。
- **引き継げるのはターミナルで対話起動した claude だけ**（`~/.claude/sessions/<pid>.json` の `entrypoint` が `cli` で、`kind` があれば `interactive`）。
  VS Code 拡張（`claude-vscode`）等で動いているセッションは止めると元の画面が壊れるので、ボタンを出さずに理由を表示する（`SessionHandover.unsupportedSourceReason`）。
  `entrypoint` は環境変数 `CLAUDE_CODE_ENTRYPOINT` を引き継ぐので、Claude Code の中（VS Code 拡張の Bash 等）から起動した claude は `cli` にならず引き継げない。
- **伝言**: 入力欄が黄色の「伝言」モードになり（注記「受け手には別セッションからのメッセージとして届きます」）、アプリ内の監視が
  受信箱ソケットへ直接書く（`MonitorStore.sendMessage`）。受け手には `Another Claude session sent a message:` に続けて
  届き、**本人の指示にはならない**（権限承認・スラッシュコマンド・設定変更は不可。v2.1.286 で確認）。
  - 受け手は伝言を `isMeta: true` の user 行として jsonl に残すので、会話履歴には出ない（実機で確認）。そのため
    送った伝言はアプリ側で sessionId ごとに覚え、送信時刻の位置に**点線の吹き出し**で差し込む（アプリを終了すると消える）。
    transcript に写しが出た場合（Claude Code の記録の仕方が変わった時）は、`RelayNotes.removingEchoes` が 1 通につき 1 件だけ取り除いて二重に並べない
    （書き出し付きはいつでも、素の同文は時刻があり送信の 5 秒前〜10 分後のものだけ。届かなかった伝言では消さない）。
  - 送信失敗は吹き出しの下とダイアログに理由を出す（`not_found` / `not_alive` / `no_socket` / `unreachable`）。
- **権限**: 監視の `permissions`（Channels を載せたセッションのみ。アプリ内サーバーの `/api/channel/permissions` に届く）があれば許可 / 拒否カードを出して `store.decide` で返す（二度押し不可）。
  状態が権限待ちのまま 3 秒経っても permissions が無い時は「確認がまだ届いていません。Channels を載せていないセッションは、ここからは答えられません（ターミナルで答えてください）」を出す。
- **アプリに引き継ぐ**: 確認ダイアログ（終了する pid・中断されること・再開すること・元のウィンドウは閉じないこと）→ キャンセルなら何もしない。
  1. 終了対象を確かめる（`SessionHandover.verify`）: 自分の uid / プロセスが claude（argv[0] か実行ファイルの場所）/ `~/.claude/sessions/<pid>.json` が
     その pid で同じ sessionId / 起動元が `cli` の対話セッション / レジストリの `procStart`（無い版は `startedAt`）とカーネルの起動時刻が一致（pid の再利用を見分ける）。
     どれかが外れたら何も送らずに中止する。
  2. SIGINT → 最大 5 秒待つ → 残っていて**同じプロセスのまま**（uid と起動時刻が同じ。実行パスは取れないことがあるので見ない）なら SIGTERM → 最大 3 秒待つ。
     終了を確認できなければ再開しない（同じ会話の二重起動を避ける）。
     終了を確認できても、`~/.claude/sessions/*.json` に同じ sessionId を持つ生存 pid（記録と起動時刻が合うもの）があれば再開しない。
  3. 同じ cwd で `claude --resume=<sessionId>` を PTY で起動する（`launchClaude(in:resumeSessionId:)`。sessionId は UUID 形式
     （`^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$`）のものしかコマンド行に入れず、`=` でつないで別のオプションに化けさせない。API キーの除去と `unset` はそのまま。`--resume` は対話起動の引数で headless ではない）。
     再開しても sessionId は変わらないので、会話はそのまま続き、ルームは通常のホストルームに切り替わる。
  - 上限到達中（`LimitWatch.isLimitReached`）は引き継がない（確認ダイアログの間・終了待ちの間に到達した場合も、止める前／再開前に判定し直す）。
  - **制約: npm 版（node で動く）claude は引き継げない**。実体が `node` で argv[0] も `node` になり、プロセスが claude だと確かめられないため
    安全側に倒して中止する（ネイティブ版 `~/.local/share/claude/versions/<版>` は引き継げる）。

### 設定（settings.json）

管理対象のプロジェクトと GitHub の紐づけは **`~/Library/Application Support/claude-deck/settings.json` だけ**に持つ（アプリにもリポジトリにも埋め込まない）。
試験用に別のファイルを使うときは環境変数 `CLAUDE_DECK_SETTINGS`（JSON のパス）で差し替える。場所は `claude-deck --print-settings-path` で GUI を出さずに確かめられる。

```json
{ "version": 1,
  "projects": [ { "id": "<UUID>", "name": "mirio", "path": "/abs/path", "status": "active", "note": "…",
                  "github": { "owner": "ShinjoSato", "repo": "ailovei", "projectNumber": 4 } } ],
  "boards": [ { "name": "overview", "owner": "ShinjoSato", "number": 5 } ] }
```

- `status` は `active` / `paused` / `archived`。`github` は省略でき、その中の `repo` / `projectNumber` もどちらか片方だけでよい。
  `boards` はリポジトリに紐づかないボード（複数リポジトリを横断するもの等）。
- 書き込みは置き換え（一時ファイル → rename）で、ファイルは 0600。ディレクトリを 0700 に締めるのは既定の場所（`~/Library/Application Support/claude-deck/`）の時だけで、
  `CLAUDE_DECK_SETTINGS` で向けた先のディレクトリの権限は変えない。
- **読めないファイル（JSON でない・形が違う・知らない `version`・同じ `id` や同じ `path` のプロジェクトがある・`path` が絶対パスでない）は上書きしない**。
  設定画面と「+」に理由を出し、直して「読み直す」まで変更を受け付けない。名前が空・owner / repo の文字種・番号などの軽いものは読み込んで、設定画面に警告として出す。
- **外で編集された分**（Claude が `jq` 等で書き換えた等）: アプリは settings.json のあるディレクトリ（置き換え・作成・削除）と settings.json 自体
  （その場の書き換え。`>` のリダイレクト・truncate して書く・VS Code の既定の保存など）を監視して、変わったらすぐ読み直す（自分の書き込みでは読み直さない）。
  置き換えで inode が替わるたびにファイルの監視を張り直し、ファイルが無い間はディレクトリの監視で出現を待つ。
  さらに保存の直前にも読み直し、前に読んだ / 書いた内容から変わっていれば、外の内容に今の変更をかけ直してから保存する（外の追加・変更は残る）。
  かけ直せない変更が 1 つでもある時（編集中のプロジェクトが外で消された等）はその変更を捨て、「外で変更されたため読み直しました」と出す（残りは保存する）。
- **外の変更と文字欄の入力が同じ欄で重なった時は外の変更を残す**（読み直しが先でも保存が先でも同じ）。溜めていた入力は捨てて欄を外の値に合わせ、
  「直前の入力は反映していません」と出す。外の値が入力と同じなら捨てない。
- **書きかけのファイル**（その場の書き換えの途中で空・途中までの JSON）を読んだ時は、読めない旨を出しつつ 0.2 秒・1 秒後に読み直す。溜めていた入力は捨てずに残し
  （欄にも残る。画面に「まだ保存していない入力があります」と出す）、読めるようになったら保存する。
- 案内（青の帯）と書き込みの失敗は、「読み直す」・次の読み直しや保存の成功で消える。案内は × で閉じられる。
- 文字欄（名前・メモ・GitHub の欄）は 0.5 秒まとめて保存する。⏎・フォーカスが外れた時・設定画面を閉じた時・アプリの終了時はすぐ書く。
  日本語の変換中（設定画面がキーウィンドウで、その入力欄に未確定の文字がある間）は書かずに待つ。変換中に状態の切り替え・並べ替え・削除をした時は、
  その操作だけを書き、溜めていた文字欄の変更は変換が終わってから書く。
- **settings.json を外で消した時**: 一度読めた・書けた後に消された場合は、空の一覧として扱い「外で消されました」と出す（`projects.json` から移行し直さない）。
  次に変更した時に作り直す。
- **移行**: settings.json が無い時、以前の版の `projects.json`（同じ場所）があれば取り込んで settings.json を作る。`projects.json` は消さずに残す。
  以前の版が書いた GitHub のキー（`ghOwner` / `ghNumber`）は取り込まない。settings.json に書けなかった時は、読んだ内容を表示したまま書けない旨を出し、
  「読み直す」・次の読み直しで移行をやり直す。`projects.json` が読めない時は取り込まずに理由を出す。
- **旧 TSV からの移し替え（移行後に一度だけ）**: 以前リポジトリにあった `projects/registry.tsv` / `projects/github-projects.tsv` は git の履歴から取り出して、
  設定画面の「書き出し・読み込み」で **registry.tsv → github-projects.tsv の順**に読み込む（逆の順だと repo 付きの行は該当するプロジェクトが無く取り込まれない）。
  ```sh
  git show 34277bd~1:projects/registry.tsv > /tmp/registry.tsv
  git show 34277bd~1:projects/github-projects.tsv > /tmp/github-projects.tsv
  ```

**設定画面**（メニュー「claude-deck → 設定…」⌘,。ウィンドウは 1 つ）のタブ:
- **プロジェクト**: 一覧（ドラッグ・「上へ / 下へ」で並べ替え）、「+」でフォルダを追加、「−」/右クリックで削除（確認あり）、名前・状態・メモの編集。
- **GitHub**: プロジェクトごとの owner / リポジトリ / Project 番号と、リポジトリに紐づかないボードの追加・編集・削除。
  owner は英数字と途中のハイフン（39 文字まで）、リポジトリは英数字と `. _ -`、番号は 1 以上。正しい間だけ保存する。GitHub 上に実在するかは確かめない。
- **iPhone 連携**: 下記「iPhone 連携」の設定（メニュー「claude-deck → iPhone 連携…」はこのタブを開く）。
- **書き出し・読み込み**: settings.json と同じ形で書き出す。読み込みは中身から形式を判断して、足りないものだけを足す（既にあるものは上書きしない）。
  - registry.tsv 形式（name / path / status / note。`#` の行と空行は無視）: 同じパスのプロジェクトは足さない。
  - github-projects.tsv 形式（name / owner / number / repo / url）: repo が `-`（または空）ならボードへ（owner + 番号が同じものは足さない）。
    repo 付きは同じ名前のプロジェクトがあり、まだ紐づけが無ければその `github` に入れる。同じ名前のプロジェクトが無い行は取り込まず
    （ボードにすると repo が落ちるため）、件数と「先に registry.tsv を読み込んでください」を出す。
  - 書き出した settings.json: プロジェクトはパス・ボードは owner + 番号で重複を除く。同じパスのプロジェクトに紐づけが無ければ紐づけだけ足す。

型・読み書き・検証・移行・取り込みは `Sources/MonitorKit/Settings/`（テストあり）、画面は `Sources/ClaudeDeck/Settings/`。

## ビルド / 実行

```sh
cd /Users/shinjo/project/ai-manager/mac
swift build          # ビルド
swift run            # 起動（ウィンドウが開く）
```

### 署名・識別子（`config/`）

チーム ID・バンドル ID・iCloud コンテナはリポジトリに書かず、手元の `config/Local.xcconfig`（git 管理外）に書く。mac の bundle.sh と iPhone の Xcode プロジェクトが同じ値を読む。

```sh
cp config/Local.example.xcconfig config/Local.xcconfig   # 雛形を写して自分の値を書く
```

| キー | 意味 | 既定（`config/Deck.xcconfig`） |
|---|---|---|
| `DEVELOPMENT_TEAM` | Apple Developer のチーム ID | 空（mac は ad-hoc・iPhone は実機に署名できない） |
| `DECK_BUNDLE_PREFIX` | バンドル ID の頭。mac はそのまま、iPhone は `.ios` / `.iosTests` を付ける | `local.claude-deck` |
| `DECK_ICLOUD_CONTAINER` | 要対応の通知に使う iCloud コンテナ | 空（通知は無効） |

- **既に使っている環境では、先に Local.xcconfig に今までの値を書く**。無いまま作るとバンドル ID が `local.claude-deck` に変わり、mac の設定（UserDefaults）・オートメーションの許可・iPhone のペアリングが引き継がれない。
- Local.xcconfig が無くても、シミュレータ向けの iPhone ビルド・テストと、mac の ad-hoc の `.app` は作れる。
- bundle.sh では環境変数 `CLAUDE_DECK_TEAM_ID` / `CLAUDE_DECK_BUNDLE_PREFIX` / `CLAUDE_DECK_ICLOUD_CONTAINER` が（空でも）優先する。
- iPhone のペアリングはキーチェーンに「バンドル ID + `.pairing`」で置くので、`DECK_BUNDLE_PREFIX` を変えるとペアリングし直しになる。

### `.app` として起動する

```sh
cd /Users/shinjo/project/ai-manager/mac
./scripts/bundle.sh            # → mac/dist/claude-deck.app（config/ の値に合うプロファイルがあれば Apple Development、無ければ ad-hoc）
open dist/claude-deck.app      # Finder からのダブルクリックでも可
```

- オプション: `--build-system auto|default|native`（既定 auto）/ `--debug` / `--out <dir>` / `--profile <path>` / `--adhoc`。
- `auto` は通常の `swift build` を試し、失敗したら `--build-system native` で再ビルドする。Metal Toolchain が無い環境では通常ビルドが SwiftTerm の `Shaders.metal` のコンパイルで失敗するため（`xcodebuild -downloadComponent MetalToolchain` で入れれば通常ビルドが通る）。
- 依存のリソースバンドル（`SwiftTerm_SwiftTerm.bundle`）は `Contents/Resources/` に同梱する。claude-deck は SwiftTerm の Metal レンダラーを有効にしていないため、現状このバンドルは参照されない（有効化する場合は SPM の `Bundle.module` が `.app` 直下を探す点に注意）。
- バンドル ID（`CFBundleIdentifier`）と `DeckICloudContainer` は `config/` の値で Info.plist に埋める。署名はチーム ID・コンテナが設定されていて、このアプリ用のプロビジョニングプロファイルがあれば Apple Development（iCloud のエンタイトルメント付き。上の「iPhone への通知」）、無ければ ad-hoc（`codesign -s -`）。Developer ID 署名・公証・配布・自動アップデートはしない。別の Mac へコピーすると Gatekeeper に止められる前提（右クリック → 開く）。
- `/Applications` へ置く場合は `--out /Applications` またはコピー。置き場所に関わらず、設定は `~/Library/Application Support/claude-deck/settings.json` を読む（上の「設定（settings.json）」。Finder 起動には環境変数が渡らないので `CLAUDE_DECK_SETTINGS` は効かない）。
- 生成物 `mac/dist/` と `mac/.build/` は git 管理外。
- アイコン（任意）: `mac/Resources/AppIcon.icns` を置くと同梱される。1024px の PNG から作る例:
  ```sh
  mkdir AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s icon.png --out AppIcon.iconset/icon_${s}x${s}.png
    sips -z $((s*2)) $((s*2)) icon.png --out AppIcon.iconset/icon_${s}x${s}@2x.png
  done
  iconutil -c icns AppIcon.iconset -o mac/Resources/AppIcon.icns
  ```

> 端末から起動すると PATH（`~/.local/bin` の `claude` など）を確実に継承できる。
> アプリ内でも各セッションをログインシェル経由で起動するため、GUI 起動でも `claude` は解決される想定。

## 現状の制約 / TODO

- `.app` は Apple Development / ad-hoc 署名のローカル起動のみ。配布時は Developer ID 署名・公証を検討。
- iCloud 経由の通知は実機（登録済みのコンテナ・プロファイル）では未確認。
- 上限到達の画面表示は実際の上限で出たものを未確認（文言はバイナリから、`⎿` の位置は TUI の描画コードから推定）。表示の形が違えば補助経路だけ効かない（主経路の残量判定は効く）。
- 追加時の表示名はフォルダ名固定（リネーム UI は未実装）。
- ホスト中のルームはアプリを終了すると claude ごと終わる（ルームの保存・復元は未実装）。
- 権限プロンプト・選択メニューの読み取りは端末画面の文言（`Do you want to …?` と `1. Yes`、`❯ n.` の選択肢、`Enter to confirm` 等の操作案内）に依る。
  **Claude Code の TUI の更新で判定を見直す必要がある**: `PTYInput.swift` の `InputBlock` / `ChoiceMenu` / `PermissionPrompt` / `InputBox`、`MenuPrompt.swift`
  （v2.1.286 の trust 確認・AskUserQuestion・plan 承認・入力欄の例文と NBSP で確認）。文言・配置（罫線と ❯ の位置関係、操作案内の有無）に依存している。
  入力欄が上下の罫線で囲まれること・右の差分パネルが縦線 `│` 1 本で区切られることも前提（`ScreenPane.swift`。全角の幅は近似）。
- 選択肢カードからの回答（矢印 + Enter）は、テストのフィクスチャ（v2.1.286 の実画面の写し）で読み取りと手順を確かめたのみで、
  本物の claude で押して先へ進むところは目視で未確認。AskUserQuestion の複数選択（チェックボックス）・複数の問い（タブ）は
  押すたびに今の画面のメニューでカードを出し直す作りで、実画面の写しでは未確認（チェック欄の記号・Enter で切り替わるかも未確認）。「Type something.」の行を「❯」が通過する時の描き方も未確認
  （文言が変わって選択肢の数が読めなくなれば Enter を押さずにやめる）。
- 送った伝言の吹き出しはアプリのメモリにだけ持つ（再起動で消える）。
- 外部セッションの権限カード（Channels 経由の許可 / 拒否）は既存の permissions の経路（アプリ内サーバーに移した）をそのまま使っており、外部ルームでの実機確認はしていない。
- ステージの 3D は、オフスクリーン描画（`SCNRenderer`）の画像を three.js 版の 3D（ヘッドレスブラウザで撮影）と状態ごとに見比べて合わせた。
  アプリの画面上での動き（跳ね・脈・表示中だけ回ること）は目視では未確認。足し算の光は明るい面の上では three.js より控えめに見える
  （three.js は sRGB のまま足すが、SceneKit は線形で足すため。暗い地の上は合わせてある）。
