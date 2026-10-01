# claude-deck

プロジェクトごとに **Claude Code を同時起動**し、セッションを**チャット（トークルーム）**として扱う macOS ネイティブ司令塔アプリ（PoC）。
ai-manager の管理対象プロジェクト一覧と連携し、各プロジェクトのディレクトリで `claude` を端末として起動する。

SwiftTerm（VT100/Xterm エミュレータ + PTY ホスト）を使い、Terminal.app 同等の操作感を持たせている。

## 設計上の方針（重要）

- **料金事故ゼロ**: 子プロセスの環境から `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` を必ず除去して `claude` を起動する。API 課金経路が存在しないため、Max 枠の上限に達しても「待つ」だけで課金は発生しない。さらにログインシェル側でも `unset` してから `exec claude` する二重防御。
- **headless 不採用**: `claude -p` / Agent SDK の起動口は一切設けない（別枠課金や非対話実行を避ける）。
- **上限到達で強制終了**: 次のどちらかで上限到達とみなし、アプリでホストしている全セッションを `terminate()` で強制終了して警告ダイアログを出す。判定は `Sources/MonitorKit/LimitGuard.swift`（テストあり）、残量の購読は `Sources/ClaudeDeck/LimitWatch.swift`。
  1. **公式の残量（主）**: statusLine の `rate_limits` を monitor 経由で受けた `MonitorStore.usage` で、5 時間 / 7 日間のどちらかが 100% 以上、かつ取得から 10 分以内。古い値・未取得では落とさない（statusLine 未設定なら この経路は働かない）。一度到達したらそのウィンドウのリセット時刻まで覚えておき、その間に起動したセッションも起動直後に止める（新しい値で 100% 未満になれば解除）。
  2. **画面の上限表示（補助）**: 生の出力ではなく端末の実画面の末尾だけを見る。入力欄より下（フッター）、入力欄直上の最後の `⎿` 行（API エラー表示）、上限到達時に自動で開くメニューの「Stop and wait for limit to reset」。会話本文に同じ文言が出ても落ちない。文言は Claude Code v2.1.286 のバイナリ内で上限判定に使われている書き出し（`You've hit your` / `You've reached your` / `You're out of usage credits` / `You're now using usage credits` 等の課金枠切替 / `Usage limit reached`）に絞っている。
  - 起動直後（対話 zsh が `claude` に exec する前）は SIGTERM が効かないので、1.5 秒後に残っていれば SIGKILL する。

## 構成

```
mac/
  Package.swift                 SPM。SwiftTerm を依存に持つ実行ファイル "claude-deck"（SwiftTerm はリビジョン固定。更新時は Package.swift の revision を書き換える）
  Sources/ClaudeDeck/
    main.swift                  NSApplication 起動
    AppDelegate.swift           ウィンドウ + メニュー
    MainViewController.swift    メインウィンドウ = チャット画面（SwiftUI を NSHostingView で載せる）
    Chat/                       チャット画面（ルーム一覧・会話・入力欄・権限カード）
      ChatRootView.swift          3 カラムの骨組み（ルーム一覧 | 会話 | 右パネルの差し込み口）
      ChatModel.swift             ルーム（monitor のセッション + ホスト中のセッション）・会話履歴・権限確認の状態
      HostedSession.swift         アプリが PTY でホストする claude 1 つ（ルームを切り替えても端末とプロセスを保持）
      RoomListView.swift          ルーム一覧・検索・「+」（新しいルーム・プロジェクト一覧の管理）・残量
      ConversationView.swift      見出し・吹き出し・ツール行・権限カード・チャット / ターミナル / GitHub / App Store 切替
      Composer.swift              入力欄（⏎ 送信 / ⇧⏎ 改行）
      AppKitHosts.swift           既存の端末ビュー / GitHub ボード / App Store 表示を SwiftUI に差し込む
      ChatTheme.swift             画面案B の色・文字のトークン（ダーク固定）
    ProjectStore.swift              プロジェクト一覧の永続化（Application Support の JSON）
    GitHubProjectPrompt.swift       プロジェクトに GitHub Project（owner/number）を紐づける入力ダイアログ
    SidebarViewController.swift     旧: プロジェクト一覧（メインウィンドウからは外した）
    TileContainerViewController.swift 旧: タイル状グリッド（メインウィンドウからは外した）
    TerminalPaneViewController.swift 旧: 1ペイン = Claude Code / GitHub / App Store を切替（`findXcodeProject` はチャット画面も使う）
    GitHubBoard.swift               github-projects.tsv 読込 + gh によるボード取得
    GitHubBoardView.swift           Issue をステータス別にグループ表示（クリックで GitHub を開く）
    AppStoreClient.swift            appstore.tsv 読込 + server HTTP API（/api/appstore）の取得
    AppStoreView.swift              審査/提出/ビルド/評価サマリ表示（Web の AppStoreCard 相当）
    ClaudeTerminalView.swift    PTY ホスト + 環境からの API キー除去 + 画面末尾の上限表示の監視
    LimitWatch.swift            公式の残量で上限到達を見て、ホスト中の全端末を止める
    ProjectRegistry.swift       projects/registry.tsv のパーサ
    AIManagerRoot.swift         ai-manager ルートの解決（.app 起動でも TSV / monitor を引ける）
    MonitorBridge.swift         アプリ全体で 1 つの MonitorStore（SSE 接続は 1 本）+ monitor 自動起動の配線
  Sources/MonitorKit/           monitor（:8766）クライアント。UI 無し・テスト可能な library
    MonitorModels.swift         monitor/src/types.ts に対応する Codable 型
    SSEParser.swift             text/event-stream の逐次パーサ（URLSession の生バイトを自前で解釈）
    MonitorEvent.swift          sessions / feed / feed-batch / usage / permissions / transcript のデコード
    MonitorConfiguration.swift  接続先・無通信タイムアウト・再接続バックオフ
    MonitorClient.swift         SSE 購読（自動再接続）+ REST / 書き込み系ラッパー
    MonitorLauncher.swift       monitor の自動起動・停止（@Observable の phase で状態を公開）
    MonitorStore.swift          @Observable ストア（接続状態・セッション・フィード・残量・権限確認・pid 対応付け）
    ClaudeSessionRegistry.swift ~/.claude/sessions/<pid>.json から sessionId を引く
    LimitGuard.swift            上限到達の判定（公式の残量 / 画面末尾の上限表示）
    Chat/                       チャット画面の UI に依らないロジック（テスト対象）
      TranscriptBuffer.swift      会話履歴の GET と SSE の統合（id で重複除去・reset で置換）
      ChatTimeline.swift          発話の下にツールを畳む・実行中ツールの判定
      RoomGrouping.swift          要対応 / 稼働中 / 待機 のグループ化・並び順・検索・未読数・アイコン色
      ChatMarkdown.swift          吹き出しの最低限の Markdown（太字・コード・改行・コードブロック）
      PTYInput.swift              PTY に送るキー列（貼り付け・Enter・権限の Yes / Esc・制御文字の除去）と、画面からの権限プロンプト / 選択メニューの読み取り
  Sources/MonitorProbe/         GUI 無しで接続を確かめるデバッグ用エントリ（swift run monitor-probe）
  Tests/ClaudeDeckTests/        MonitorKit のテスト（swift test）
  Resources/Info.plist          .app 用 Info.plist（バンドル ID com.shinjosato.claude-deck）
  scripts/bundle.sh             claude-deck.app を組み立てて ad-hoc 署名する
```

## monitor 連携（MonitorKit）

起動時に `MonitorBridge.store.start()` で monitor の `GET /events` を購読し、セッション・フィード・残量・
保留中の権限確認をストアに保持する（UI は後続の画面が使う）。monitor が起動していなくてもアプリは動き、
`connection` が `.disconnected` のまま指数バックオフ（0.5 秒〜最大 10 秒）で張り直し続ける。

- 接続先: `CLAUDE_DECK_MONITOR_URL`（例 `http://127.0.0.1:8799`）> `CLAUDE_DECK_MONITOR_PORT` > 既定 `http://127.0.0.1:8766`
- デバッグ出力: `CLAUDE_DECK_MONITOR_DEBUG=1` で接続状態とイベントの要約を標準エラーに出す
- 無通信 10 秒で切れたとみなす（monitor は sessions を 1 秒ごとに送るため）
- 切れている間: 権限確認は答えられないので空にする。sessions / usage / feed は最後の値を残す（鮮度は `connection` で判断）
- 再接続のたびに `connectionEpoch` が増える。transcript の差分 GET をやり直す合図に使う
- アプリで起動した claude の pid を `registerHostedProcess(pid:)` で登録し、`~/.claude/sessions/<pid>.json` の
  sessionId で monitor のセッションと対応付ける（`session(forHostedPid:)` / `externalSessions`）。
  `/clear` で sessionId が替わるので sessions を受けるたびに読み直す

### monitor の自動起動（`MonitorLauncher`）

起動時に `MonitorBridge.start()` が launcher → store の順に動かす（store は自分で再接続するので launcher の完了は待たない）。

1. 接続先がループバック以外（`CLAUDE_DECK_MONITOR_URL` で別ホスト）なら起動しない（`.skippedRemote`）
2. `GET /api/health` が応答すれば既存の monitor を使う（`.usingExisting`。アプリ終了時も止めない）
3. 応答が無ければ `<ai-manager ルート>/monitor` で、install が済んでいなければ `npm install`（`.installing`）、
   `ui/dist` が無ければ `npm run build`（`.building`）を済ませてから `npm start`（`.starting` → `.running`）。
   済んだかは `node_modules/.package-lock.json` / `ui/dist/index.html` と、実行中だけ置く
   `node_modules/.claude-deck-{install,build}-incomplete` で判定する（途中で止めた install / build は次回やり直す）
4. 自分が起動した monitor だけを、アプリ終了時に止める。`applicationShouldTerminate` で `.terminateLater` を返し、
   バックグラウンドで止め終えてから終了する（main を止めない）。SIGTERM / SIGINT も通常の終了経路に乗せる

- 子プロセスは `/bin/zsh -lc` 経由（node / npm の PATH をログインシェルから得る）で、新しいプロセスグループの先頭として
  `posix_spawn` する。停止は `kill(-pgid, SIGTERM)` → 3 秒待って残れば SIGKILL（npm → tsx → node をまとめて止め、孤児を残さない）。
  起動待ちの間や起動後に npm（グループ先頭）だけ落ちた場合も、残ったグループを同じ手順で片付ける
- SIGTERM / SIGINT は `SIG_IGN` ではなく何もしないハンドラ（`TerminationSignals`）で既定動作だけ外す。
  `SIG_IGN` は exec を越えて子に残り、端末ペインの claude（SwiftTerm の forkpty 経路）が SIGTERM を無視して
  上限到達時の `terminate()` が効かなくなるため。ハンドラは exec で既定に戻るので子に漏れない（`TerminationSignalsTests`）
- 停止要求の後は何も起動しない（start / stop ごとの世代番号で、古い実行が新しい実行の状態を書き換えない）
- 環境から `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` / `MONITOR_LAN` / `MONITOR_TOKEN` を除去し、シェル側でも unset する。
  `PORT` は接続先のポートに合わせる（LAN 公開モードでは起動しない）
- 標準出力 / 標準エラーは `~/Library/Logs/claude-deck/monitor.log`（追記・`O_CLOEXEC`）。launcher 自身の起動・失敗・停止の記録も同じファイルに残る。
  起動時に 5MB を超えていれば `monitor.log.1` に回す（1 世代）
- ポート使用中の判定は 127.0.0.1 と ::1 の両方を見る。URL にポートが無ければ scheme の既定（http 80 / https 443）
- 失敗理由は `MonitorLaunchFailure`（monitor ディレクトリが無い・node が無い・ポートが別プロセスに使用中・
  install/build 失敗・45 秒で health が上がらない・起動後に終了）。`launcher.phase` が `.failed` になり、NSAlert でも知らせる
- 画面表示は `MonitorBridge.launcher.phase`（`@Observable`。`isBusy` で準備中か分かる）と `ownedPid` / `logURL` を使う
- アプリが強制終了（クラッシュ・SIGKILL）した場合は monitor が残る。次回起動時は health が応答するのでそれを使う

```sh
# GUI 無しで接続・再接続・対応付けを確かめる（45 秒、pid 14978 をホスト中とみなす）
CLAUDE_DECK_MONITOR_PORT=8799 swift run monitor-probe 45 14978
# 実 monitor に繋ぐテスト（未設定ならスキップ）
MONITOR_TEST_URL=http://127.0.0.1:8799 swift test
```

## プロジェクト一覧（ユーザー管理 + 永続化）

チャット画面の「+」で選ぶプロジェクトの一覧。**ユーザーが自由に追加でき、永続化される**。

- 追加: 「+」→「フォルダを追加…」（複数可）。選んだディレクトリで `claude` を起動するエントリになる。
- 削除: 「+」の一覧で各行の「…」（または右クリック）→「一覧から削除」。一覧から外すだけでフォルダは消さない。
- 取り込み: 「+」の下部「registry.tsv を取り込む」。`projects/registry.tsv` の行を足す（既にあるパスは重複させない）。
- GitHub Project の紐づけ: 各行の「…」→「GitHub Project を設定…」（URL・`owner/番号`・番号のみを受け付ける。空欄で解除）。
- 同じプロジェクトを選ぶと、動いているルームがあれば新しく起動せずそのルームに移る（終了済みのルームしか無ければ新しく起動する）。
- 永続化先・初回の取り込みは下記。

## メイン画面: チャット（画面案B の左と中央）

Claude Code のセッションを**チャットアプリの操作感**で扱う。セッション 1 つ = トークルーム 1 つ。
右側（ステージパネル・#69）は `ChatRootView` の `trailing` に差し込む（`ChatRootView(model:) { StagePanel() }`）。

### ルーム一覧（左 312px）

- monitor が見つけたセッション + アプリでホスト中のセッションを **要対応（権限待ち・入力待ち）/ 稼働中 / 待機** に分けて並べる。
  各グループ内は最後に動いた順。状態は monitor の `SessionSnapshot.status`。monitor 未接続のときは、ホスト中のセッションだけ
  端末画面からのローカル判定（作業中 / 権限プロンプト / 待機）で代わりに出す。
- 各行: 頭文字アイコン（色はプロジェクト名から決まる）・状態ドット・名前・ブランチ・状態ラベル + 直近の一行・時刻・未読数
  （開いていない間に届いた応答の数）。アプリの外で動いているセッションには「外部」タグ（入力欄は無効。伝言・引き継ぎは #70）。
- 上部: 検索（名前・ブランチ・タイトル・直近の一行。空白区切りで AND）と **「+」**（プロジェクト一覧から選んで `claude` を起動 = 新しいルーム。
  一覧の追加・削除・取り込み・GitHub の紐づけもここ）。右クリック → 「ルームを閉じる（claude を終了）」。
- 下部: 5 時間 / 7 日間の残り% と取得からの経過（statusLine 未設定なら未取得と出す）。monitor 未接続ならその旨を出す。

### 会話（中央）

- 見出し: アイコン・名前・ブランチ・状態バッジ・VS Code / Xcode で開く・**チャット / ターミナル / GitHub / App Store** 切替。
  ターミナルは既存の端末ビュー、GitHub は既存のボード表示、App Store は既存の `AppStoreView`（`appstore.tsv` に登録のあるプロジェクトだけ出す）。
  切り替えても、ルームを移っても、各ルームの PTY と claude は生きたまま。claude が終了したルームも、最後に分かった sessionId で会話を出し続ける。
- 会話は monitor の会話履歴 API（`/api/sessions/:id/transcript` + SSE `transcript`）から組み立てる。
  SSE は起動時に `?transcripts=*` で張り（ルームを選ぶたびに張り直さない）、ルームを開いた時に GET、以降は SSE を id で重複除去して足す。
  再接続（`connectionEpoch` の増加）後は**全件を取り直して置き換える**（切れていた間の発話は手元の末尾より前に入りうるので `?after=` では埋まらない）。
  取得中に繋ぎ直した時は取得後にもう一度取り直し、失敗した時は間隔を空けて 3 回までやり直す。
- 表示: 自分の発話は右の青い吹き出し、Claude の応答は左の暗色の吹き出し（太字・インラインコード・改行・コードブロック）。
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
  「❯ n.」の選択肢の形の行は、罫線の直下にあっても入力欄とは見なさない。文言だけで決めた「入力待ち」はバッジ表示用で、
  送信は止めない（返答本文が「Do you want to proceed …?」で終わるだけの画面で送れなくならないように）。入力欄は同じ条件で無効にし、
  権限なら「権限の確認に答えると送れます」、それ以外は「端末側の選択に答えると送れます（ターミナル表示で操作）」と出す。
- 判定は**貼り付けの前**と、**Enter の直前**の 2 回。貼り付けた後に止めた場合は本文が Claude Code の入力欄に残る
  （安全に消すキーが無い。Esc はメニューの取り消しになる）ので、その旨を知らせ、チャット欄の下書きには戻さない（送り直しで二重にしない）。
  取りやめが起きたセッションでは、次の送信の前に端末の入力欄（罫線の間の ❯ 行）が空かを画面から確かめ、残っていれば送らずに
  「端末側の入力欄に前回の本文が残っているようです」と知らせる（前回の本文にくっつけないため）。警告は 1 回だけで、
  もう一度送ると送れる（未知の薄字表示を本文と誤認しても、チャットから送れないまま固まらないため）。
  空欄の時に薄字で出る例文（`Try "…"`）は空とみなす。
- 判定はターミナル表示のスクロール位置に依らない（SwiftTerm の表示位置 `yDisp` ではなく、バッファ末尾の `rows` 行 = 実画面を読む）。
- 本文からは改行・タブ以外の制御文字（C0・DEL・C1）を落としてから送る（ESC や Ctrl-C が端末操作として効かないように）。

### 権限カード

- 権限待ちは会話の末尾に amber の枠のカードで出す（ツール名・見出し・コマンド等のプレビュー・許可 / 拒否）。
- monitor の `permissions`（Channels 経由）があれば `store.decide` で返す。無ければホスト中のセッションの端末画面から
  プロンプトを読み取り、**許可 = `1`（1. Yes）/ 拒否 = `Esc`** を PTY に送る（選択肢の数で「No」の番号が変わるため拒否は Esc）。
  キーは Claude Code v2.1.251 / v2.1.286 の実際の TUI で確認した。画面にプロンプトが無ければ何も送らない。
  押した時のカードの内容と今の画面のプロンプトが違う（別の確認に替わった）場合も何も送らず、カードを今の内容に更新する。
- 押してから結果が出るまでは、そのカードのボタンを無効にして二度押しを防ぐ。

### GitHub 切替

- そのプロジェクトの Issue を**ステータス別（Todo / In Progress / Debug / Review / Done / その他）にグループ化**して表示。各行は `[repo] #番号 タイトル @担当`、**クリックで GitHub を開く**。右上の 🔄 で再取得。ルームを行き来しても取り直さない。
- マッピング元: プロジェクトに保存した GitHub 参照（owner/number）→ `projects/github-projects.tsv`（name / owner / number / repo / url）の名前一致。外部セッションは cwd が一覧のプロジェクトと一致すればそれを使う。**マッピングが無いルームでは GitHub を選べない**。
- 取得は `gh project item-list <number> --owner <owner> --format json` をログインシェル経由で実行（**`gh` の認証 + `project` スコープが前提**）。
- 解決順（github-projects.tsv）: 環境変数 `CLAUDE_DECK_GH_PROJECTS` → ai-manager ルート配下（後述「ai-manager ルートの解決」）。

### App Store 切替

`projects/appstore.tsv` に登録があるプロジェクト（mirio / sandora 等）は、会話の見出しの切替に **App Store**（`app.badge`）が追加で出る（旧ペインのトグルと同じ表示）。

- **App Store**: そのアプリの審査ステータス・最新 TestFlight ビルド・レビュー件数などを **Web の AppStoreCard 相当のサマリ**で表示。REJECT/FAILED 系は赤、配信中/完了/利用可は緑のバッジ（Web と色基準を合わせている）。右上の 🔄 で再取得。
- ロジックは **server に一本化**。claude-deck は ASC API を直接叩かず、既存 HTTP API `GET /api/appstore/:name` を fetch するだけ（二重実装しない）。
- 前提: **server（`:8765`）が起動していること**（`./scripts/dev.sh` 等）。**server 未起動・API エラー・認証未設定時は、その旨をペイン内に文言表示してフォールバック**（アプリは落とさない）。
- 対象判定元: `projects/appstore.tsv`（name / bundleId）。ルームの名前（プロジェクト名）で引く。**登録が無いプロジェクトでは App Store を出さない**。
- 解決順（appstore.tsv）: 環境変数 `CLAUDE_DECK_APPSTORE_TSV` → ai-manager ルート配下（後述「ai-manager ルートの解決」）。API ベース URL は `CLAUDE_DECK_API_BASE`（既定 `http://localhost:8765`）で差し替え可能。

**永続化先**: `~/Library/Application Support/claude-deck/projects.json`（人が読める JSON）。試験用に別の一覧を使うときは環境変数 `CLAUDE_DECK_PROJECTS`（JSON のパス）で差し替える。
**初回のみ** `registry.tsv` から取り込んで空にしない（以降は完全にユーザー管理）。

### registry.tsv の解決順（初回取り込み / 取り込みボタン）

1. 環境変数 `CLAUDE_DECK_REGISTRY`（絶対パス）
2. ai-manager ルート配下の `projects/registry.tsv`（下記）

### ai-manager ルートの解決（`AIManagerRoot.swift`）

`.app` から起動すると cwd が `/` になるため、ai-manager ルート（`projects/registry.tsv` を持つディレクトリ）の解決を `AIManagerRoot` に集約している。TSV や `monitor/` はこのルートからの相対で引く。

1. 環境変数 `AI_MANAGER_ROOT`
2. UserDefaults `aiManagerRoot`（`defaults write com.shinjosato.claude-deck aiManagerRoot /path/to/ai-manager`）
3. 実行ファイルの位置 → カレントディレクトリの順に親へ遡り、`projects/registry.tsv` を持つディレクトリ
4. 既定 `/Users/shinjo/project/ai-manager`

各候補は `projects/registry.tsv` が実在するときだけ採用する。API は `AIManagerRoot.url`（ルート URL）と `AIManagerRoot.file("相対パス", envOverride: "環境変数名")`。
解決結果は `claude-deck --print-ai-manager-root` で GUI を出さずに確認できる（`.app` なら `claude-deck.app/Contents/MacOS/claude-deck --print-ai-manager-root`）。

## ビルド / 実行

```sh
cd /Users/shinjo/project/ai-manager/mac
swift build          # ビルド
swift run            # 起動（ウィンドウが開く）
```

### `.app` として起動する

```sh
cd /Users/shinjo/project/ai-manager/mac
./scripts/bundle.sh            # → mac/dist/claude-deck.app（ad-hoc 署名済み）
open dist/claude-deck.app      # Finder からのダブルクリックでも可
```

- オプション: `--build-system auto|default|native`（既定 auto）/ `--debug` / `--out <dir>`。
- `auto` は通常の `swift build` を試し、失敗したら `--build-system native` で再ビルドする。Metal Toolchain が無い環境では通常ビルドが SwiftTerm の `Shaders.metal` のコンパイルで失敗するため（`xcodebuild -downloadComponent MetalToolchain` で入れれば通常ビルドが通る）。
- 依存のリソースバンドル（`SwiftTerm_SwiftTerm.bundle`）は `Contents/Resources/` に同梱する。claude-deck は SwiftTerm の Metal レンダラーを有効にしていないため、現状このバンドルは参照されない（有効化する場合は SPM の `Bundle.module` が `.app` 直下を探す点に注意）。
- 署名は ad-hoc（`codesign -s -`）のみ。Developer ID 署名・公証・配布・自動アップデートはしない。別の Mac へコピーすると Gatekeeper に止められる前提（右クリック → 開く）。
- `/Applications` へ置く場合は `--out /Applications` またはコピー。その場合は実行ファイル位置から ai-manager を辿れないので、上記の `AI_MANAGER_ROOT` / UserDefaults / 既定パスで解決される（Finder 起動には環境変数が渡らないので、実質 UserDefaults か既定パス）。
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

- `.app` は ad-hoc 署名のローカル起動のみ。配布時は Developer ID 署名・公証を検討。
- 上限到達の画面表示は実際の上限で出たものを未確認（文言はバイナリから、`⎿` の位置は TUI の描画コードから推定）。表示の形が違えば補助経路だけ効かない（主経路の残量判定は効く）。
- 追加時の表示名はフォルダ名固定（リネーム UI は未実装）。
- ホスト中のルームはアプリを終了すると claude ごと終わる（ルームの保存・復元は未実装）。
- 権限プロンプト・選択メニューの読み取りは端末画面の文言（`Do you want to …?` と `1. Yes`、`❯ n.` の選択肢、`Enter to confirm` 等の操作案内）に依る。
  **Claude Code の TUI の更新で判定を見直す必要がある**: `PTYInput.swift` の `InputBlock` / `ChoiceMenu` / `PermissionPrompt` / `InputBox`
  （v2.1.286 の trust 確認・AskUserQuestion・plan 承認・入力欄の例文と NBSP で確認）。文言・配置（罫線と ❯ の位置関係、操作案内の有無）に依存している。
- ステージパネル（#69）・外部セッションへの伝言 / 引き継ぎ（#70）は別 Issue。
