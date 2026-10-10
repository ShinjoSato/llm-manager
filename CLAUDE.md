# ai-manager

Claude Code を「マネージャー」として運用するためのプロジェクト。
他プロジェクトの管理と、Claude Code セッションの司令塔（mac アプリ claude-deck。セッション監視もアプリの中で動く）を担う。

## 役割

私（Claude）はこのリポジトリにおいて、複数の対象を横断的に把握・調整する**マネージャー**として振る舞う。
ユーザーから依頼を受けたら、まず関連する登録簿・データを確認してから動く。

## 運用ルール（重要）

- **言語**: 日本語でやり取り・応答する。ドキュメント・コメントも日本語を基本とする。
- **「開発状況を確認して」= GitHub Project ボードを見る**: ユーザーが「開発状況を確認」「○○の状況」と言ったら、まず GitHub Project（ボード）を確認する。ローカル git status や PR 一覧は主役にしない（補足としてなら可）。手順は下の「GitHub Project（ボード）連携」。
- **記録はこのプロジェクト内に残す**: マネジメントに関わるルール・方針・知見は永続メモリではなく ai-manager 内（CLAUDE.md や `docs/` 等）に記載する。それがこのプロジェクトの目的。

## 機能と現状

| 機能 | 状態 | 場所 |
|------|------|------|
| 他プロジェクト管理 | 手動運用 | `~/Library/Application Support/claude-deck/settings.json`（mac アプリの設定画面で編集） |
| claude-deck（Claude Code 司令塔アプリ） | PoC（Swift/macOS・ビルド可） | `mac/` |
| Claude Code セッション監視（リアルタイム） | 稼働（mac アプリの中・:8766 でフックを受ける） | `mac/Sources/MonitorKit/Hub`・`Server` |
| 権限確認の中継（Channels） | 実装済み（実機の claude では未確認） | `mac/Sources/ClaudeDeckChannel`・`mac/Sources/MonitorKit/Channel` |
| 上限の残量（statusLine） | 稼働 | `mac/scripts/statusline.sh` |
| iPhone 連携の口（同じ Wi-Fi・TLS・ペアリング） | mac 側実装済み（既定は無効） | `mac/Sources/MonitorKit/Remote`・`mac/Sources/ClaudeDeck/Remote`・仕様 `mac/docs/remote-api.md` |
| iPhone アプリ（claude-deck iOS） | 実装済み（シミュレータで確認・実機と TestFlight は未確認） | `ios/`（詳細 `ios/README.md`） |
| mac / iPhone の共有パッケージ（DeckCore） | 稼働 | `packages/DeckCore` |
| 要対応の iPhone 通知（iCloud・CloudKit のプライベート DB） | 実装済み・**保留中（既定で無効）**。コンテナ・App ID・プロファイルの登録を見送っている（2026-10-05 ユーザー判断） | `mac/Sources/ClaudeDeck/Notify`・`ios/ClaudeDeck/Notify`・`packages/DeckCore/Sources/DeckCore/Notify`（手順 `mac/README.md`「iPhone への通知」） |
| スプレッドシート勉強管理 | 未着手 | - |

構成は `mac/`（claude-deck）に一本化した。セッション監視・会話の記録・フックの受け口（127.0.0.1:8766）はアプリの中で動き、
Channels のチャネル（`claude-deck-channel`）と statusLine（`mac/scripts/statusline.sh`）も mac 側にある。旧 `monitor/`（Node）は削除済み。
管理対象と GitHub の紐づけは mac アプリの設定（`settings.json`）に持ち、使用量は statusLine が `~/Library/Application Support/claude-deck/usage.json` に書いて mac アプリが読む。

## 他プロジェクト管理

- 管理対象とボードの紐づけは mac アプリの設定 `~/Library/Application Support/claude-deck/settings.json` が唯一の正（形は `mac/README.md`「設定（settings.json）」）。リポジトリには置かない。アプリは 0600 で置き換えて書く。試験では `CLAUDE_DECK_SETTINGS` で差し替えられ、場所は `claude-deck --print-settings-path` で出せる。
- **管理対象・ボードを知りたい時は settings.json を `jq` で読む**:
  - 管理対象: `jq -r '.projects[] | [.name, .path, .status] | @tsv' ~/Library/Application\ Support/claude-deck/settings.json`
  - ボード: プロジェクトに紐づくものは `.projects[].github`（owner / repo / projectNumber）、リポジトリに紐づかないものは `.boards[]`（name / owner / number）。
    例: `jq -r '(.projects[] | select(.github.projectNumber) | [.name, .github.owner, .github.projectNumber, (.github.repo // "-")]), (.boards[] | [.name, .owner, .number, "-"]) | @tsv' <settings.json>`
  - リンク（LP 等）: `.projects[].links[]`（name / url と、省略できる kind / pinned / note / reminderDay。無いプロジェクトにはキー自体が無い）。
  - サイト（LP の場所）: `.projects[].site.path`（プロジェクトからの相対パス。無ければアプリが自動で探す。無いプロジェクトにはキー自体が無い）。
- **管理対象の追加依頼を受けたら**: 基本はユーザーにアプリの設定画面（「claude-deck → 設定…」⌘,）で追加してもらう。頼まれたら settings.json を編集する（id は新しい UUID・パスは絶対パス・status は active / paused / archived・`version` は変えない）。アプリが動いていれば、ディレクトリとファイル自体の監視ですぐ読み直して反映される（`jq … > tmp && mv` の置き換えも、その場の書き換えも拾う。設定画面で編集中でも、アプリの保存は直前に読み直して外の変更を残したうえで書き、同じ欄の入力とぶつかれば外の変更を残す）。書き換えの途中を読んだ時は少し待って読み直す。一度作られた後に settings.json を消すと空の一覧として扱い（projects.json から移行し直さない）、次の変更で作り直す。壊れた JSON・知らない version・同じ id / path の重複・相対パスはアプリが上書きせず読めない旨を出すので、編集後は `jq . <settings.json>` で確かめる。
- **旧 TSV（registry.tsv / github-projects.tsv）の移し替え**: 移行後に一度だけ、git の履歴から取り出して（`git show 34277bd~1:projects/registry.tsv > /tmp/registry.tsv`、`git show 34277bd~1:projects/github-projects.tsv > /tmp/github-projects.tsv`）設定画面の「書き出し・読み込み」で registry → github-projects の順に読み込む（手順は `mac/README.md`「設定（settings.json）」）。
- 兄弟プロジェクトは `/Users/shinjo/project/` 配下にある。ローカルの様子を補足で見る時は `git -C <path> status -sb` 等を直接使う。
- mirio が中心プロダクト。infra（mirio-prod の deploy など）と blog（Mirio 関連ページ）は mirio に関連する作業を含むため、mirio の動きと連動して見ると良い。

### GitHub Project（ボード）連携
- 管理対象とボードの紐づけは settings.json の `.projects[].github` と `.boards[]`（上の `jq` の手順で引く）。
- ボード状況は `gh` で直接取る。settings.json で owner と number を引き、
  `gh project item-list <number> --owner <owner> --format json --limit 200` を実行する（既定の件数は 30 なので `--limit` を付ける）。
  - 未完了だけ: `... --jq '.items[] | select(.status != "Done") | [.status, .title, (.content.number // "-")] | @tsv'`
- 前提: `gh` CLI 認証済み（`ShinjoSato`、`project` スコープ）。ステータスは Todo / In Progress / Debug / Done。
- **infra は専用ボード未作成**。横断作業は overview（リポジトリに紐づかないボード）で追う。専用ボードを作ったら設定画面の GitHub タブで紐づけてもらう。
- overview はステータスが Todo / In Progress / **Review** / Done（Debug ではない）。
- 停滞検知（In Progress のN日放置）は item-list に更新日時が無いため未実装。GraphQL で `updatedAt` を取れば追加可能（将来）。
- 現状は**手動運用**。ユーザーが話しかけたときに動く。定期実行などの自動化は未導入。

## claude-deck（Claude Code 司令塔アプリ）

`mac/` にある Swift/macOS ネイティブアプリ（SPM 実行ファイル `claude-deck`）。プロジェクトごとに `claude`（Claude Code）を PTY でホストし（SwiftTerm）、セッションをチャットアプリの操作感（トークルーム）で扱う。
**画面・挙動の詳細と各ファイルの役割は `mac/README.md`**（下の「」は README の節名）。機能を変えたら README の該当の節も直す。

- **設計の絶対方針（料金事故ゼロ）**: 子プロセスの環境から `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` を必ず除去して `claude` を起動する（Claude Code の中から起動された時の `CLAUDE_CODE_*` 等の子セッション印も除く）。API 課金経路を作らないため、Max 枠の上限に達しても課金は発生しない（待つだけ）。**headless（`claude -p` / Agent SDK）の起動口は設けない方針**。サイトの開発サーバー（`npm run dev`）もプロジェクトのスクリプトを動かすだけで、同じく API キー・子セッション印を除いた環境で起動する。
- **上限到達で強制終了**: 公式の残量（アプリ内の監視が statusLine の書いた使用量ファイルから読む `MonitorStore.usage`。5 時間 / 7 日間が 100% 以上かつ取得 10 分以内）を主、端末の実画面の末尾に出た上限表示（Claude Code v2.1.286 のバイナリで確認した文言のみ・会話本文は見ない）を補助として、ホスト中の全セッションを `terminate()`。到達はリセット時刻まで覚え（`limit-state.json`）、その間の新規起動・再開・引き継ぎも止める。判定は `mac/Sources/MonitorKit/Limit/LimitGuard.swift`（テストあり）、購読は `mac/Sources/ClaudeDeck/App/LimitWatch.swift`。残量経路は statusLine（`mac/scripts/statusline.sh`）の設定が前提。
- **画面の構成**:
  - 左端の切り替えバーで左の一覧を「ルーム」（監視のセッション + ホスト中のセッションを要対応 / 稼働中 / 待機で並べる）と「ディレクトリ」（設定に登録したプロジェクト。最上部の固定行「リンク」で横断のリンク一覧）に切り替える。「一覧の切り替えバー」「ルーム一覧」
  - 中央は `ChatModel.center` で、会話（`TranscriptStore` から組み立てたチャット。端末ビューは画面に載せず、PTY の受信と画面読み取りだけに使う）・ディレクトリの詳細（見出しの操作と、その下のタブ（サイト・画像・iPhone・リンク・スレッド）で選んだ節だけを欄いっぱいに出す本文。サイトと iPhone は該当しないプロジェクトでは出さず、最後に開いたタブをプロジェクトごとに覚える。判定は `mac/Sources/MonitorKit/Projects/DirectoryTabs.swift`）・横断のリンク一覧を出し分ける。「会話（中央）」「ルーム一覧」
  - 見出しのボタン（VS Code・GitHub・リンク・ピン・Xcode・閉じる・別ウィンドウで開く・ディレクトリでは起動・Finder・設定で編集）はアイコンだけで、入りきらなければ優先度の低いものから「…」へ回す。「Xcode」「閉じる」は `.xcworkspace` / `.xcodeproj` がある時だけで、「閉じる」は AppleScript でそのワークスペースだけを閉じる（初回は macOS のオートメーション許可が要る）。
  - 右はステージパネル（360px。SceneKit の 3D ステージと、選択中のルームのプロジェクトの LP のプレビューを切り替える）。「ステージパネル」
  - ルームは一覧の右クリックか見出しのボタンで別ウィンドウにも開ける（`RoomWindows`・同じルームは 1 枚・中身は同じ `ConversationView` で送信と回答は同じ経路・下書きと添付はルームごとに共有・メインで他を見ている間も取得と既読を続ける・別ウィンドウ同士は macOS のタブにまとめられる・閉じてもセッションは止めない・復元しない）。「別ウィンドウ」
  - 設定画面（「claude-deck → 設定…」⌘,）のタブはプロジェクト・GitHub・iPhone 連携・キャラクター・書き出し・読み込み・起動と終了・外観（ナイト / ライト）。「設定（settings.json）」
  - コードは画面が `mac/Sources/ClaudeDeck/`（`Chat/Model/`・`Chat/Views/` の `RoomList` / `Directory` / `Links` / `Conversation` / `Composer`・`Terminal/`（`ClaudeTerminalView` を `+Launch` / `+Input` / `+Screen` / `+Limit` の extension に分ける）・`Stage/`・`Settings/`）、UI に依らない判定は `mac/Sources/MonitorKit/`（テストあり）。
- **ホスト中のセッションへの送信と回答**: 入力欄は ⏎ 送信・⇧⏎ 改行で、PTY に bracketed paste で本文を入れ、入ったのを画面で確かめてから Enter（画像は先にパスを貼って `[Image #N]` を確かめる）。**端末で選択待ち（権限プロンプト・plan 承認・AskUserQuestion・trust 確認・入力欄に重なったダイアログ・セッションファイルの `waitingFor`）の間は送らない**（Enter が選択の確定になるため）。権限カードは Channels があれば `store.decide`、無ければ端末に許可 `1` / 拒否 `Esc`。選択肢カードは ↑/↓ で「❯」を 1 行ずつ動かし、着いたのを画面で確かめてから Enter（番号キーは使わない）。どれも押した時のカードと今の画面が違えば送らない。「入力欄と PTY への送信」「権限カード」「選択肢カード」
  - **Claude Code の TUI を更新したら判定を見直す**: `mac/Sources/MonitorKit/Chat/PTYInput.swift`・`MenuPrompt.swift`・`ScreenPane.swift`（入力欄は上下に罫線・メニューは ❯ の下を罫線で閉じない、重ね表示のダイアログは入力欄の上の罫線に案内行が接する、差分パネルは縦線 1 本で区切る、が前提。v2.1.286 / v2.1.288 で確認）。選択肢カードは本物の claude での目視が未確認。
- **外部セッション（ターミナル等で起動したもの）**: 入力欄は「伝言」（受信箱ソケットへ直接書く。本人の指示・権限承認にはならない）、権限は Channels がある時だけ許可 / 拒否。「アプリに引き継ぐ」は同じ sessionId の claude かを確かめて SIGINT → SIGTERM し、終了を確認できて同じ sessionId の生存 pid が他に無い時だけ同じ cwd で `claude --resume=<sessionId>`（UUID 形式のみ）を PTY で起動する（ターミナル起動の対話セッションだけ・npm 版は不可）。「外部セッション」
- **終了と次の起動**: ホスト中のセッションを `hosted-sessions.json` に記録し（隣の `.lock` を flock で持ち、別の claude-deck が動いていれば再開も書き込みもしない）、次の起動で `claude --resume=<sessionId>` で再開して、稼働中だったものには続きを頼む。上限到達中・同じ会話が動いている・直前の自動再開で落ちた時は見送りとして帯に出す。⌘Q・ウィンドウを閉じる時に稼働中・権限待ちがあれば確認を出す。「終了と次の起動」
- **サイト（LP）のプレビューと開発サーバー**: ディレクトリの詳細とステージパネルで、Next.js の書き出し（`out/`）をアプリ内の静的配信（サイトごとに 127.0.0.1 の OS が選ぶポート・GET / HEAD のみ・`out/` の配下だけ・LAN には出さない）で見る。開発サーバー（`npm run dev`）は ▶ を押した時だけ起動し（自動起動しない）、ルームではなくプロジェクトに付く（ルームを閉じても止めない）。停止・アプリの終了・設定からの削除でプロセスグループごと止めるが、アプリの強制終了・クラッシュでは残りうる。「ルーム一覧」の「サイト」
- **iPhone のプレビュー**: `.xcodeproj` / `.xcworkspace` のあるプロジェクトの詳細で、Swift ソースの `#Preview` を静的に拾って並べ、**起動中の Xcode の MCP（`xcrun mcpbridge` の `RenderPreview`）**で 1 件ずつ描いて `~/Library/Caches/claude-deck/ios-previews/` に写す。**呼ぶツールは Open / Close / ListWorkspaces / Glob / RenderPreview の許可リストだけ**（書き換え・Run・テストは呼ばない）。mcpbridge は 1 本・プロセスグループで起動し、「iPhone」のタブを離れて 3 分・アプリの終了・設定からの削除で止める（タブを離れたプロジェクトの待ち行列は取りやめる）。走査も描画もタブを開いた時だけ。描くたびに動いている Xcode を数え直し、その Xcode の `DEVELOPER_DIR` を渡す（`MCP_XCODE_PID` は渡さない。渡すと GUI の Xcode へ直につなぎ、ウィンドウが無いと断られる）。利用者・他の相手が開いていたワークスペースは閉じない（開く前の `XcodeListWorkspaces`）。ソースは変えない。初回は Xcode のメニューバーの MCP のアイコンで許可が要る。「ルーム一覧」の「iPhone のプレビュー」
- **リンク**: settings.json の `links`（名前・URL・種類・ピン・メモ・毎月の確認日）を見出しの「リンク」・ピンのボタン・ディレクトリの詳細・横断のリンク一覧から開く。開くのは http / https で host のあるものだけ。最終確認日は `link-visits.json`、確認の印はアプリの中だけ（通知はしない）。「会話（中央）」「ルーム一覧」「設定（settings.json）」
- **アプリ内サーバー（:8766）**: `127.0.0.1:8766` で `POST /hook`・`POST /api/channel/permissions`・`GET /api/health` だけを出す（Host / Origin / 接続元はループバックのみ）。ポートは `CLAUDE_DECK_SERVER_PORT`（`off` で開かない）。**アプリ側の SIGTERM / SIGINT は `SIG_IGN` にしない**（exec を越えてホスト中の claude に残り、上限到達時の `terminate()` が効かなくなる。何もしないハンドラで捕捉して通常の終了経路に乗せる）。実装は `mac/Sources/MonitorKit/Server/`。「アプリ内サーバー（:8766）」
- **iPhone 連携の口**: 設定画面の「iPhone 連携」タブで有効にした時だけ（**既定は無効**）、選んだ LAN のインターフェースの IPv4・既定ポート 8767 で **TLS のみ**で待ち受ける（0.0.0.0 にはしない。`/hook` 等は LAN に出さない）。自己署名の証明書を QR の指紋で iPhone にピン留めさせ、端末トークン（mac にはハッシュだけ）で全 API を Bearer で受ける。**iPhone からの操作は `ChatModel+Remote.swift` が画面のカード・入力欄と同じ処理に渡す**（`promptId` / `menuId` が今のものと一致する時だけ・選択待ちでは送らない）。有効にした時と別のネットワークでは開かない。新しい claude の起動口・headless の口は無い。実機ではファイアウォールの「受信接続を許可」を確かめる。仕様は `mac/docs/remote-api.md`。「iPhone 連携」
- **要対応の iPhone 通知（iCloud）**: 要対応が 5 秒続いたら自分の iCloud（CloudKit のプライベート DB）にレコード `AttentionNotice`（ルーム名・定型文・時刻・ルーム / セッション ID だけ。**会話の本文・ツールの入力は載せない**）を書き、解消したら消す。**コンテナが空・未定義の起動（`swift run` を含む）と、エンタイトルメントの無い起動（ad-hoc）では無効**。**iCloud コンテナ・App ID・プロファイルの登録はユーザーが行う**（コンテナは消せない。Claude は `-allowProvisioningUpdates` も実行しない）。手順は「iPhone への通知（iCloud・CloudKit）」。
- **ビルド/実行**: `cd mac && swift build` / `swift run` / `swift test`。Swift 6.3 / Xcode 26.5 で確認済み（Swift 6.4 / Xcode 27 では `--build-system native` を付けて確認）。
- **署名・識別子**: チーム ID・バンドル ID・iCloud コンテナはリポジトリに書かず、`config/Local.xcconfig`（追跡しない。雛形は `config/Local.example.xcconfig`）に `DEVELOPMENT_TEAM`・`DECK_BUNDLE_PREFIX`・`DECK_ICLOUD_CONTAINER` を書く。既定（`config/Deck.xcconfig`）はチーム・コンテナ空・`local.claude-deck`。iPhone の Xcode プロジェクトは全構成が `Deck.xcconfig` を土台にし、mac の bundle.sh も同じファイルを読む（環境変数 `CLAUDE_DECK_TEAM_ID` / `CLAUDE_DECK_BUNDLE_PREFIX` / `CLAUDE_DECK_ICLOUD_CONTAINER` で上書き可）。「署名・識別子」
- **`.app` 化**: `mac/scripts/bundle.sh`（`--help` で使い方）→ `mac/dist/claude-deck.app` → `open mac/dist/claude-deck.app`。チーム ID とコンテナが設定されていて、このアプリ用の macOS のプロビジョニングプロファイルがあれば Apple Development で署名して iCloud のエンタイトルメントを付け、無ければ ad-hoc。チャネル `Contents/MacOS/claude-deck-channel` も同梱。Metal Toolchain が無い環境では自動で `--build-system native` に切り替える。Developer ID 署名・公証・配布・自動更新はしない。「`.app` として起動する」

## 共有パッケージ DeckCore（`packages/DeckCore`）

mac アプリと iPhone アプリで共有する、プラットフォームに依存しない部分（Foundation / Security / CryptoKit だけ・macOS 14 / iOS 17）。
- 中身: 監視のドメイン型（`Models/MonitorModels.swift`・`LenientStringEnum`）、Remote API の型とピン留め（`Remote/`）、
  Markdown の解析・会話の組み立て（ツールを畳む・伝言の差し込み・画像の印・`TranscriptBuffer`）・ルームのグループ化（`Chat/`）、
  ドット絵キャラ（`Pixel/`）、iPhone 向けのクライアント（`Client/`: ピン留めの URLSession・要求の組み立て・SSE・結果コードの文言・接続の失敗の案内・再接続の待ち）。
- mac の `MonitorKit` は DeckCore にローカル依存（`.package(path: "../packages/DeckCore")`）し、`@_exported import` で再公開する（画面側の import はそのまま）。
- テスト: `cd packages/DeckCore && swift test`。mac 側の `RemoteClientIntegrationTests` は mac の口をループバックに立て、DeckCore のクライアントで QR → ペアリング → 一覧 → SSE → 操作 → 取り消しまで通す。

## iPhone アプリ（`ios/`）

SwiftUI・iOS 17 以上・iPhone のみ。バンドル ID `$(DECK_BUNDLE_PREFIX).ios`・チームは `DEVELOPMENT_TEAM`（どちらも `config/Local.xcconfig`）・配布は TestFlight（アーカイブ・アップロードはユーザーが行う）。詳細は `ios/README.md`。
- Xcode プロジェクト `ios/ClaudeDeck.xcodeproj` は手書き（フォルダ同期のグループなので、`ios/ClaudeDeck/`・`ios/ClaudeDeckTests/` にファイルを置けば自動で入る）。DeckCore はローカルの Swift Package として参照。共有スキーム `ClaudeDeck`。
- 画面: ペアリング（カメラで QR・貼り付け・`claude-deck://pair` で開かれたリンク。**どれも名前と指紋の確認画面を経てから送る**）、ルーム一覧、会話、権限 / 選択肢カード、入力欄、接続の設定（解除）。見た目・文言は mac のチャット画面にそろえる（`ios/ClaudeDeck/Theme/DeckTheme.swift`）。
- 接続: `/v1/events?transcripts=*` を 1 本張り、届いた `state` で一覧、`transcript` で開いている会話の追記と未読を数える。切れたら理由（別の Wi-Fi・スリープ・口が無効・回数制限・指紋違い・取り消し）と案内を出し、1→30 秒の指数的な待ち（回数制限は 1〜2 分）で張り直す。裏に回ったら閉じ、前に出たら張り直す。指紋違い・取り消しは再ペアリングを促して止まる。
- 鍵: 接続先・指紋・端末トークンはキーチェーン（`AfterFirstUnlockThisDeviceOnly`）。
- 通知: 設定の「要対応を通知する」（既定は切）で通知の許可と iCloud の購読（`ios/ClaudeDeck/Notify/`）。通知を開くと該当ルームへ（未接続なら案内を出して、つながったら開く）。エンタイトルメントは `ios/ClaudeDeck.iCloud.entitlements`（`aps-environment`・iCloud）で、**既定のビルドには付けない**（実機の自動署名が消せないコンテナを勝手に登録しないため。有効にする時に `CODE_SIGN_ENTITLEMENTS` に設定する）。
- TLS: CA の検証はせず、証明書の SHA-256 がピンと一致した時だけ `.useCredential`。ATS の例外は `NSAllowsLocalNetworking` だけ。`ITSAppUsesNonExemptEncryption` は false（暗号は OS の TLS と、指紋の SHA-256 だけで、輸出規制の申告が要らない範囲のため）。
- 画面確認用: Debug ビルドを `-demo rooms` / `-demo conversation` の起動引数で開くと、通信せずに見本のデータで描く。
- ビルド / テスト: `xcodebuild -project ios/ClaudeDeck.xcodeproj -scheme ClaudeDeck -destination 'platform=iOS Simulator,name=iPhone 17' build`（`test` でユニットテスト。アプリの中で自己署名の TLS に指紋だけで繋がる試験を含む）。

## Claude Code セッション監視（mac アプリの中）

複数リポジトリで同時に走っている Claude Code の状況をリアルタイムに集約する。**mac アプリの中で動く**（`mac/Sources/MonitorKit/Hub`・`Server`・`Channel`）。
読み取り専用で、`~/.claude` は読むだけ。
詳細と Claude Code 側の設定手順（フック・statusLine・Channels）は `mac/README.md` の「Claude Code 側の設定」。

- 窓口は `SessionHub`（actor）。層ごとの型（`InventoryScanner` / `TranscriptPoller` / `HookIntake` / `PermissionWaiters` / `UsagePoller`）を同じ actor の上で順に回し、セッションの辞書と配信（フィード・スナップショット）は `SessionHub` だけが持つ。セッションごとの状態は `SessionState`（書く層ごとに欄を分ける）。
- **在庫層**（3秒・`InventoryScanner`）: `~/.claude/sessions/<pid>.json` + `kill(pid,0)` で稼働セッション一覧を復元。
- **実況層**（250ms・`TranscriptPoller`）: `~/.claude/projects/<slug>/<sessionId>.jsonl` の末尾差分から実行中ツール・ブランチ・作業内容・トークン量を取る。`ai-title` は先頭寄りにしか出ないため初回だけ広く遡る（`primeMeta`）。
- **フック層**（任意・`HookIntake`）: アプリ内サーバーの `POST /hook`（:8766）。**「なぜ止まっているか」（権限待ち・入力待ち・APIエラー）はログに一切残らない**ので、これはフックでしか取れない。`mac/README.md` のスニペットを `~/.claude/settings.json` に入れる（**`async: true` 必須**。付けないと全プロジェクトの応答をブロックする）。宛先は `http://localhost:8766/hook`。
- **上限の残量**（任意）: `mac/scripts/statusline.sh` を `~/.claude/settings.json` の `statusLine` に指定すると、Claude Code が渡す `rate_limits` を表示したうえで `~/Library/Application Support/claude-deck/usage.json` に原子的に書く（`CLAUDE_DECK_USAGE_FILE` で差し替え）。mac アプリが 3 秒ごとに読み、上限到達の強制終了に使う。セッションが全て止まると値が古くなるので取得時刻を見る。**`~/.claude/settings.json` は Claude が勝手に書き換えない**（差し替えはユーザーの了承を得てから）。
- **権限確認に答える**: Claude Code の **Channels**（permission relay）で、ツール使用の許可・拒否を claude-deck の画面から出せる。
  チャネルは `claude-deck-channel`（SPM の実行ファイル。stdio の MCP サーバーを外部ライブラリ無しで最小限に実装）。対象リポジトリの `.mcp.json` に
  実行ファイルの絶対パス（`.app` なら `mac/dist/claude-deck.app/Contents/MacOS/claude-deck-channel`）を `command` で登録し、
  `claude --dangerously-load-development-channels server:<name>` で起動する。チャネルはアプリ内サーバーの `/api/channel/permissions` に長ポーリングで預け、
  申請元は親 PID で引く（間にシェル等を挟まない）。宛先は `CLAUDE_DECK_URL`（http のループバックのみ。外れていれば既定に戻す）。**答えられるのは手元（ループバック）だけ**
  （スマホからの承認は `claude --remote-control` が担う）。返せるのは `allow` / `deny` のみ。
- **8766 を別のプロセスが使っている時は奪わず・止めず**、ルーム一覧にフックが届かない旨を出して監視は続ける。そのプロセスを止めれば 5 秒以内にアプリが受け口を引き継ぐ。アプリが動いていない間のフックは取りこぼす（curl は 1 秒で諦めるだけ）。
- 制約: macOS ローカルのセッションのみ（クラウドセッションは映らない）。ログの粒度はターン／ツール単位で、生成中テキストは流れない。

## スプレッドシート勉強管理

- 未着手。着手時に方針をここに追記する。

## メモ
- **開発ブランチと preview の運用**: 開発ブランチは Issue ごとに **develop から**切る（他の開発ブランチの上に積まない）。完成したものは **preview に develop + 完成した全ブランチをまとめてマージ**し、ユーザーは preview 1 つで確認する（新しく完成するたびに preview を develop から作り直して全部入れ直す）。同じ箇所を触るブランチ同士がぶつかったら preview のマージで解消し、develop へのマージ時は後のブランチに develop を取り込んで解消する。「preview-done」は preview に入っている PR をまとめてマージする合図として扱う（一部だけなら番号を確かめる）。
- GitHub リポジトリは `ShinjoSato/llm-manager`（ベースブランチは develop）。`.gitignore` でビルド成果物（`mac/dist/`・`.build/` 等）と手元だけで持つもの（下記）を除外。
- **手元だけで持つもの（git で追跡しない）**: `config/Local.xcconfig`（署名・識別子）、`.claude/github-project.json`（開発フローの設定）、
  `~/Library/Application Support/claude-deck/`（settings.json・iPhone 連携の証明書と端末トークン・usage.json・hosted-sessions.json・limit-state.json・link-visits.json）。リポジトリに秘密情報の置き場は無い。
- 開発フロー（developer-plugin）の設定 `.claude/github-project.json` は **git で追跡せず手元で持つ**（GitHub の owner・リポジトリ・Project の各 ID を含むため）。
  新しい clone では `.claude/github-project.example.json` をコピーして値を入れるか、developer-plugin の `project-init` で作る。無いと Issue〜PR の skill は動かない。
  - スクリプトはカレントから上へ探すので、`.claude/worktrees/` の中からでも本体のファイルを読む。
  - このファイルを追跡していた頃のコミット・ブランチと行き来すると git が手元のファイルを消すことがある。消えたら作り直す。
- 旧ダッシュボード（データ中核 server・Web・MCP・App Store / Google カレンダー連携・補助シェル）は使われていなかったため削除済み。App Store の確認は appstore-plugin の skill、カレンダーは claude.ai の Google Calendar MCP を使う。
