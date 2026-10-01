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
    Chat/                       チャット画面（ルーム一覧・会話・入力欄・権限カード・選択肢カード）
      ChatRootView.swift          3 カラムの骨組み（ルーム一覧 | 会話 | 右パネルの差し込み口）
      ChatModel.swift             ルーム（monitor のセッション + ホスト中のセッション）・会話履歴・権限確認の状態
      HostedSession.swift         アプリが PTY でホストする claude 1 つ（端末ビューは画面に載せず、PTY の受信と画面読み取りに使う）
      RoomListView.swift          ルーム一覧・検索・「+」（新しいルーム・プロジェクト一覧の管理）・残量
      ConversationView.swift      見出し・吹き出し・ツール行・権限カード・選択肢カード
      Composer.swift              入力欄（⏎ 送信 / ⇧⏎ 改行・外部ルームでは「伝言」モード）
      MarkdownView.swift          Claude の吹き出しの Markdown 描画（表の列幅揃え・横スクロール・解析結果のキャッシュ）
      ExternalSessionViews.swift  外部ルームのバナー（アプリに引き継ぐ）・伝言の点線吹き出し・Channels 未設定の案内
      ChatTheme.swift             画面案B の色・文字のトークン（ダーク固定）
    Stage/                      右側のステージパネル（画面案B の右 360px）
      StagePanel.swift            見出し（開閉）・ステージ・いまの動き・随伴するサブエージェント・ライブフィード
      StageWebView.swift          monitor の埋め込み表示を出す WKWebView（直近 3 枚を保持して切替）とウィンドウ幅の監視
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
    EditorActions.swift         見出しの「VS Code / Xcode / 閉じる」の結果の文言と、Xcode からワークスペースだけを閉じる AppleScript（osascript）
    Chat/                       チャット画面の UI に依らないロジック（テスト対象）
      TranscriptBuffer.swift      会話履歴の GET と SSE の統合（id で重複除去・reset で置換）
      ChatTimeline.swift          発話の下にツールを畳む・実行中ツールの判定・送った伝言の差し込み
      RelayNotes.swift            外部セッションへ送った伝言（transcript の写しとの重複排除・送信失敗の理由）
      SessionHandover.swift       アプリに引き継ぐ: sessionId の検証・終了対象の確認（pid / sessionId / 起動時刻 / プロセス）・SIGINT → SIGTERM
      RoomGrouping.swift          要対応 / 稼働中 / 待機 のグループ化・並び順・検索・未読数・アイコン色
      ChatMarkdown.swift          吹き出しの Markdown 解析（見出し・表・リスト・引用・区切り線・段落・コードブロック）
      PTYInput.swift              PTY に送るキー列（貼り付け・Enter・権限の Yes / Esc・矢印・制御文字の除去）と、画面からの権限プロンプト / 選択メニューの判定
      MenuPrompt.swift            選択メニューの中身の読み取り（ChoiceMenu.parse）と、矢印で選択肢まで動かして Enter する手順（MenuNavigator）
    Stage/
      StageLogic.swift            ステージパネルの文言（いまの動き・職業名・フィード）・埋め込み URL・プレースホルダー・開閉の判定
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
右側はステージパネル（`MainViewController` で `ChatRootView(model:) { StagePanel(model:) }` として差し込む）。
埋め込み表示の URL は monitor の接続先のホスト・ポートだけを使い、`CLAUDE_DECK_MONITOR_URL` に付けたパスやクエリ（LAN のトークン等）は引き継がない（ループバックの monitor を前提にしている）。

### ルーム一覧（左 312px）

- monitor が見つけたセッション + アプリでホスト中のセッションを **要対応（権限待ち・入力待ち）/ 稼働中 / 待機** に分けて並べる。
  各グループ内は最後に動いた順。状態は monitor の `SessionSnapshot.status`。monitor 未接続のときは、ホスト中のセッションだけ
  端末画面からのローカル判定（作業中 / 権限プロンプト / 待機）で代わりに出す。
- 各行: ドット絵キャラのアイコン・名前・ブランチ・状態ラベル + 直近の一行・時刻・未読数
  （開いていない間に届いた応答の数）。アプリの外で動いているセッションには「外部」タグ（伝言・引き継ぎは下記「外部セッション」）。
  - キャラは monitor の 2D と同じ絵と配色（`monitor/ui/src/pixel/sprites.ts`・`look.ts` を `Sources/MonitorKit/Pixel/PixelCharacter.swift` に移植。変えるときは両方そろえる。ただしマークの大きさ・位置・跳ね幅は小さいアイコンで読めるよう monitor の 2D とは変えている）。稼働中=立ち・緑で跳ねる / 権限待ち=立ち・amber で「!」が点滅 / 入力待ち=立ち・青で「?」が点滅 / エラー=うずくまり・赤 / 待機=座り・灰で Zz が浮き沈み / 終了=座り・暗い灰 / 状態不明=座り・灰（マーク無し）
  - SwiftUI の Canvas で整数ポイントのマスを補間なしに塗る。動く状態だけ、画面に出ている間だけ `TimelineView(.periodic)` で 4fps で描き直す（起点を固定時刻にして全行が同じ境目でコマを切り替える）。「動きを減らす」設定では止める。行と見出しでは状態名を隣の文字が読むので、アイコン自体は読み上げない
  - 会話の見出しのアイコンも同じキャラ。「+」のプロジェクト一覧はセッションを持たないので頭文字アイコンのまま
- 上部: 検索（名前・ブランチ・タイトル・直近の一行。空白区切りで AND）と **「+」**（プロジェクト一覧から選んで `claude` を起動 = 新しいルーム。
  一覧の追加・削除・取り込み・GitHub の紐づけもここ）。右クリック → 「ルームを閉じる（claude を終了）」。
- 検索欄の下: monitor 未接続（接続中・再接続待ち）の間だけその旨を出す。
- 上限の残り% は出さない（statusLine はターミナル起動の Claude Code でしか更新されず、VS Code 拡張だけ動いていると古い値が残るため）。
  上限到達の強制終了（`LimitGuard` / `LimitWatch`）は従来どおり `MonitorStore.usage`（取得 10 分以内の値だけ）を使う。

### ステージパネル（右 360px）

選択中のルームのセッションを、monitor のステージ（アニメーション）と monitor クライアントのデータで見せる。
文言・URL・判定は `Sources/MonitorKit/Stage/StageLogic.swift`（テストあり）、画面は `Sources/ClaudeDeck/Stage/`。

- **見出し**: 「ステージ」・畳むボタン。ステージは 3D 表示だけ（以前の 2D / 3D の保存値 `stagePanel.mode` はパネル表示時に消す）。
- **ステージ**: WKWebView で monitor の埋め込み表示 `/?embed=stage&session=<id>&mode=3d&bg=transparent` を読む（monitor 側の `mode=2d` は monitor の UI 用に残っているが、アプリからは使わない）。
  接続先は `MonitorConfiguration`（`CLAUDE_DECK_MONITOR_URL` / `CLAUDE_DECK_MONITOR_PORT`）。ルームを切り替えると URL を差し替える。
  埋め込み表示は URL を読み込み時にしか見ないので切替は読み直しになるが、直近 3 枚の WKWebView を生かしておき、行き来した時は読み直さない。
  monitor に繋ぎ直した（`connectionEpoch` が増えた）時は保持分を捨てて読み直す。読み込みに失敗したら 2 秒後にやり直す。
  - 背景は透過（`drawsBackground = false`）。monitor 側の `html { color-scheme: dark }` があっても地は塗られない（WKWebView のスナップショットで透過を確認）。
    透けない環境が出たら `StageTheme.embedBackground` に `0x0b111d` を入れると monitor が同色で塗る。
  - http のループバックは ATS で弾かれない（`swift run` と `.app` の両方で読み込みを確認。Info.plist の変更は不要）。
  - 埋め込み表示の外へのナビゲーション（別オリジン）は止める。
- **プレースホルダー**: monitor 未接続（自動起動の準備中は `launcher.phase` に応じて「npm install」「UI をビルド中」「起動しています」、失敗時はその旨）・
  ルーム未選択・ホスト中で sessionId 未解決（「セッションを確認しています…」）・monitor がまだそのセッションを見つけていない、の各状態で文言を出す。
- **いまの動き**: monitor UI の `SessionCard` の `actionLine` と同じ順（スキル『…』> `currentAction` > ツールの動作「端末を叩いている」等）。
  作業中でなければ `statusDetail` か状態名。下に「最終活動 N秒前 · 稼働 N分」（1 秒ごとに更新）と作業タイトル。
- **随伴するサブエージェント**: `agents` を id 順で、職業名（`pixel/kit.ts` の JOBS と同じ。例: Explore → 斥候）・種別・状態
  （ログ更新が 15 秒以内なら「作業中」、それ以外は最終更新からの経過）。
- **ライブフィード**: そのセッションの feed の直近 60 件を新しい順（新着が先頭に入る）。時刻・種別（ツール / 指示 / 応答 / 状態 / セッション / 随伴）・内容を mono で。
- **開閉**: 見出しのボタンで畳む（幅 36px の帯になり、帯のボタンで開く。UserDefaults `stagePanel.open`）。
  ウィンドウ幅が 1100px 未満なら自動で畳む。狭いまま開いた時はそれに従い（パネルは最小 240px まで縮む）、広げれば通常に戻る。

### 会話（中央）

- 見出し: アイコン・名前・ブランチ・状態バッジ・「VS Code」「Xcode」「閉じる」。表示の切替は無く、どのルームも常にチャット。
  「Xcode」「閉じる」は `.xcworkspace` / `.xcodeproj` があるルームだけ出す（`findXcodeProject`）。「閉じる」は確認ダイアログの後、
  monitor の `close.ts` と同じ AppleScript をアプリから `osascript` で実行し、Xcode からそのワークスペースだけを閉じる
  （Xcode は終了しない・起動していなければ立ち上げない。パスは argv で渡す）。monitor 未接続でも、ホスト中のルームでも使える。
  結果（開きました / 閉じるよう伝えました / Xcode では開いていません / Xcode は起動していません / エラー）をボタンの左に数秒出す。
  初回は macOS が「claude-deck が Xcode を操作する」許可（オートメーション）を求める。拒否するとエラー（-1743）になる。
  ルームを移っても各ルームの PTY と claude は生きたまま。claude が終了したルームも、最後に分かった sessionId で会話を出し続ける。
- 端末ビュー（`ClaudeTerminalView`）は画面に載せない。PTY の受信は main キューで端末バッファに流れ、状態・権限プロンプト・選択待ち・上限表示は
  0.3 秒ごとのタイマーと受信時にバッファ末尾の `rows` 行を読むので、ビュー階層に無くても動く。桁数は作成時の 960×640pt のまま固定。
- 会話は monitor の会話履歴 API（`/api/sessions/:id/transcript` + SSE `transcript`）から組み立てる。
  SSE は起動時に `?transcripts=*` で張り（ルームを選ぶたびに張り直さない）、ルームを開いた時に GET、以降は SSE を id で重複除去して足す。
  再接続（`connectionEpoch` の増加）後は**全件を取り直して置き換える**（切れていた間の発話は手元の末尾より前に入りうるので `?after=` では埋まらない）。
  取得中に繋ぎ直した時は取得後にもう一度取り直し、失敗した時は間隔を空けて 3 回までやり直す。
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
  「❯ n.」の選択肢の形の行は、罫線の直下にあっても入力欄とは見なさない。文言だけで決めた「入力待ち」はバッジ表示用で、
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

### 権限カード

- 権限待ちは会話の末尾に amber の枠のカードで出す（ツール名・見出し・コマンド等のプレビュー・許可 / 拒否）。
- monitor の `permissions`（Channels 経由）があれば `store.decide` で返す。無ければホスト中のセッションの端末画面から
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
- 押すと **矢印キー（↑/↓）で「❯」を 1 行ずつ動かし、目的の行に着いたのを画面で確かめてから Enter** を送る（`MenuNavigator`）。
  番号キーは使わない（trust 確認には番号が無く、番号キーが「移動」か「即決定」かもメニューごとに違って、押した結果を確かめてから確定できないため）。
  矢印は端末のモードに合わせて CSI（`ESC[A`/`ESC[B`）か、アプリケーションカーソルモードなら SS3（`ESC O A`/`ESC O B`）で送る。
  0.1 秒ごとに画面を読み直し、「❯」が動くのを待ってから次の矢印を送る（画面が追いつく前に送り重ねて行き過ぎないため。行き過ぎたら戻す）。
- 最初に、押した時のカードと今の画面のメニュー（本文・問い・選択肢の文言。「❯」の位置は除く）が同じかを確かめ、違えば何も送らない。
  動かしている途中で問い・本文・選択肢の数が変わったら Enter を押さずにやめる。着いた時も全体を照合してから Enter を送る。
  「❯」が動かない・メニューが消えた時も Enter を押さずにやめて理由を出す（矢印で「❯」を動かした分は端末に残る）。
- 「キャンセル（Esc）」は今のメニューがカードと同じ時だけ `Esc` を送る（trust 確認の Esc は claude の終了になる）。
- **文字を入力する選択肢**（AskUserQuestion の「Type something.」、plan の「Tell Claude what to change」）はカードからは選べない
  （選ぶと端末側の文字入力に移り、本文を安全に渡せないため）。「キャンセル」で閉じてから入力欄で伝える旨を出す。
- 中身を読み取れないメニューは、その旨と「キャンセル（Esc）」だけのカードを出す（メニューが出ている時だけ送る）。
- 押してから結果が出るまではカードのボタンを無効にして二度押しを防ぐ。外部セッションは対象外。

### 外部セッション（ターミナル等で起動したもの）

アプリの外で起動した claude には本人の入力として届く経路が無い。ここから出来るのは **伝言** と **権限の許可・拒否（Channels のみ）**、
そして **アプリに引き継ぐ**（アプリの PTY で同じ会話を再開して、以降は通常のルームとして操作する）の 3 つ。

- 見出しに「外部セッション」タグ、その下にバナー（起動元に応じた説明と「アプリに引き継ぐ」ボタン）。
- **引き継げるのはターミナルで対話起動した claude だけ**（`~/.claude/sessions/<pid>.json` の `entrypoint` が `cli` で、`kind` があれば `interactive`）。
  VS Code 拡張（`claude-vscode`）等で動いているセッションは止めると元の画面が壊れるので、ボタンを出さずに理由を表示する（`SessionHandover.unsupportedSourceReason`）。
  `entrypoint` は環境変数 `CLAUDE_CODE_ENTRYPOINT` を引き継ぐので、Claude Code の中（VS Code 拡張の Bash 等）から起動した claude は `cli` にならず引き継げない。
- **伝言**: 入力欄が黄色の「伝言」モードになり（注記「受け手には別セッションからのメッセージとして届きます」）、monitor の
  `POST /api/sessions/:id/message`（`MonitorStore.sendMessage`）で送る。受け手には `Another Claude session sent a message:` に続けて
  届き、**本人の指示にはならない**（権限承認・スラッシュコマンド・設定変更は不可。v2.1.286 で確認）。
  - 受け手は伝言を `isMeta: true` の user 行として jsonl に残すので、monitor の transcript には出ない（実機で確認）。そのため
    送った伝言はアプリ側で sessionId ごとに覚え、送信時刻の位置に**点線の吹き出し**で差し込む（アプリを終了すると消える）。
    transcript に写しが出た場合（monitor の仕様が変わった時）は、`RelayNotes.removingEchoes` が 1 通につき 1 件だけ取り除いて二重に並べない
    （書き出し付きはいつでも、素の同文は時刻があり送信の 5 秒前〜10 分後のものだけ。届かなかった伝言では消さない）。
  - 送信失敗は吹き出しの下とダイアログに理由を出す（`not_found` / `not_alive` / `no_socket` / `unreachable`・monitor 未接続）。
- **権限**: monitor の `permissions`（Channels を載せたセッションのみ）があれば許可 / 拒否カードを出して `store.decide` で返す（二度押し不可）。
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

### GitHub / App Store 表示（旧ペインのみ）

会話画面からは外した。`GitHubBoardView`（`gh project item-list` で Issue をステータス別に表示）と `AppStoreView`（server の
`GET /api/appstore/:name` のサマリ）は、使われていない旧ペイン（`TerminalPaneViewController`）にだけ残っている。
「+」の「GitHub Project を設定…」で保存した owner/number は、一覧の 2 行目（`GH #番号`）に出る。

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
  **Claude Code の TUI の更新で判定を見直す必要がある**: `PTYInput.swift` の `InputBlock` / `ChoiceMenu` / `PermissionPrompt` / `InputBox`、`MenuPrompt.swift`
  （v2.1.286 の trust 確認・AskUserQuestion・plan 承認・入力欄の例文と NBSP で確認）。文言・配置（罫線と ❯ の位置関係、操作案内の有無）に依存している。
- 選択肢カードからの回答（矢印 + Enter）は、テストのフィクスチャ（v2.1.286 の実画面の写し）で読み取りと手順を確かめたのみで、
  本物の claude で押して先へ進むところは目視で未確認。AskUserQuestion の複数選択（チェックボックス）・複数の問い（タブ）は
  押すたびに今の画面のメニューでカードを出し直す作りで、実画面の写しでは未確認。「Type something.」の行を「❯」が通過する時の描き方も未確認
  （文言が変わって選択肢の数が読めなくなれば Enter を押さずにやめる）。
- 送った伝言の吹き出しはアプリのメモリにだけ持つ（再起動で消える）。
- 外部セッションの権限カード（Channels 経由の許可 / 拒否）は既存の monitor permissions の経路をそのまま使っており、外部ルームでの実機確認はしていない。
- ステージの 3D（WebGL）表示とキャラの動きは、WKWebView 内での描画を目視では未確認（canvas と WebGL2 の生成までは確認）。
