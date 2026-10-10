# claude-deck

プロジェクトごとに **Claude Code を同時起動**し、セッションを**チャット（トークルーム）**として扱う macOS ネイティブ司令塔アプリ（PoC）。
ai-manager の管理対象プロジェクト一覧と連携し、各プロジェクトのディレクトリで `claude` を端末として起動する。

SwiftTerm（VT100/Xterm エミュレータ + PTY ホスト）を使い、Terminal.app 同等の操作感を持たせている。

## 設計上の方針（重要）

- **料金事故ゼロ**: 子プロセスの環境から `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` を必ず除去して `claude` を起動する。API 課金経路が存在しないため、Max 枠の上限に達しても「待つ」だけで課金は発生しない。さらにログインシェル側でも `unset` してから `exec claude` する二重防御。
- **headless 不採用**: `claude -p` / Agent SDK の起動口は一切設けない（別枠課金や非対話実行を避ける）。
- **上限到達で強制終了**: 次のどちらかで上限到達とみなし、アプリでホストしている全セッションを `terminate()` で強制終了して警告ダイアログを出す。判定は `Sources/MonitorKit/Limit/LimitGuard.swift`（テストあり）、残量の購読は `Sources/ClaudeDeck/App/LimitWatch.swift`。
  1. **公式の残量（主）**: statusLine の `rate_limits`（`mac/scripts/statusline.sh` が `~/Library/Application Support/claude-deck/usage.json` に書く）をアプリ内の監視が読んだ `MonitorStore.usage` で、5 時間 / 7 日間のどちらかが 100% 以上、かつ取得から 10 分以内。古い値・未取得では落とさない（statusLine 未設定なら この経路は働かない。設定は下の「Claude Code 側の設定」）。一度到達したらそのウィンドウのリセット時刻まで覚えておき、その間に起動したセッションも起動直後に止める（新しい値で 100% 未満になれば解除）。到達の解ける時刻は `limit-state.json` に残し、次の起動でも usage.json が古い間はそれを優先する（下の「終了と次の起動」）。
  2. **画面の上限表示（補助）**: 生の出力ではなく端末の実画面の末尾だけを見る。入力欄より下（フッター）、入力欄直上の最後の `⎿` 行（API エラー表示）、上限到達時に自動で開くメニューの「Stop and wait for limit to reset」。会話本文に同じ文言が出ても落ちない。文言は Claude Code v2.1.286 のバイナリ内で上限判定に使われている書き出し（`You've hit your` / `You've reached your` / `You're out of usage credits` / `You're now using usage credits` 等の課金枠切替 / `Usage limit reached`）に絞っている。
  - 起動直後（対話 zsh が `claude` に exec する前）は SIGTERM が効かないので、1.5 秒後に残っていれば SIGKILL する。

## 構成

```
mac/
  Package.swift                 SPM。SwiftTerm を依存に持つ実行ファイル "claude-deck"（SwiftTerm はリビジョン固定。更新時は Package.swift の revision を書き換える）
                                と、チャネルの実行ファイル "claude-deck-channel"
  Sources/ClaudeDeck/
    App/                        起動・ウィンドウ・アプリ全体で 1 つのもの
      main.swift                  NSApplication 起動
      AppDelegate.swift           ウィンドウ + メニュー（「ウインドウ」のしまう・⌘W でルーム / 吹き出しの別ウィンドウを閉じる・タブ）+ 終了の確認（applicationShouldTerminate・ウィンドウを閉じる時）
      RoomWindows.swift           ルームの別ウィンドウ（印ごとに 1 枚の NSWindow・タイトルはルーム名・別ウィンドウ同士だけ macOS のタブにまとめられる・閉じても止めない）
      BubbleWindows.swift         Claude の返答の吹き出しの別ウィンドウ（開いた時点の本文の写しを持つ・同じ吹き出しは 1 枚・吹き出し同士だけタブにまとめられる・閉じても止めない）
      DetachedWindow.swift        別ウィンドウ（ルーム・吹き出し）に共通の作り方・置き方・最後の 1 枚を閉じる時にメインを出し直す判定
      QuitCoordinator.swift       終了の確認ダイアログと「作業が終わったら終了」の待ち（.terminateLater）
      LaunchSettings.swift        起動時の再開の設定（UserDefaults・既定はオン）
      AppearanceSettings.swift    カラーテーマ（ナイト / ライト）の設定（UserDefaults）と NSApp.appearance への反映
      MainViewController.swift    メインウィンドウ = チャット画面（SwiftUI を NSHostingView で載せる）
      MonitorBridge.swift         アプリ全体で 1 つの MonitorStore（監視とフックの受け口はアプリの中で 1 つ）+ 終了シグナルの配線
      LimitWatch.swift            公式の残量で上限到達を見て、ホスト中の全端末を止める
      SystemActions.swift         Finder で表示・クリップボードへのコピー・ファイル / フォルダを選ぶパネル
    Terminal/                   Claude Code を PTY でホストする端末ビュー（1 つの型を役割ごとの extension に分ける）
      ClaudeTerminalView.swift    本体（ClaudeStatus・ScreenState・持ち物・PTY 受信の傍受）
      ClaudeTerminalView+Launch.swift  claude の起動（環境からの API キー除去・--resume）
      ClaudeTerminalView+Input.swift   入力（貼り付け・Enter・画像の取り込み待ち・権限 / 選択メニュー / タブへの回答）
      ClaudeTerminalView+Screen.swift  画面の読み取り（状態の監視・実画面の行・背景色・選択メニューの解析・画面の写し）
      ClaudeTerminalView+Limit.swift   画面末尾の上限表示の監視と強制終了
    Chat/                       チャット画面（ルーム一覧・会話・入力欄・権限カード・選択肢カード）
      Model/                      ChatModel と、それが束ねる部品（@Observable・画面に依らない）
        ChatModel.swift             ルーム一覧（監視のセッション + ホスト中のセッション）・選択・別ウィンドウで開いているルーム・既読・claude の起動と終了。下の部品を束ねる
        ChatOutbox.swift            下書き・添付・ホスト中のセッションへの送信・送った画像の仮の吹き出し（ルームごと）
        ChatRelay.swift             外部セッションへの伝言と、手元で持つ点線の吹き出し
        ChatHandover.swift          外部セッションの claude を止めてアプリで再開する（引き継ぎ）
        PromptResponder.swift       権限確認（Channels・端末）と選択肢メニューへの回答（画面のカードと iPhone が同じ経路）
        TranscriptCache.swift       開いたルームの会話の取得と追記の購読（直近 4 ルームと、メイン・別ウィンドウで出しているものを持つ）・吹き出しの画像の読み込み
        EditorLauncher.swift        見出し・詳細の「VS Code」「Finder」「GitHub」「リンク」「Xcode」「閉じる」と結果の短い一言（押した先ごと）
        HostedSession.swift         アプリが PTY でホストする claude 1 つ（端末ビューは画面に載せず、PTY の受信と画面読み取りに使う）
        SessionRestorer.swift       ホスト中のセッションの記録（hosted-sessions.json）と起動時の再開・作業中だったものへの続きの頼み
        SiteThumbnailStore.swift    「ディレクトリ」の行の LP のサムネイル（オフスクリーンの WKWebView で撮って縮小・キャッシュ・1 つずつ）
        DevServerStore.swift        開発サーバーの持ち手（サイトごとに 1 つ・起動 / 停止・アプリの終了とプロジェクトの削除で止める。ルームを閉じても止めない）
        ProjectImageStore.swift     ディレクトリの詳細の「画像」（走査・サムネイルの縮小をバックグラウンドで・NSCache）・節の走査の持ち手（BackgroundScan。走り切った鍵と「再読み込み」の回数を持つ。「iPhone のプレビュー」と共有）
        IOSPreviewStore.swift       ディレクトリの詳細の「iPhone のプレビュー」（mcpbridge を 1 本持って 1 件ずつ描く・待ち行列・キャッシュへ写す・タブを離れて 3 分で止める）
        LinkVisitStore.swift        リンクの最終確認日（link-visits.json）の読み書き
        LinkTitleFetcher.swift      リンクの名前の候補にするページの <title> の取得（3 秒・資格情報なし）
        ImageDecoding.swift         ImageIO での縮小（吹き出しの画像・ディレクトリの詳細の画像・iPhone のプレビューで共有）
      Views/                      画面（SwiftUI）
        ChatRootView.swift          骨組み（切り替えバー | 一覧（境界のドラッグで幅を変える）| 会話かディレクトリの詳細 | 右パネルの差し込み口）
        ListPane.swift              一覧の幅の状態・境界のつかむ所・ウィンドウの最小幅
        DeckStyles.swift            繰り返す見た目の組み合わせ（角丸の地と枠・入力欄の地・詳細のカード・見出しの帯・状態のカプセル・節の見出し（名前と件数）・グリッドの枠 等）
        WindowResizeView.swift      ウィンドウの大きさの変化を知らせる NSView（一覧の幅とステージの自動で畳む判定）
        RoomList/                   左の一覧（ルーム / ディレクトリ）
          ListModeBar.swift           左端の切り替えバー（「ルーム」/「ディレクトリ」・要対応のバッジ）
          RoomListView.swift          一覧（状態別のルームか登録ディレクトリ）・検索・「+」のポップオーバー・右クリックメニュー
          DirectoryRow.swift          ディレクトリ 1 行（プロジェクトの印・名前・パスの末尾・件数といちばん急ぐ状態・LP のサムネイル）
          RoomRow.swift               ルーム 1 行（RoomRow）・「外部」タグ・プロジェクトの印（ProjectBadgeView）
          RoomListNotices.swift       検索欄の下の注意（監視の開始中・フックの受け口の状態・再開の結果・終了待ち）
          ProjectLauncher.swift       「+」の中身（プロジェクト一覧から選んで起動・追加・削除・設定を開く）
        Directory/                  中央のディレクトリの詳細（DirectoryDetailView: 見出しと操作・タブで切り替える本文（サイト・画像・iPhone のプレビュー・リンク・スレッド））
          DirectoryTabBar.swift       見出しの下のタブの列（アイコン・名前・件数。入りきらなければアイコンを外し、それでも入らなければ横スクロール）
          ProjectLinkEditor.swift     「リンク」の節の追加・編集のポップオーバー（種類と名前の提案・<title> の取得）
          ProjectImagesSection.swift  「画像」: フォルダごとのサムネイルのグリッド・拡大のシート
          IOSPreviewsSection.swift    「iPhone のプレビュー」: 全ファイルの #Preview を 1 つのグリッド（枠にファイル名と行）・すべて描く・拡大して切り替えて描き直すシート
          SitePreviewSection.swift    「サイト」: 見る元（開発サーバー / 書き出し / 公開 URL）・表示幅・再読み込み・ブラウザで開く・書き出しの更新時刻
          SitePreviewParts.swift      サイトの欄とステージパネルのプレビューで共有する部品（場所の読み込み・表示幅の切り替え・縮める枠・開発サーバーの操作と出力）
          SiteWebView.swift           プレビューの WKWebView（pageZoom で縮めて表示幅ぶんを収める・file: / javascript: へは遷移しない）
        Links/
          LinkOverviewView.swift      中央の横断のリンク一覧と、「ディレクトリ」の固定行「リンク」（LinkOverviewListRow）
        Conversation/               中央の会話
          ConversationView.swift      見出し + バナー + チャット（ChatPane: 吹き出しの一覧 + 入力欄）。メインの中央と別ウィンドウで共通
          ConversationHeader.swift    見出し（名前・状態・ブランチ）と「VS Code」「GitHub」「リンク」「Xcode」「閉じる」「別ウィンドウで開く」のボタン
          RoomWindowView.swift        別ウィンドウの中身（1 ルームの会話・会話の取得と既読・ルームが消えた時の案内・そのウィンドウで出す警告）
          BubbleWindowView.swift      吹き出しの別ウィンドウの中身（ルーム名・時刻・全文コピーのボタンと、縦にスクロールする Markdown の本文）
          HeaderActions.swift         見出しのボタン列（入りきらない時は優先度の低いものから「…」のメニューへ。ディレクトリの詳細と共通）
          MessageList.swift           会話の一覧（中央の列にそろえる・末尾への自動スクロール・カードの差し込み・空の時の案内）
          MessageBubbles.swift        発話 1 件（EntryView）・自分の吹き出し・Claude の返答（枠なしの本文。右クリックとホバーのボタンで別ウィンドウに開く）
          ToolsRow.swift              「ツール N件 ▸」の畳み
          PermissionCard.swift        権限確認のカード
          MenuCard.swift              選択肢のカード（選択肢の行・AskUserQuestion のタブ）
          UnreadableMenuCard.swift    選択肢が読めない時のカード
          PromptCardParts.swift       カードの共通部品（見出し・等幅の抜粋・控えめなボタン・枠・終了の確認）
        Composer/                   入力欄
          Composer.swift              入力欄（⏎ 送信 / ⇧⏎ 改行・外部ルームでは「伝言」モード・添付ボタン）
          AttachmentStrip.swift       入力欄の上の添付チップ
          AttachmentDrop.swift        ドロップから添付を拾う
          ComposerTextView.swift      Return を横取りする NSTextView（⌘V の添付は MonitorKit の AttachmentPasteTextView）
        ChatImageViews.swift        吹き出しの画像（サムネイルの格子・拡大表示のシート・表示時に読み込んで NSCache に持つ ChatImageLoader）
        MarkdownView.swift          Claude の吹き出しの Markdown 描画（表の列幅揃え・横スクロール・コードブロックのコピーのボタン・解析結果のキャッシュ）
        ExternalSessionViews.swift  外部ルームのバナー（アプリに引き継ぐ）・伝言の点線吹き出し・Channels 未設定の案内
        PixelAvatar.swift           ルーム一覧と見出しのドット絵キャラ（絵は DeckCore の PixelCharacter）
        ChatTheme.swift             色・文字・時刻の書式のトークン（色はテーマ（ナイト / ライト）ごとの値を描く時の外観で選ぶ。AppKit 側の色も）
    Stage/                      右側のステージパネル（360px）
      StagePanel.swift            見出し（ステージ / プレビューの切り替え・開閉）・ステージ・畳んだ状態
      StagePreviewPanel.swift     プレビュー（選択中のルームのプロジェクトの LP。開発サーバー → 書き出し → 案内）
      StageActivityViews.swift    いまの動き・随伴するサブエージェント・ライブフィード
      StageSceneView.swift        ステージの 3D を描く SCNView（表示中だけ回す・動きを減らす設定で止める）とウィンドウ幅の監視
    Settings/                   設定画面（⌘,）。タブ: プロジェクト・GitHub・iPhone 連携・キャラクター・書き出し / 読み込み・外観・起動と終了（共通の部品は SettingsParts.swift）
    Remote/                     iPhone 連携（設定画面のタブの中身・QR・端末一覧・iPhone からの操作を ChatModel の部品（PromptResponder・ChatOutbox・ChatRelay）へ繋ぐ ChatModel+Remote）
    Notify/                     要対応を iCloud（CloudKit）に書いて解消したら消す AttentionNotifier と、設定画面に出す通知の設定・状態
  Sources/MonitorKit/           セッション監視・会話・フックの受け口（アプリ内）。UI 無し・テスト可能な library
    Store/                      アプリ向けの窓口と設定
      MonitorStore.swift          @Observable ストア（監視の状態・受け口の状態・セッション・フィード・残量・権限確認・pid 対応付け）
      MonitorConfiguration.swift  読み取り元（CLAUDE_HOME）・使用量ファイル・受け口のポート・デバッグ出力
    Hub/                        監視の本体
      SessionHub.swift            監視の窓口の actor。各層を順に回し、セッションの辞書と配信（フィード・スナップショット・状態の合成・伝言）を持つ
      SessionState.swift          セッションごとの可変状態（書く層ごとに欄を分ける）と、層が返すフィードの 1 行
      MonitorEvent.swift          監視からストアへ流れる変化（sessions / feed / usage / permissions / transcript）
      InventoryScanner.swift      在庫層: レジストリの走査結果を既知の State に当て、作る・終わらせる・捨てる判断を返す
      SessionInventory.swift      在庫層: ~/.claude/sessions/<pid>.json + kill(pid,0) の読み取り
      ClaudeSessionRegistry.swift ~/.claude/sessions/<pid>.json から sessionId を引く
      TranscriptPoller.swift      実況層: 末尾差分を State に映す（ツール・ブランチ・題・スキル・サブエージェント・フックの待ちを解く）
      TranscriptTail.swift        実況層: jsonl の末尾差分の読み取り（ai-title の遡り primeMeta）
      HookIntake.swift            フック層: payload の読み取り・待ち行列（HookInbox・取りこぼしの数え上げ）・State への反映（HookIntake）
      Attention.swift             要対応の判定・待ち始めの時刻・権限待ちの説明
      PermissionWaiters.swift     権限の待ち合わせ: 預かり（セッションの対応付け）・待ち手の登録と期限切れ・判断・端末側で答えられた分の始末
      PermissionRegistry.swift    Channels の権限確認の保留・長ポーリングの待ち手・取り置き
      UsagePoller.swift           使用量: ファイルを読み直して変わった時だけ返す
      TranscriptLog.swift         会話履歴の整形（発話・応答・ツール）と画像の取り出し（行の位置を覚えて読み直す）
      TranscriptStore.swift       会話履歴の取得と追記の購読（250ms）を持つ actor
      SessionMessaging.swift      受信箱ソケットへの伝言（Unix ソケット・自分の所有のソケットだけ）
      UsageReader.swift           使用量ファイル（statusline.sh が書く）の読み取り
      XcodeFinder.swift           作業場所の .xcworkspace / .xcodeproj 探し（会話の見出しの「Xcode」「閉じる」・ディレクトリの詳細の「iPhone のプレビュー」と iPhone の API が使う）
      ClaudeHome.swift            ~/.claude のパス・スラッグ・transcript の場所
      JSONLoose.swift             JSON の値を typeof の厳しさで読む（NSNumber の 1 を true と取り違えない）・行の絞り込みのバイト列検索
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
      ChannelProtocol.swift       stdio の MCP（改行区切りの JSON-RPC 2.0）の読み解きと応答（initialize / ping / 未対応メソッド / 権限確認の通知）
      ChannelRelay.swift          受け口への長ポーリング（再試行 5 秒・30 分で諦める）と応答の読み分け
      ChannelServer.swift         stdin を行で読み、中継して判断を stdout に返す（ログは stderr）
    Settings/                   設定（settings.json）の型・読み書き（0600・原子的・読めないファイルは上書きしない）・検証・
                                projects.json からの移行・旧 TSV / 書き出したものの取り込み・「+」と設定画面が共有するストア（SettingsStore）
    Projects/                   ルームとプロジェクトの照合と、見出しのボタンの先
      GitHubLinks.swift           ルームの cwd と設定のプロジェクトの対応（ProjectMatcher）と GitHub の URL（ボード / リポジトリ）
      ProjectLinks.swift          設定のリンク（LP 等）の URL の検証（http / https で host のあるものだけ）と、見出しの「リンク」に出すもの
      ProjectBadge.swift          プロジェクトの印（色のキー `ProjectColor`・SF Symbol）の解決。無い時は名前のハッシュの色と `folder`、設定画面のアイコンの候補
      EditorActions.swift         見出しの「VS Code / GitHub / リンク / Xcode / 閉じる」の結果の文言と、Xcode からワークスペースだけを閉じる AppleScript（osascript）
      ProjectDirectories.swift    「ディレクトリ」の一覧の組み立て・並び・検索・セッションの件数と状態の集計
      LinkReminder.swift          リンクの「毎月 N 日に確認」の判定
      LinkVisits.swift            リンクの最終確認日（link-visits.json）の型と読み書き
      LinkOverview.swift          横断のリンク一覧の組み立て（節・絞り込み・確認が必要な数）
      LinkTitle.swift             ページの <title> の読み取り（文字コードの判別・切れた UTF-8 の扱い）
      ProjectImages.swift         ディレクトリの詳細の「画像」の走査とグループ化・浅い順の走査（ProjectTree。「iPhone のプレビュー」と共有）
      DirectoryTabs.swift         ディレクトリの詳細のタブ（並び・出せるタブ・覚えたタブの復元と先頭へ戻す・プロジェクトごとの記憶）
    Previews/                   ディレクトリの詳細の「iPhone のプレビュー」（Xcode の RenderPreview）
      SwiftPreviews.swift         Swift のソースから #Preview を静的に拾う（コメント・文字列を飛ばす字句の読み取り・走査）
      XcodeBridgeProtocol.swift   mcpbridge の JSON-RPC の組み立てと読み取り（ping への返事）・呼んでよいツールの許可リスト・失敗の見分け・Xcode のプロジェクトの中のパスとの対応・開いているワークスペースの一覧の読み取り
      XcodeBridgeClient.swift     MCP クライアント（握手・1 件ずつの要求・時間切れで止める（止め切ってから次を起動）・パッケージの読み込み中は待って頼み直す・開く前の一覧で自分で開いたかを見分ける）
      XcodeSelection.swift        つなぐ Xcode の選び方（動いている Xcode を数え直す・複数なら xcode-select・DEVELOPER_DIR）
      PreviewQueueRules.swift     待ち行列の止め方（時間切れ・読み込み待ちが続いた時・節が閉じた時）
      XcodeBridgeProcess.swift    `xcrun mcpbridge` の子プロセス（新しいプロセスグループ・stdin / stdout の 1 行 1 メッセージ・グループごとの停止）
      PreviewSnapshotCache.swift  描いた PNG と添え書きのキャッシュ（鍵・置き場・写す前の絵の確かめ・古い版と消えたプロジェクトの片付け）
    Sites/                      ディレクトリの詳細の「サイト」（LP のプレビュー）
      SiteLocator.swift           LP の場所の自動検出と、設定の `site`（相対パス）の検証・解決（プロジェクトの外を指さない）
      SiteFiles.swift             配信のパスの解決（書き出しの外・隠しファイルは返さない・フォルダは index.html・拡張子なしは .html）と Content-Type
      SiteServer.swift            書き出しの静的配信（サイトごとに 127.0.0.1 のランダムなポート・GET / HEAD のみ。SitePreviewServers）
      SiteViewport.swift          表示幅（PC / タブレット / スマホ）と縮める率・欄の幅とタブの中で使える高さからの高さの上限・サムネイルのキャッシュの名前・プレビューの中で開いてよい行き先
      DevServerRules.swift        開発サーバーの起動条件（dev スクリプト）・子の環境・出力からのアドレスの読み取り・失敗の理由・出力の末尾・止める手順
      DevServerProcess.swift      開発サーバーの子プロセス（新しいプロセスグループで起動・出力と終了の通知・グループごとの停止。起動と停止の手順 ProcessGroup は mcpbridge と共有）
    Limit/
      LimitGuard.swift            上限到達の判定（公式の残量 / 画面末尾の上限表示）
      LimitState.swift            上限到達の記録（limit-state.json）と、続けて止めた分をまとめた知らせの文言
    Chat/                       チャット画面の UI に依らないロジック（テスト対象）
      RelayNotes+Failure.swift    伝言の送信失敗の理由（監視の失敗種別を言葉にする。伝言そのものは DeckCore）
      SessionHandover.swift       アプリに引き継ぐ: sessionId の検証・終了対象の確認（pid / sessionId / 起動時刻 / プロセス）・SIGINT → SIGTERM
      RoomRedirects.swift         引き継ぎで移った後に元のルーム宛てに届く取り込みの結果を、移し先のルームへ付け替える表
      SessionRestore.swift        前回のセッションの記録の読み書き（HostedSessionsFile・HostedSessionsLock）・再開するかの判定・
                                  再開の直後に落ちたかの判定・続きを頼む時機（ResumeNudgeGate）・
                                  終了の確認の要否と文言（QuitConfirmation）・「作業が終わったら終了」の待ち（QuitWait）
      Attachments.swift           添付: 送る形の組み立て（画像パスの貼り付け用エスケープ・本文へのパスの一覧）・ペーストボードからの拾い出し・一時保存と掃除
      AttachmentPasteTextView.swift 添付を受ける文字欄（⌘V のメニュー検証・貼り付け・ドロップ）。入力欄の SubmitTextView の土台
      PTYInput.swift              PTY に送るキー列（貼り付け・Enter・権限の Yes / Esc・矢印・制御文字の除去）と、画面からの権限プロンプト / 選択メニューの判定
      MenuPrompt.swift            選択メニューの中身の読み取り（ChoiceMenu.parse）と、矢印で選択肢まで動かして Enter する手順（MenuNavigator）・問いのタブを移る手順（MenuTabMover）
      MenuScreenLog.swift         選択肢カードを出した・読めなかった画面の写しを直近数件残す
      ScreenPane.swift            画面の右に縦線で区切って出る別の欄（差分パネル）を除いて左だけにする
      ComposerSync.swift          入力欄とモデルの下書きの同期判定（変換中は本当の外部変更の時だけ書き戻す）
      ComposerPlaceholder.swift   入力欄の空欄の案内の出し分け（端末ビューの表示内容で見る・変換中は隠す）
      RoomListMode.swift          左の一覧の見方（ルーム / ディレクトリ）と要対応の件数
      ListPaneWidth.swift         左の一覧の幅（範囲・保存値の収め方・ドラッグで中央の最小幅を割らない計算）
      HeaderOverflow.swift        見出しのボタンが入りきらない時に「…」へ回す順（優先度の低いものから）
      DetachedRooms.swift         別ウィンドウで開いているルーム（同じルームは 1 枚・引き継ぎでの付け替え）・会話を取得し既読にする対象（ShownSessions）・
                                  手元に持つ会話の決め方（TranscriptRetention）
      DetachedBubbles.swift       別ウィンドウで開いている吹き出し（sessionId と項目の id の鍵・同じ吹き出しは 1 枚・開ける吹き出しの判定・タイトル）
    Stage/                      ステージパネルの文言・判定（StageLogic）、3D の寸法・配置・動き（StageBlueprint / StageScene）、
                                SceneKit のノードへの起こし（StageSceneRig）・背景側の色（StageBackdrop）・設定画面の見本（CharacterGallery）
    Theme/                      カラーテーマ（DeckTheme: ナイト / ライトの色の組）・会話の Markdown の文字の段階（ChatTypeScale）
    Notify/                     通知にする要対応の組み立て（AttentionNoticeSource）と iCloud を使えるかの確認・失敗の文言（CloudKitNoticeStore）
    Support/                    共通の下回り
      DeckCoreExport.swift        共有パッケージ DeckCore（../packages/DeckCore）を再公開する（監視のドメイン型・Remote API の型・
                                  Markdown の解析・会話の組み立て・ルームのグループ化・ドット絵は DeckCore にある。iPhone アプリと共有）
      TerminationSignals.swift    SIGTERM / SIGINT を何もしないハンドラで捕まえる（子に SIG_IGN を漏らさない）
      ChildEnvironment.swift      子プロセス（claude・開発サーバー・mcpbridge）の環境から API キーと Claude Code の子セッション印を除く
      SecureFile.swift            0600・置き換えで書く
      DeckPaths.swift             Application Support / Caches / Logs の claude-deck と、環境変数で差し替える設定ファイルの場所
      Paths.swift                 realpath・フォルダか・ファイルの種類・URL の 1 区間のエンコード
      Concurrency.swift           一度だけ通す印（OnceFlag）と、持ち主が消えたら止まる繰り返し（repeatingTask）
  Sources/ClaudeDeckChannel/    Claude Code が子プロセスで起動するチャネル（stdio の MCP サーバー・実行ファイル claude-deck-channel）
  Tests/ClaudeDeckTests/        MonitorKit のテスト（swift test）。Sources と同じ区分のサブディレクトリ（Hub / Store / Limit / Projects / Chat / Channel /
                                Server / Remote / Settings / Sites / Previews / Notify / Stage / Terminal / Theme / Support / Scripts）。共通の補助は Support/TestSupport.swift・Hub/FakeClaudeHome.swift
  docs/remote-api.md            iPhone 向けの口の仕様（エンドポイント・型・ペアリング・TLS・上限）
  docs/pty-daemon.md            アプリを閉じても claude を動かし続ける常駐プロセスの設計と試作の記録（未実装）
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
  状態の合成・終了後 5 分の保持・要対応の時刻（`attentionSince`）・権限待ちの説明・未知の通知のフィード化は `SessionHub` と、それが順に回す層
  （`InventoryScanner` / `TranscriptPoller` / `HookIntake` / `PermissionWaiters` / `UsagePoller`。すべて `SessionHub` の actor の上で動き、
  セッションの辞書と配信は `SessionHub` だけが持つ）。
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
  件数をログとそのセッションのフィードに出す。時刻の取得と積み込みは一続きで、待ち行列の順＝時刻の順。
  届いた後のログ活動を反映前に読んでいれば、権限待ち等は答え済みとして出さない（数えるのは親ログの活動だけ。親が確認で止まっている間も
  サブエージェントは書き続けるので、その活動は数えない。Channels の保留の取り下げも同じ基準）
- 止めて開き直す時は、前の待ち受けがポートを手放すのを待つ（最大 2 秒）
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
- ボードの中身の表示はアプリには無い（見出しの「GitHub」でブラウザに開くか、`gh project item-list` で見る）。

## メイン画面: チャット

Claude Code のセッションを**チャットアプリの操作感**で扱う。セッション 1 つ = トークルーム 1 つ。
右側はステージパネル（`MainViewController` で `ChatRootView(model:) { StagePanel(model:) }` として差し込む）。

### 一覧の切り替えバー（左端 48px）

- ウィンドウの左端の細いバーに、アイコンだけのボタンを縦に並べる。「ルーム」（`bubble.left.and.bubble.right`）は状態別の一覧、
  「ディレクトリ」（`folder`）は登録プロジェクトの一覧。選んでいる方を強調し、名前はホバーの吹き出し（見出しのボタンと同じ自前のツールチップ）と読み上げで出す。
- 選択は UserDefaults（`roomList.mode`）に保存し、既定は「ルーム」。知らない保存値も「ルーム」に戻す。
- 要対応（権限待ち・入力待ち）のルームがあれば「ルーム」アイコンに件数のバッジ（検索で隠れた分も数える。100 件以上は「99+」）。
- 「+」・監視の案内・選択中のルーム・未読は両方の一覧で共通（検索欄は見方ごとに対象が違うので、切り替えたら空に戻す）。切り替えても中央の表示と選択中のルームは変えない（会話を出していて未選択の時だけ、「ルーム」で見えている最初の行を選ぶ）。
- 見方の型と件数は `Sources/MonitorKit/Chat/RoomListMode.swift`（テストあり）、画面は `Sources/ClaudeDeck/Chat/Views/RoomList/ListModeBar.swift`。

### ルーム一覧（既定 312px・幅は変えられる）

- 幅: 一覧と中央の境界（1pt の線から中央側へ 8pt をつかめる。一覧のスクロールバーには重ねない。カーソルは左右の矢印）をドラッグして 240〜480px で変える（ルーム / ディレクトリ共通）。
  広げるのはつかんだ時の中央（会話・ディレクトリの詳細）が 420px を保てる分まで。ダブルクリックで既定の 312px に戻す（広げる時は同じく中央の余りの分まで）。
  幅は離した時（とダブルクリック）だけ UserDefaults（`roomList.width`）に保存し、ドラッグ中は手元の幅で描く。知らない値・範囲外は範囲に収める。
  ステージパネルを自動で畳む幅もこの幅を使う（下記「ステージパネル」）が、ドラッグ中はつかんだ時の幅のまま判定し、離した時に反映する（途中で開閉を往復させない）。
  ウィンドウの最小幅は一覧の幅に応じて中央 420px を保てる幅（切り替えバー 48 + 境界 3 本 + 畳んだパネル 36 + 一覧 + 420）に掛け直す。
  起動時・保存されたウィンドウが狭い時は、保存値は変えずに一覧を中央 420px が保てる幅まで縮めて描く。
  範囲と計算は `Sources/MonitorKit/Chat/ListPaneWidth.swift`（`ListPaneDrag` を含む。テストあり）、状態・つかむ所・ウィンドウの最小幅は `Sources/ClaudeDeck/Chat/Views/ListPane.swift`
  （`ListPaneLayout`・`ListPaneDivider`・`ListPaneWindowSync`。中央の幅は観測しない箱に持ち、ウィンドウの伸縮で画面全体を描き直さない）。
- 見出しは今の見方の名前（「ルーム」/「ディレクトリ」）。
- **「ルーム」**: 監視が見つけたセッション + アプリでホスト中のセッションを **要対応（権限待ち・入力待ち）→ 稼働中 → 待機** の見出しで並べる
  （空の段は出さない・各段は最後に動いた順・同時刻は名前順）。組み立ては DeckCore の `RoomGrouping`。
- 状態は監視の `SessionSnapshot.status`。監視の開始前は、ホスト中のセッションだけ端末画面からのローカル判定（作業中 / 権限プロンプト / 待機）で代わりに出す。
- **「ディレクトリ」**: 設定（settings.json）に登録したプロジェクトの一覧。設定の順で、進行中（active）を上に、休止・保管（paused / archived）は
  「休止・保管」の見出しの下にまとめて薄く出す（設定の変更はすぐ映る）。各行は印（直径 22px の色の薄い塗りの丸（縁取りなし）に SF Symbol のアイコン。設定の `color`（`ProjectColor` の 11 キー）/ `icon`、無ければ名前のハッシュで従来の 8 色から決めた色
  （`ChatTheme.avatarColor(for:)`。キーとナイトの値は従来と同じで、ライトは紫・桃・橙・青緑の 4 色が名前どおりの色相の濃い版）と `folder`。知らない色は警告にして名前の色、
  無い Symbol は `folder` に落とす。解決は `Sources/MonitorKit/Projects/ProjectBadge.swift`（テストあり）・絵は `ProjectBadgeView`（`RoomRow.swift`）で、詳細の見出しと「+」の一覧も同じ印。
  行の右クリックの「アイコンと色を変更…」で設定画面のプロジェクトタブの該当プロジェクトを開く）・名前・パスの末尾・
  そのプロジェクトで終了していないセッションの件数と、その中でいちばん急ぐ状態（要対応は色の地）。セッションの照合は「GitHub」ボタンと同じ
  （status を問わず全プロジェクトで、cwd がプロジェクトの path と一致か配下・いちばん深い path。`ProjectMatcher`。外部セッションも登録済みの path の配下なら数える）。
  名前の右に、確認の日を過ぎてまだ開いていないリンクがあれば小さな黄色の点（要対応のバッジとは別。下の「リンク」）。
  検索欄は名前とパスで絞る（空白区切りで AND）。右クリックで「Claude Code を起動」「Finder で表示」。組み立て・並び・検索・件数と状態の集計は
  `Sources/MonitorKit/Projects/ProjectDirectories.swift`（テストあり）、行は `Views/RoomList/DirectoryRow.swift`。
  最上部（検索欄の下）に固定の行「リンク」（SF Symbol `link`・右に確認が必要なリンクの件数。検索で消えない。`LinkOverviewListRow`）があり、押すと中央に全プロジェクト横断のリンク一覧を出す
  （`ChatCenter.links`・`Views/Links/LinkOverviewView.swift`）: 種類の絞り込み（すべて / 請求 / ダッシュボード / ストア / ドキュメント / その他）と「確認が必要なものだけ」、
  プロジェクトごとの節（status を問わず・開けるリンクのあるものだけ・設定の順。名前・パスの末尾・「詳細を開く」）に各リンクの行
  （確認のバッジ・種類・名前・URL（中略）・前回・ピンの印・2 行目にメモと「毎月 N 日に確認」）。押すとブラウザで開いて最終確認日を記録する。編集はしない（「詳細を開く」で詳細へ）。
  組み立て（節・絞り込み・確認が必要な数）は `Sources/MonitorKit/Projects/LinkOverview.swift`（テストあり）。
  - 行を押すと中央（会話の場所）にプロジェクトの**詳細**を出す（`Views/Directory/DirectoryDetailView.swift`）。見出しは名前・状態・パスと、
    アイコンだけのボタン「Claude Code を起動」（動いているルームがあれば「ルームへ移る」。「+」と同じ起動経路・`ChatModel.launch`）・「VS Code」・「Finder」・
    「GitHub」・「リンク」（会話の見出しと同じ部品と挙動。紐づけ・リンクが無ければ出さない）・「Xcode」「閉じる」（プロジェクトの path の配下に
    `.xcworkspace` / `.xcodeproj` がある時だけ。会話の見出しと同じ処理で、検出の結果は cwd ごと、閉じる処理中の印は押した先（ルーム / プロジェクト）ごとに `EditorLauncher` が持つ）・
    「設定で編集」（設定画面のプロジェクトタブでそのプロジェクトを選んで開く）。
    見出しの直下にタブの列（`Views/Directory/DirectoryTabBar.swift`）があり、本文は選んだタブの節だけを欄いっぱいに出す（画像やプレビューが多くても他の節へ 1 クリックで行ける）。
    タブはサイト（下記）・画像（下記）・iPhone（iPhone のプレビュー。下記）・リンク（下記）・スレッド（そのプロジェクトのスレッド。ルーム一覧と同じ行。終了したルームも含み、押すとそのルームを選んで中央が会話に戻る）の順。
    - 件数: 画像・iPhone は走査し終えた時だけ（それまでは数字なし）、リンク・スレッドは常に添える。
    - 出す条件: 「サイト」は LP の場所が見つかった時と、設定の `site` が使えない時（理由を見せるため）だけ。開いた時に場所だけを軽く探し（`SiteLocator.lookup`）、分かるまでは出しておいて無いと分かったら消す
      （後から足すと並びがずれるため、消す向きにだけ動かす）。LP が無く公開リンクだけのプロジェクトでは出さない（リンクには請求やダッシュボードも混ざり、勝手に読み込まないため。リンクのタブからブラウザで開く）。調べるのは詳細を開いた時の 1 回で、開いている間に LP を作った時は別のディレクトリへ移って戻ると出る。「iPhone」は `.xcworkspace` / `.xcodeproj` がある時だけ。画像・リンク・スレッドは常に出す（空なら中で「なし」）。
    - 覚え方: 最後に押したタブをプロジェクトごとに UserDefaults（`directory.tab.<プロジェクトの id>`）に覚え、次に開く時はそのタブ。初めては出せるタブの先頭、覚えたタブが出せなくなっていたら先頭に戻る（覚えた値は押した時だけ書き換える）。
    - 走査・描画はそのタブを開いた時に始め、タブを離れると画面ごと消えて走査中のものは取りやめる。走査の結果と「再読み込み」の回数は詳細（プロジェクトごと）が持つので、タブを行き来しても走査し直さない。
      タブを替えるとスクロールは先頭に戻る（サイトで選んだ見る元は詳細が持ち、タブを替えても保つ）。別のプロジェクトへ移れば選んだタブ・走査の結果・見る元を持ち越さない（`.id(project.id)`）。
    - 入りきらない幅ではアイコンを外し、それでも入らなければ列を横にスクロールする（選んだタブを見える所へ寄せる）。選んだタブは太字と下線（`ChatTheme.selectionInk`）。
    - 出せるタブ・覚えたタブの復元・先頭へ戻す判定は `Sources/MonitorKit/Projects/DirectoryTabs.swift`（テストあり）。
    パス・状態・メモ・GitHub の紐づけは本文に出さない（見出しのパスと状態のほかは設定画面で見る）。
    本文は中央の欄の幅いっぱいに使う（文章のタブは読みやすいよう 900px まで、サイトのプレビューと画像は欄いっぱい）。
  - **リンク**（詳細のタブ）: 設定の `links` を全部、種類のアイコン・名前・URL（中略）の行で出す。開けるものは押すとブラウザで開き（開けた時だけ最終確認日を記録）、
    開けない形・名前の重複は理由付きで薄く出す。各行の右にピン（`pin` / `pin.fill`。押すと `pinned` を切り替え。付いている間は常に見せる）と
    「前回: M/D」（未記録は「未確認」）、2 行目にメモと「毎月 N 日に確認」、確認の日を過ぎてまだ開いていなければ先頭に小さな黄色のバッジ「確認」（`LinkDueBadge`）。
    ホバーで「編集」「上へ」「下へ」「削除」（削除は確認なし・並べ替えは上下だけ）、節の下に「+ 追加」。
    - 追加・編集はポップオーバー（名前・URL・種類の Picker・メモ（1 行）・「毎月」のトグルと日（1〜31 の Stepper）・ピンのトグル・問題の一覧・「キャンセル」「保存」）。
      検証は設定画面と同じ（名前必須・http / https で host あり・同じ名前は不可・確認の日は 1〜31）で、問題がある間は保存できない。編集で URL を変えた時は最終確認日を新しい URL へ写す。
    - 「+ 追加」はクリップボードに http / https のアドレスがあれば URL 欄の初期値にし、種類を `ProjectLinkKind.suggest(for:)`（host とパスを小文字で見て、
      `billing` / `invoice` / `usage` / `payment` / `subscription` → 請求、App Store Connect・apps.apple.com・play.google.com → ストア、`docs.` 始まりか `/docs` 始まり → ドキュメント、
      `console.` / `dashboard.` / `app.` / `platform.` 等の始まりか vercel.com・github.com 等 → ダッシュボード、それ以外はその他）、名前を `ProjectLinks.suggestedName(for:)`
      （host の `www.` と TLD を除いた主要部分を先頭大文字に。`co.jp` 等は末尾 3 ラベルで見る）で提案する。URL 欄を書き換えた時も種類・名前を触っていなければ提案し直し、
      種類に触れていなければ元の `kind`（無ければ無いまま）を保つ。
    - クエリの無いアドレスは、加えてページの `<title>` をバックグラウンドで取りに行き（`LinkTitleFetcher`。http / https・3 秒・資格情報なし・本文は先頭 256KB で `</title>` が見えたらそこまで・
      時間切れでも読めた分から抜く。読み取りは `Sources/MonitorKit/Projects/LinkTitle.swift` で、末尾の切れた UTF-8 を落とし `<meta charset>` の Shift_JIS / EUC-JP も読む。テストあり）、
      利用者が名前を触っていない時だけ置き換える（閉じたら捨てる・取れなくても何も出さない）。クエリ付きのアドレスは一度きりのログイン用リンク等を使い切らないよう自動では取りに行かず、
      名前欄の横のボタンで頼んだ時だけ取って名前に入れる。
    - 保存は `SettingsStore.updateProject` で `links` 全体を 1 回で置き換えて即時に書く（設定画面を開いていても揃う）。編集・並べ替え・削除は開いた時の行と今の行が一致する時だけで、
      設定画面の溜めていた変更が先に当たって行がずれた時は保存せずその旨を出す。部品は `Views/Directory/ProjectLinkEditor.swift`。
  - **画像**（詳細のタブ）: プロジェクト配下の画像（png / jpg / jpeg / gif / webp / heic / heif / svg / tiff / bmp / ico）をフォルダ（相対パス・件数）ごとにサムネイルのグリッドで並べる
    （`Views/Directory/ProjectImagesSection.swift`）。iPhone 側には出していない。
    - 隠しフォルダ・隠しファイルと `node_modules`・`.next`・`out`・`build`・`dist`・`Pods`・`DerivedData`・`vendor`・`.build`・`.swiftpm`（`SiteLocator.skipped` + 2 つ。大文字小文字は区別しない）の中は見ず、
      フォルダのシンボリックリンクは辿らず、ファイルのリンクは実体がプロジェクトの中にある時だけ数える。深さ 8・画像 2,000 件・フォルダ 20,000 個で打ち切る
      （浅いフォルダから画面と同じ自然順で集めるので、超えた時は深い分・後ろの分が落ちる旨を出す）。
    - `.xcassets` の中（imageset / appiconset）はその `.xcassets` で 1 グループ。グループは浅い順 → 名前順、中は名前順（数字は自然順）。
    - 枠はサムネイル・ファイル名（中略）・「W×H・サイズ」（寸法は絵と一緒に枠ごとに持つ。HEIC は主画像・ICO はいちばん大きいフレーム。SVG 等 ImageIO で読めないものは寸法なしで NSImage で描く）。
      クリックで拡大のシート（Esc で閉じる・Finder で表示）、右クリックで「Finder で表示」「パスをコピー」。
    - 走査とサムネイルの縮小はバックグラウンドで行い（デコードは同時 4 枚まで。`DecodeGate`。枠が画面から消えれば待たずにやめる）、縮小した絵は NSCache に持つ（更新時刻をキーに含めるので再読み込みで新しい絵になる）。
      表示された枠だけ読み（`LazyVGrid`）、「再読み込み」で走査し直し、別のプロジェクトへ移れば持ち越さない（`.id(project.id)`）。ファイルの監視（自動更新）はしない。
    - タブを開いた時に初めて走査する（離れれば走査中のものは取りやめ、次に開いた時にやり直す）。グループは畳める（タブを開いている間だけ）。
      画像が無ければ「画像なし」。
    - 走査とグループ化は `Sources/MonitorKit/Projects/ProjectImages.swift`（テストあり）、ストアは `Chat/Model/ProjectImageStore.swift`。
  - **iPhone のプレビュー**（詳細の「iPhone」のタブ。プロジェクトの path の配下に `.xcworkspace` / `.xcodeproj` がある時だけ。開くのは「Xcode」ボタンと同じもの（`XcodeFinder`））:
    iOS アプリの SwiftUI の `#Preview` を、**起動中の Xcode の MCP（`xcrun mcpbridge` の `RenderPreview`）**で描いて並べる（`Views/Directory/IOSPreviewsSection.swift`）。iPhone 側には出していない。
    - 一覧（ビルド不要）: Xcode のプロジェクトのあるフォルダの下の Swift ファイルを浅い順に読み、`#Preview`（名前・`traits:` 付きも）をファイルごとに上から数える。
      コメント・文字列（複数行・raw・補間の入れ子。32 段を超えたらそこで読むのをやめる）の中は数えず、名前は最初の引数がラベルの無い文字列の時だけ。
      型の宣言の継承節の `PreviewProvider`（`SwiftUI.` 付きも。ジェネリクスの制約・型注釈は除く）は一覧に出さないが、Xcode の `previewDefinitionIndexInFile` と番号をそろえるため数える。
      `#if` で分岐した `#Preview` は両方数えるので番号がずれうる（下の「行の照合」で検出）。隠しフォルダ・「画像」と同じ依存 / 成果物のフォルダ・`.xcodeproj` / `.xcworkspace` / `.xcassets` の中は見ず、リンクは辿らない。
      深さ 10・Swift ファイル 5,000 件・フォルダ 20,000 個で打ち切り、2MB を超えるファイルは読まない。走査は `Sources/MonitorKit/Previews/SwiftPreviews.swift`（テストあり）。
    - 描画: mcpbridge（stdio の JSON-RPC 2.0・1 行 1 メッセージ）と `initialize`（protocolVersion `2025-06-18`）→ `tools/list` で `RenderPreview` を確かめ（無ければ Xcode 27 以降が要る旨）→
      `XcodeListWorkspaces`（開く前から開いているか）→ `XcodeOpenWorkspace` → `XcodeGlob`（`**/<ファイル名>`）で Xcode のプロジェクトの中のパスを引き → `RenderPreview`（時間切れ 300 秒）。
      - Glob の結果はディスク上の相対パスと末尾の区間がいちばん長く一致するものを使う（グループ名がフォルダと違っても合う）。同点が複数・結果が打ち切られた時は、別のファイルを描かないよう「プロジェクト内で特定できない」と出す。
      - 開いた ID は mcpbridge が動いている間だけ使い回す。**利用者が開いていたもの（同じパスか、返った ID が開く前の一覧にある。一覧を読めない時も）は閉じない**。別のプロジェクトを描く時・止める時は、自分で開いたものだけを `XcodeCloseWorkspace` で閉じる。
      - `isError` が false でも本文が `{"type":"error",…}` なら失敗。返った `previewSnapshotPath` は絶対パス・リンクでない通常のファイル・`.png`・PNG の署名・50MB 以下を（リンクを辿らずに開き直して）確かめてから
        `~/Library/Caches/claude-deck/ios-previews/<project-id>/`（0700 / 0600）に写し、名前・行・端末・切り替えの候補・ソースの更新時刻を隣の JSON に残す。相手の `ping` には空の result（知らない要求には Method not found）、id が null の失敗は待っている 1 件を失敗にする。
      - **呼ぶツールは `XcodeOpenWorkspace` / `XcodeCloseWorkspace` / `XcodeListWorkspaces` / `XcodeGlob` / `RenderPreview` の許可リストだけ**で、それ以外（書き換え・Run・テスト・ビルド設定等）は要求を組み立てる所で拒む（`XcodeBridgeTool`）。
        ソースは変えない（Xcode が DerivedData・xcuserdata 等を更新することはある）。
    - mcpbridge はアプリ全体で 1 本・描くのは 1 件ずつ（要求も直列）。子の環境から API キー・子セッション印を除く（`ChildEnvironment`）。
      **描くたびに動いている Xcode を数え直して**つなぐ先を決め（`XcodeSelection`。1 つならそれ、複数なら xcode-select の Xcode、どちらでもなければ決めずに案内を出す）、その `.app` の `Contents/Developer` を `DEVELOPER_DIR` で渡す（違う版の mcpbridge を使わないため）。
      PID か Developer フォルダが変わった時・Xcode が動いていない / mcpbridge が使えない失敗の時は、mcpbridge を捨てて次は作り直す。
      - **`MCP_XCODE_PID` は渡さない**（親の環境にあっても消す）: 渡すと GUI の Xcode へ直につなぎ（passthrough）、ウィンドウが無いと接続を断られて mcpbridge が終わる（「Rejecting connection - no workspace windows are open.」）。
        渡さなければ Xcode の中の headless の `Xcode Service` へつなぎ（router）、ワークスペースもそこで開く（GUI のウィンドウは開かない）。Xcode 27（mcpbridge 25317）で確認。
      - 何も開いていない時、2 回目以降の `XcodeListWorkspaces` は返らない（同じ版で確認）ので、開く前の一覧は起動し直した mcpbridge の最初の呼び出しにする。一覧は 10 秒で諦め、その時は自分で開いたとはみなさない。
      - 開発サーバーと同じく**新しいプロセスグループ**で起動し、止める時は stdin を閉じてからグループごと SIGTERM → 3 秒 → SIGKILL（`ProcessGroup`・`DevServerStopPlan`）。止めるのは、どこでも「iPhone」のタブが開いていない状態が 3 分続いた時
        （自分で開いたものを閉じてから）・アプリの終了（`applicationWillTerminate` と SIGTERM / SIGINT の経路で止め切るまで待つ）・開いているプロジェクトが設定から消えた時（描いている 1 件の後）。
      - 要求の時間切れでは、遅れて届く応答と食い違わないよう mcpbridge ごと止める（止め切るまで次を起動しない）。開いた直後の「Waiting for packages to load」は 3 秒おきに最大 3 分頼み直す。
        時間切れ・読み込み待ちが続けて 2 回出たら、待っている分を描かずに戻して理由を出す（`PreviewStallCounter`）。
    - **初回の承認**: Xcode は MCP の相手（mcpbridge を起動したアプリ。実地ではプロジェクトを替えた時にも求められた。`.app` と `swift run` は別の相手になりうる）ごとに、メニューバーの Xcode の MCP のアイコンでの許可を求める。
      未承認の間は `XcodeOpenWorkspace` が 1 分ほど待ってから「waiting for the user to approve」を返すので、開いている間は案内を出し、返ったら許可してから描き直すよう出す。
    - 画面: タブを開いた時に走査し、「再読み込み」で走査し直す。全ファイルの `#Preview` を 1 つのグリッドに、描いた絵（縮小して NSCache）か名前と「描く」の枠
      （待機中・描いています・描けませんでした（クリックでもう一度。ホバーで理由）もその場に出す）・名前（無ければ表示名かファイル名）・ファイル名と行で並べる。
      - 描いた絵は鍵（プロジェクト・ファイル・番号・切り替えの組・言語・ソースの更新時刻）でキャッシュし次回もすぐ出す。ソースを書き換えると描き直すまで出さない（その回に描いた絵も、走査した時の更新時刻と一致する時だけ出す）。同じ指定の古い版は書いた時に消す。
      - 「すべて描く」はまだ今のソースの絵が無いものを順に待ち行列へ。描いている間は「取りやめる」（待っている分を外す。描いている 1 件は終わるまで待つ）。
        **そのプロジェクトの「iPhone」のタブがどこにも開いていなくなったら（別のタブへ移った・別のプロジェクトへ移った等）待っている分を取りやめる**（`PreviewSectionPresence`）。
      - 行の照合: Xcode が返した `sourceLineNumber` が一覧の行と違えば、枠の下と拡大のシートに「別のプレビューの可能性」を出す。
      - 描いた枠のクリックで拡大のシート（Esc で閉じる）: 返った候補（外観・文字の大きさ・向き・コントラスト・ボタンの枠・言語）を「既定」か値から選んで描き直す（組ごとに別にキャッシュ）・表示名・端末・描いた時刻・Finder で表示。
        右クリックで描く / 描き直す・ソース / 画像を Finder で表示・パスのコピー。
    - 失敗の案内: Xcode が動いていない（タブを開いている間は 3 秒おきに見る。動いていなければ mcpbridge を起動しない）・未承認・ビルド失敗（ログの `error:` の行を先頭から 3 行）・時間切れ・
      そのプレビューだけの失敗（`{"type":"error","data":…}` の中の文言）・ファイルが Xcode のプロジェクトに無い / 特定できない・返った絵を写さなかった・描いている間にソースが書き換わった（「再読み込み」で出る）。
      Xcode が無い・未承認・ビルド失敗など続けても同じ失敗になるものは、待っている分を描かずに戻して節の上に理由を出す（× で消せる）。
    - 実地（sandora・Xcode 27）: 初回はビルドを含んで約 100〜110 秒、同じプロジェクトの別ファイルは約 60 秒、同じファイルの別のプレビューや外観の切り替えは 1〜10 秒。開く前の一覧
      （「No workspaces are currently open.」/「* workspaceIdentifier: workspace-…, workspacePath: /…/random_talk.xcodeproj」）で自分で開いたものと既に開いていたものを見分けられることと、`sourceLineNumber` が走査した行と一致することを確かめた。
    - キャッシュの片付け: 起動時に設定に無い project-id のフォルダを消し（設定が読めない間は消さない）、動いている間に設定から消えたプロジェクトの分もその場で消す。
    - 判定（走査・JSON-RPC・失敗の見分け・パスの対応・キャッシュの鍵と絵の確かめ・つなぐ Xcode の選び方・待ち行列の止め方）と子プロセス・クライアントは `Sources/MonitorKit/Previews/`（テストあり。偽の mcpbridge と sh の子で確かめる）、持ち手は `Chat/Model/IOSPreviewStore.swift`。
  - **見出しのボタンが入りきらない時**（会話の見出しも同じ）: 名前とパスは省略表示（最小 140px）まで縮め、それでも入らなければ優先度の低いボタンから
    「…」（`ellipsis.circle`。ホバーで「ほかの操作」と回したボタンの名前）のメニューにまとめる。メニューの項目は同じ動作を呼ぶ
    （「GitHub」「リンク」で開く先が複数ならサブメニュー、処理中は状態を添えて押せない。「閉じる」の確認はメニューから押しても出る）。
    回す順は、詳細が「設定で編集」→「閉じる」→「Finder」→ ピン →「リンク」→「GitHub」→「Xcode」→「VS Code」→「Claude Code を起動」、会話が「閉じる」→ ピン →「リンク」→「GitHub」→「Xcode」→「VS Code」（ピンは「リンク」と同じ段で、その直前に右から隠れる）。
    候補は `ViewThatFits` で入るものを選ぶ（`Views/Conversation/HeaderActions.swift`）。回す順の計算は `Sources/MonitorKit/Chat/HeaderOverflow.swift`（テストあり）。
  - **サイト**（先頭のタブ）: プロジェクトの LP をアプリの中でプレビューする（`Views/Directory/SitePreviewSection.swift`）。
    - 場所: 設定の `site`（下記「設定（settings.json）」）があればそれ、無ければプロジェクト直下と 2 階層までのサブフォルダから探す
      （`next.config.{js,mjs,ts,cjs}` があるか、`package.json` と `out/index.html` がある所。`node_modules`・`.next`・`out`・隠しフォルダ等の中は見ず、
      見つけたサイトの中も探さない。シンボリックリンクのフォルダは辿らない）。複数あれば書き出し済み → 浅い → 名前の順で先頭を使い、候補がある旨を出す。
    - 見る元: 「書き出し」（`<サイト>/out/`）と、設定のリンクのうち http / https のもの（「公開: 名前」）。書き出しは `/_next/...` の絶対パスで参照し合うので
      file:// では崩れる。アプリの中の小さな静的配信で出す: サイトごとに **127.0.0.1 の OS が選ぶポート**（:8766 / :8767 とは別のサーバー）で、
      **GET / HEAD のみ**・**`out/` の配下だけ**（`..`・パーセントエンコードした `..`・シンボリックリンクで外へ出るものは拒否、`.` で始まる隠しファイルは返さず、リンクを解いた先が隠しファイルでも返さない。`out` 自体がリンクなら実体がサイトのフォルダの中にある時だけ使う）・
      Host は `127.0.0.1` / `localhost` の自分のポートだけ（DNS リバインディング対策）・接続元はループバックだけ。フォルダは `index.html`、末尾の `/` が無ければ 308 で補い、
      拡張子の無いパスは `.html` を補う（Next の export の両方の形。`blog.html` と index.html の無い `blog/` が並ぶ時は `/blog` に `blog.html` を返す）。無いものは `out/404.html` があればそれを 404 で返す。Content-Type は拡張子から（`nosniff`）。
      転送のクエリに制御文字があれば 400。大きさは属性から取り（HEAD では読まない）、`Range: bytes=` の単一範囲に 206 で答える（不正・範囲外・複数範囲は 416）。
      配信はアプリが動いている間だけ使い回す（待ち受けが後から落ちたら外し、次に開く時に別のポートで開き直す）。実装は `Sources/MonitorKit/Sites/`（テストあり。配信はループバックに立てて実際に取得・拒否を確かめる）。
    - 表示幅: PC 1280 / タブレット 820 / スマホ 390（CSS ピクセル）で組ませ、枠に収まるよう `pageZoom` で縮めて表示する（拡大はしない。スマホは角丸の端末の枠）。選んだ幅は UserDefaults（`sitePreview.viewport`）。
      高さの上限は欄の幅から決める（その幅で横いっぱいに収まる高さ）。ただしタブの欄の高さから見出しの行と案内の分を除いた高さ（欄の下端まで）を超えない
      （最小 320px は保ち、足りない時は欄をスクロールする。`SiteViewport.heightLimit`。テストあり）。
    - 見出しの行（「サイト」・見る元 / 幅の切り替え・再読み込み・ブラウザで開く）は 1 行に入らなければ 2 段に折り返す（見る元の名前は省略表示）。
    - 再読み込み（場所と更新時刻も確かめ直す）・ブラウザで開く（今開いているページ。http / https だけ）・書き出しの更新時刻（`out/index.html`）。
      `out/` が無ければ「`npm run build` で書き出すと見られます」の案内。書き出しがあって配信を開けない時はその旨と理由を出し、「再読み込み」で開き直す。
    - **開発サーバー**（見る元の 1 つ）: ▶ を押した時だけ、サイトの場所で `npm run dev` を起動する（`package.json` に `dev` スクリプトがある時だけ。
      無ければ理由を出してボタンを出さない）。起動は claude と同じく `/bin/zsh -lic` のログインシェルで PATH（nvm 等）を得て、
      `unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; exec npm run dev`。子の環境からも API キーと Claude Code の子セッション印を除き（`ChildEnvironment`。claude の起動と共通）、
      `BROWSER=none`・`NO_COLOR=1` を足す。stdin は `/dev/null`、stdout / stderr は 1 本にまとめて読む。**新しいプロセスグループ**（`posix_spawn` の `SETPGROUP`。`zsh -lic` でもシェル・npm・node が同じグループにそろうのを実地で確認済み）で起動し、
      止める時はグループごと SIGTERM → 3 秒待って残れば SIGKILL（`DevServerStopPlan`）。先頭のプロセスはグループが止まり切るまで刈り取らず、
      送る前に今も自分の子か（`waitid(WNOWAIT)`）を確かめる（番号の使い回しで別のプロセスに送らないため。グループの一覧を `sysctl` で取れない時は、先頭が生きていれば残っているとみなして手順を続ける）。
      **開発サーバーはルームではなくプロジェクト（サイトのフォルダ）に付く**ので、ルームを閉じても止めない。止めるのは停止ボタン・アプリの終了
      （`applicationWillTerminate` と SIGTERM / SIGINT の経路の両方で、片付け中のものも含めて止まり切るまで待ってから終える）・プロジェクトが設定から消えた時（設定が読めない間は止めない。止め切ってから一覧から外す）。
      止めている間は孫まで止め切るまで「停止中」のままで、先頭が自然に終わった時も、グループに残ったものを止め切るまでは片付け中として扱う（その間は同じサイトを起動しない）。
      自動では起動しない。同じサイト（フォルダ）は二重に起動しない（`DevServerStore`）。
      **アプリが強制終了・クラッシュした時（SIGKILL 等で終了の処理が走らない時）は開発サーバーが残りうる**（設計上の限界。残ったら `lsof -i :<ポート>` 等で見つけて止める）。
      - 出力の各行（色などの制御文字は落とす）から `http://localhost:NNNN` / `127.0.0.1:NNNN` を見つけてプレビューにつなぐ。Next の `- Local:` 行・Vite の `➜ Local:` 行を優先し、
        無ければ最初の手元のアドレス（後から `Local:` 行が出ればそちらへ乗り換え、`Local:` 行で決めた後は替えない）。前後に語の文字が続くもの（`xlocalhost` 等）は拾わない。
        `0.0.0.0` / `[::1]` は `localhost` で開き、LAN のアドレス・「使用中」のエラーの行のアドレスは使わない。プレビューで開くのは手元（localhost / 127.0.0.1）の
        アドレスだけ。**ページそのものの遷移は開いたアドレスと同じ origin（スキーム・ホスト・ポート）に限り**、それ以外の http / https のリンクは既定のブラウザで開く
        （`SiteNavigationPolicy.decide`。埋め込みの扱いと HMR の WebSocket は書き出しと同じ。書き出し・公開 URL の遷移の扱いは変えない）。
      - 出力は読んだ順に、まとめてメインへ渡す（受け手が詰まっている間は 256KB までためて古い方から捨てる）。行の分け方は読む位置をずらして最後に一度だけ削り、
        改行の来ない 16KB を超える行は UTF-8 の文字の境界で切る。画面の出力の反映は 0.2 秒に 1 回に間引く。
      - 出力の末尾 400 行を節の中で見られる（「出力を見る」）。起動に失敗した・すぐ終わった時は理由を出す: npm / node が無い（終了コード 127 等）・
        dev スクリプトが無い・ポートが使用中（`EADDRINUSE` / `Port N is already in use`）・それ以外は終了コード。
      - 判定（起動条件・アドレスの読み取り・失敗の理由・止める手順）は `Sources/MonitorKit/Sites/DevServerRules.swift`、子プロセスは `DevServerProcess.swift`
        （テストあり。sh で孫を持つ子を立て、グループごと止まる・SIGTERM を無視しても SIGKILL で止まる・すぐの終了を知らせる・先頭が終わった後も SIGTERM を無視する孫を止め切る・出力が順に届く、を確かめる）、
        持ち手は `Sources/ClaudeDeck/Chat/Model/DevServerStore.swift`。初めて開いた時の見る元は、開発サーバーが動いていればそれ、書き出しが無く起動できるなら開発サーバー、それ以外は書き出し。
    - WKWebView は Cookie 等を残さない（`nonPersistent`）。外部のサイトへの遷移はそのまま許し、`file:`・`javascript:`・ページそのものの `data:` 等へは遷移しない
      （新しいウィンドウで開くリンクは同じ枠で開く）。
  - **一覧のサムネイル**: 「ディレクトリ」の各行の右に LP のサムネイル。書き出しのトップを画面に出さないウィンドウの WKWebView（1280×800）で撮って縮小し、
    `~/Library/Caches/claude-deck/site-thumbs/`（0700 / 0600。名前はサイトと `out/index.html` の更新時刻から）に置く。更新時刻が変わった時だけ撮り直し、
    同じサイトの古いものは消す。撮るのは 1 つずつ。書き出しが無ければ出さない。撮れなかった書き出しは（更新時刻ごとに）撮り直さず、詳細の「再読み込み」からは間引き（30 秒）と
    その記録を飛ばして撮り直す。設定からプロジェクトを消すと、そのサムネイル（画面の分と保存した画像）を片付ける。
  - 中央の出し分けは `ChatModel.center`（ルームを選べば会話、ディレクトリを選べば詳細、「リンク」の固定行を押せば横断のリンク一覧 `.links`）。詳細・リンク一覧を出している間も選択中のルームは残し、
    ステージパネルはそのルーム（無ければ空のプレースホルダー）のまま。会話を出していない間は既読にしない。設定から外されたプロジェクトの詳細は案内に替える。
- 各行: ドット絵キャラのアイコン・名前・ブランチ・状態ラベル + 直近の一行・時刻・未読数
  （開いていない間に届いた応答の数）。アプリの外で動いているセッションには「外部」タグ（伝言・引き継ぎは下記「外部セッション」）。
  - キャラはステージの 3D と同じ絵と配色（`packages/DeckCore/Sources/DeckCore/Pixel/PixelCharacter.swift`。マークの大きさ・位置・跳ね幅だけは小さいアイコンで読めるよう変えている）。稼働中=立ち・緑で跳ねる / 権限待ち=立ち・amber で「!」が点滅 / 入力待ち=立ち・青で「?」が点滅 / エラー=うずくまり・赤 / 待機=座り・灰で Zz が浮き沈み / 終了=座り・暗い灰 / 状態不明=座り・灰（マーク無し）
  - SwiftUI の Canvas で整数ポイントのマスを補間なしに塗る。動く状態だけ、画面に出ている間だけ `TimelineView(.periodic)` で 4fps で描き直す（起点を固定時刻にして全行が同じ境目でコマを切り替える）。「動きを減らす」設定では止める。行と見出しでは状態名を隣の文字が読むので、アイコン自体は読み上げない
  - 会話の見出しのアイコンも同じキャラ（iPhone アプリも同じ絵）。「+」のプロジェクト一覧はセッションを持たないので、ディレクトリと同じプロジェクトの印
- 上部: 検索（名前・ブランチ・タイトル・直近の一行。空白区切りで AND）と **「+」**（プロジェクト一覧から選んで `claude` を起動 = 新しいルーム。
  一覧の追加・削除・取り込みもここ）。右クリック → 「別ウィンドウで開く」（下の「別ウィンドウ」）・「ルームを閉じる（claude を終了）」・「Finder で表示」。
- 検索欄の下: 監視の開始中はその旨、フックの受け口（:8766）を開けない時（別のプロセスが使用中）はフックが届かない旨を出す。
- 上限の残り% は出さない（statusLine はターミナル起動の Claude Code でしか更新されず、VS Code 拡張だけ動いていると古い値が残るため）。
  上限到達の強制終了（`LimitGuard` / `LimitWatch`）は従来どおり `MonitorStore.usage`（取得 10 分以内の値だけ）を使う。

### ステージパネル（右 360px）

選択中のルームのセッションを、アプリが SceneKit で描くステージ（3D）と監視のデータで見せる。
文言・判定は `Sources/MonitorKit/Stage/StageLogic.swift`、ステージの組み立ては `StageBlueprint.swift`・`StageScene.swift`、
SceneKit への起こしは `StageSceneRig.swift`（いずれも MonitorKit・テストあり）、画面は `Sources/ClaudeDeck/Stage/`。

- **見出し**: 「ステージ / プレビュー」の切り替え（アイコンだけ・名前はホバーで出す。UserDefaults `stagePanel.view`）・畳むボタン。ステージは 3D 表示だけ（以前の 2D / 3D の保存値 `stagePanel.mode` はパネル表示時に消す）。
- **プレビュー**: 選択中のルームの cwd から設定のプロジェクトを引き（`ProjectMatcher`）、その LP を会話の横で見る（`StagePreviewPanel.swift`）。
  開発サーバーが動いていてアドレスが分かればそれ、無ければ書き出し（`out/`）、どちらも無ければ案内と「開発サーバーを起動」「サイトの欄を開く」のボタン。
  開発サーバーの状態・起動 / 停止・出力、表示幅の切り替え・再読み込み・ブラウザで開くはサイトの欄と同じ部品（`SitePreviewParts.swift`）で、
  パネルの幅（360px）と残りの高さに収まるよう縮めて出す。ルームが無い・プロジェクトに入っていない時はその旨を出す。
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
  ウィンドウ幅が 831px + 一覧の幅（既定の 312px なら 1143px）未満なら自動で畳む（左端の切り替えバー 48px・境界 3 本・会話の最小 420px・パネル 360px の分。一覧を広げられる上限と揃えて余裕は足さない。`StageLogic.autoCollapseWidth(listWidth:)`）。狭いまま開いた時はそれに従い（パネルは最小 240px まで縮む）、広げれば通常に戻る。

### 会話（中央）

- 見出し: アイコン・名前・ブランチ・状態バッジ・「VS Code」「GitHub」「リンク」「Xcode」「閉じる」「別ウィンドウで開く」。表示の切替は無く、どのルームも常にチャット。
  「別ウィンドウで開く」（`macwindow.badge.plus`）はメインの見出しにだけ出し、別ウィンドウの見出しには出さない。優先度は「GitHub」と同じ段でその直前に「…」へ回る。
  見出しのボタンはアイコンだけで、ホバーで名前と開く先を出す。「VS Code」は常に出す。
  「Xcode」「閉じる」はプロジェクト配下（浅い範囲・`ios/` 等のサブディレクトリを含む）に `.xcworkspace` / `.xcodeproj` があるルームだけ出す（`XcodeFinder`。`.xcworkspace` 優先・最も浅い階層。
  SPM だけのもの（claude-deck 自身等）では出さない）。「Xcode」は `NSWorkspace.open` で Xcode の GUI を開く（実行＝Cmd+R はユーザー操作。ワンクリックでのシミュレータ実行（`xcodebuild` / `simctl`）は将来）。「閉じる」は確認ダイアログの後、
  AppleScript をアプリから `osascript` で実行し、Xcode からそのワークスペースだけを閉じる
  （Xcode は終了しない・起動していなければ立ち上げない。パスは argv で渡す）。ホスト中のルームでも使える。
  結果（開きました / 閉じるよう伝えました / Xcode では開いていません / Xcode は起動していません / エラー）をボタンの左に数秒出す。
  初回は macOS が「claude-deck が Xcode を操作する」許可（オートメーション）を求める。拒否するとエラー（-1743）になる。
  「GitHub」は、ルームの cwd が設定のプロジェクトの path と一致するか配下にあり（いちばん深いものを採る。`/a/b` は `/a/bc` に当たらない）、
  そのプロジェクトに GitHub の紐づけがある時だけ出す。Project 番号とリポジトリの両方があればメニューで選び、片方ならそのまま既定のブラウザで開く。
  ボードは owner の種類を `https://api.github.com/users/<owner>` の `type` で引いて `users/` か `orgs/` の URL にする
  （認証なし・3 秒で諦める・owner ごとにアプリが動いている間だけ覚える・取れなければ `users/`）。判定と URL は `Sources/MonitorKit/Projects/GitHubLinks.swift`。
  「リンク」は、同じ照合で紐づいたプロジェクトに `links`（LP 等の名前と URL・種類）がある時だけ「GitHub」の隣に出す。1 つならそのまま既定のブラウザで開き、
  複数なら名前のメニュー（種類のアイコン付き。種類が 2 つ以上なら種類ごとに `Section` で区切る。`ProjectLinks.grouped`・`ProjectLinkMenuItems`。会話と詳細の見出しで同じ部品）で選ぶ。
  開く直前にも URL を確かめ、http / https で host のあるものだけ開く（`javascript:`・`file:`・`user:pass@` 付きは開かず理由を出す）。
  設定で不正なリンク（名前が空・URL の形）はボタンに含めず、同じ名前（空白を除く）が重なれば先のものだけ出す。設定の変更はすぐ映る。判定は `Sources/MonitorKit/Projects/ProjectLinks.swift`（テストあり）。
  種類（`ProjectLinkKind`）のアイコンは 請求 `creditcard` / ダッシュボード `gauge` / ストア `storefront` / ドキュメント `book` / その他 `link`。リンクは iPhone 側（DeckCore / Remote API）には出していない。
  `pinned` のリンクは種類のアイコンの単独ボタンとして「リンク」の左に出す（設定の順に最大 3 つ。`ProjectLinks.pinned`・`ProjectLinks.pinLimit`。4 つ目以降はメニューの中だけ。ホバーで名前と URL。`id` は `pin:<url>`）。
  入りきらない時は「リンク」と同じ優先度の段でピンから先に（同じ段の中では `HeaderAction.subpriority` が低いものから・ピン同士は右から）「…」へ回り、次に「リンク」が回る（`HeaderOverflow` の `subpriorities`。テストあり）。
  確認の日を過ぎてまだ開いていないピンはアイコンの右上に小さな黄色の点（`HeaderButtonLabel.dot`）。どの経路で開いても `EditorLauncher.openLink` を通り、開けた時だけ最終確認日を記録する（下の「設定（settings.json）」の `link-visits.json`）。
  ルームを移っても各ルームの PTY と claude は生きたまま。claude が終了したルームも、最後に分かった sessionId で会話を出し続ける。
  選択中のルームが一覧から消えても別のルームへ自動では移らない（自動で選ぶのは未選択の時だけ）。
- 端末ビュー（`ClaudeTerminalView`）は画面に載せない。PTY の受信は main キューで端末バッファに流れ、状態・権限プロンプト・選択待ち・上限表示は
  0.3 秒ごとのタイマーと受信時にバッファ末尾の `rows` 行を読むので、ビュー階層に無くても動く。桁数は起動前に広げた約 160 桁のまま固定（下記「選択肢カード」）。
- 会話はアプリ内の `TranscriptStore` から組み立てる。ルームを開いた時に、直近に開いた 4 ルームを対象に追記の購読を張り直してから
  `fetchTranscript` で全件、以降は追記を id で重複除去して足す（それより前に開いたルームの会話は手放し、開き直した時に取り直す。メインと別ウィンドウで出している会話は手放さない）。
  監視を始め直した（`connectionEpoch` の増加）後は**全件を取り直して置き換える**。最初の発話前でログが無い時は空のまま追記を待つ。
- 表示: 会話は欄の中央の列（最大 760pt・`ChatTheme.columnWidth`。欄が広ければ左右に余白、狭ければ欄いっぱい）に並べる。自分の発話は列の右に寄せた青い吹き出し（14pt）。
  Claude の応答は吹き出しの枠・背景を付けず（上下の発話との距離が変わらないよう、吹き出しだった頃の内側の余白 上下 10pt は残す）、列いっぱいの左揃えの本文として発話より 2pt 大きい 16pt で描く（行間も広げる）。見出し・リスト・表・引用・インラインのコード・コードブロックも同じ比率で大きくする
  （大きさは `ChatTypeScale`（MonitorKit・テストあり）の `.reply` を Environment の `chatTypeScale` で `MarkdownView` に渡す。既定の `.standard` は今までの 14pt / 等幅 12pt）。
  返答に添えた画像・ツールの行・権限カード・選択肢カードも同じ列の左端にそろえる。Claude の応答は Markdown を描く（見出し・表・箇条書き / 番号付きリスト（入れ子）・引用・区切り線・コードブロック、インラインの太字・斜体・コード・リンク）。リンクは http / https だけ開き、`file://` やカスタムスキームは開かない（会話ビュー全体で判定は `ChatMarkdown.isOpenableLink`）。コードブロック内のタブはそのまま保つ。コードブロックの右上にコピーのボタン（横スクロールしても右上に留まる。押すと中身をクリップボードに入れ、1.5 秒チェックマークにする）。表は寄せ指定に従い、列幅は中身に合わせて長いセルは折り返し、本文の列より広い時だけ横スクロール。解析は自前（`ChatMarkdown`・外部ライブラリなし）で本文ごとにキャッシュし、描画は `Chat/Views/MarkdownView.swift`。自分の発話と伝言はインライン装飾のみ。
  ツール呼び出しは直前の発話の下に「ツール N件 ▸」の 1 行に畳み、開くとツール名と対象を並べる。実行中のものは緑で強調。
  新着で末尾へ自動スクロールし、上に遡っている間は止める（macOS 15 以降）。
- 作業中に送った指示は Claude Code 側でキューに入り、ログに「ユーザーの発話」として残らないため吹き出しには出ない（応答には反映される）。

### 別ウィンドウ

- ルーム一覧の行の右クリック「別ウィンドウで開く」か、会話の見出しのボタンで、そのルームの会話だけのウィンドウを開く。同じルームのウィンドウが既にあれば前に出す（二重に開かない）。
  メインでディレクトリの詳細・リンク一覧・他のルームを見ている間も、別ウィンドウの会話は更新され続ける。
- 中身は中央と同じ `ConversationView`（見出し・外部セッションのバナー・吹き出し・権限カード・選択肢カード・入力欄）。送信・伝言・回答・引き継ぎは
  メインと同じ部品（`ChatOutbox` / `ChatRelay` / `PromptResponder` / `ChatHandover`）を通るので、選択待ちの間は送らない・押した時のカードと今の画面が違えば送らない等の守りもそのまま効く。
- **下書きと添付はルームごとに 1 つを共有する**（`ChatOutbox.drafts` / `attachments` はルームの id で引く）。メインと別ウィンドウで同じルームを出していれば、
  片方で書いた文面・添えた添付はもう片方にもそのまま映り、送れば両方から消える（変換中の文字は確定するまで書いている側にだけある。`ComposerSync`）。
- 会話の取得と既読: メインで選んでいるルームに加えて、別ウィンドウのルームも開いた時に取得・購読し（`TranscriptCache.ensure`）、新着を受けるたびに既読にする
  （`ChatModel.markShownSeen`。メインは会話を出している間だけ、別ウィンドウは開いている間）。別ウィンドウとメインで選んでいるルームの会話は「直近 4 ルーム」の数に関わらず手放さない
  （`TranscriptRetention`）。監視を始め直した時はメインと別ウィンドウの両方を取り直す（`ShownSessions`）。
- タイトルはルーム名（変われば追従）。別ウィンドウ同士は同じ `tabbingIdentifier` で、「ウインドウ」メニューの「すべてのウインドウを結合」や
  システム設定の「タブで開く」で macOS のタブにまとめられる（メインは `tabbingMode = .disallowed` で混ぜない）。⌘W は別ウィンドウ（タブ。吹き出しの別ウィンドウも）だけを閉じる。
  テーマ（ナイト / ライト）はメインと同じく `AppearanceSettings` に追従する。
- 警告（送れなかった理由など）は出た時に前にあったウィンドウに出す（`ChatAlerts.target`。そのウィンドウが閉じられていればメインに出す）。
- ルームが閉じられた・一覧から消えた時はウィンドウを勝手に閉じず「このルームは閉じられました。」と出す（監視の開始中はその旨）。外部セッションを引き継いだ時は、
  ウィンドウは引き継いだ先のルームに付け替える（`DetachedRooms.retarget`。引き継ぎ先が既に別ウィンドウにあれば元のウィンドウを閉じる）。
- 別ウィンドウを閉じてもセッションとアプリは止めない。メインのウィンドウを閉じる時の終了の確認は別ウィンドウが残っていても今までどおり通り、アプリの終了で一緒に閉じる。
  終了の保留中に隠したメインしか残っていない時に最後の別ウィンドウを閉じると、アプリが終わらないようメインを出し直す（Dock から開き直した時も同じ）。
  次の起動で別ウィンドウは復元しない。
- 開いているルームの集合と付け替え・取得と既読の対象の決め方は `Sources/MonitorKit/Chat/DetachedRooms.swift`（テストあり）、
  ウィンドウは `Sources/ClaudeDeck/App/RoomWindows.swift`、中身は `Sources/ClaudeDeck/Chat/Views/Conversation/RoomWindowView.swift`。
  作り方・置き方・最後の 1 枚を閉じる時の扱いは吹き出しの別ウィンドウと共通（`Sources/ClaudeDeck/App/DetachedWindow.swift`）。

### 吹き出しの別ウィンドウ

- Claude の返答の吹き出しを 1 つだけ別ウィンドウに出し、横に置いたまま会話を続けられる。開くのは吹き出しの右クリック「別ウィンドウで開く」か、
  吹き出しにカーソルを乗せた間だけ右上の脇に出る小さなボタン（`macwindow.badge.plus`。ホバーで名前を出すのは見出しと同じ `HeaderTooltipModifier`。場所は常に取っておき本文の幅を揺らさない）。
  メインの会話からもルームの別ウィンドウの会話からも開ける。自分の発話・伝言・ツールの行・カード・本文の無い吹き出しは開けない。
- 中身は開いた時点の本文の写し（`BubbleSnapshot`）。ルームが閉じても会話が流れても見続けられ、後から開き直しても写しは最初のまま。
  本文は会話と同じ `MarkdownView` で縦にスクロールして読み、文字は選択できる。リンクは会話と同じく http / https だけ開く。画像は出さない。
  上の帯にルーム名と発言の時刻、右に「全文をコピー」（Markdown の原文をクリップボードへ。押した直後は印がチェックになる）。
- タイトルは「ルーム名 · 時刻」（今日なら `HH:mm`、それ以外は `M/d HH:mm`）。
- 同じ吹き出し（sessionId と transcript の項目の id の組 `BubbleKey`）は 2 枚開かず、今のウィンドウを前に出す。違う吹き出しはいくつでも開ける。
- 吹き出しのウィンドウ同士は同じ `tabbingIdentifier`（ルームの別ウィンドウとは別）で macOS のタブにまとめられる。テーマ（ナイト / ライト）に追従し、⌘W で閉じる。
- 寿命はルームの別ウィンドウと同じ（閉じてもアプリ・セッションは止めない・メインを閉じる時の終了の確認はそのまま・アプリの終了で閉じる・次の起動で復元しない）。
- 開いている吹き出しの集合と開ける吹き出しの判定は `Sources/MonitorKit/Chat/DetachedBubbles.swift`（テストあり）、
  ウィンドウは `Sources/ClaudeDeck/App/BubbleWindows.swift`、中身は `Sources/ClaudeDeck/Chat/Views/Conversation/BubbleWindowView.swift`。

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
- **入力欄の上に重なるダイアログ**: TUI v2.1.288 の fullscreen では申し出（「Teach auto mode about your environment?」等）のダイアログが入力欄の真上に重なって出る
  （入力欄の ❯ と罫線は下に残る）。入力欄の上の罫線の直上（空行を除き 3 行以内）に案内行があれば、その上の罫線までを重ね表示のメニューとして送信を止める
  （会話中の案内行風の文字を拾わないよう、罫線に接し、上端の罫線があり、その間に `⏺` / `✻` の行が無い時だけ）。案内行は行頭の文言か、「·」で区切った各部分が
  キーの案内（`↑/↓ to navigate` 等）で `Enter to …` と `Esc to …` を含む行。
- **セッションファイルの待ち**: 監視と同じ `~/.claude/sessions/<pid>.json` が `status:"waiting"` で `waitingFor` がダイアログ系（`dialog open`・`sandbox request`・
  `goal proposal`。v2.1.288 のバイナリで確認）の間も送らず、Esc だけのカード（「ダイアログ」）を出す（`SessionWaiting`）。ただし `waitingFor` は閉じた後も古いまま
  残りうるので、通常の空の入力欄（空で、最後の `⏺` / `✻` の行との間に罫線が無い。`InputBox.isPlainEmpty`）が見えている時は、`statusUpdatedAt` が端末の最後の出力より後
  （1 秒の幅）の時だけ信じる。
- 判定は**貼り付けの前**と、**Enter の直前**の 2 回。貼り付けた後に止めた場合は本文が Claude Code の入力欄に残る
  （安全に消すキーが無い。Esc はメニューの取り消しになる）ので、その旨を知らせ、チャット欄の下書きには戻さない（送り直しで二重にしない）。
  取りやめが起きたセッションでは、次の送信の前に端末の入力欄（罫線の間の ❯ 行）が空かを画面から確かめ、残っていれば送らずに
  「端末側の入力欄に前回の本文が残っているようです」と知らせる（前回の本文にくっつけないため）。警告は 1 回だけで、
  もう一度送ると送れる（未知の薄字表示を本文と誤認しても、チャットから送れないまま固まらないため）。
  空欄の時に薄字で出る例文（`Try "…"`）は空とみなす。
- **貼り付けが入ったかの確認**: 貼り付けの後は端末の入力欄が空でない・貼る前から変わったことを確かめてから Enter を送る（長文は `[Pasted text #1 …]` に畳まれるので
  一致では見ない。`PasteCheck`）。約 1 秒（長文ほど延ばし最大 4 秒）待っても入らなければ Enter を送らず、本文と添付を入力欄に戻して「端末の入力欄に入りませんでした」と出す
  （入力欄が読めない時と、本文が例文と同じ `Try "…"` の形の 1 行の時は従来どおり送る）。この後は、遅れて入った本文と戻した本文が二重にならないよう、
  入力欄が貼る前と同じか空と確かめられるまで何度でも送らない（`LeftoverCheck`。上の「1 回だけの警告」とは別）。
- 判定は SwiftTerm の表示位置 `yDisp` ではなく、バッファ末尾の `rows` 行（= 実画面）を読む。
- 本文からは改行・タブ以外の制御文字（C0・DEL・C1）を落としてから送る（ESC や Ctrl-C が端末操作として効かないように）。
- 書きかけはルームごとに `ChatOutbox.drafts` に持つ。日本語の変換中（marked text）は確定前の文字が下書きに入らないため、再描画で入力欄へ書き戻すのは
  送信後の空など本当の外部変更の時だけ（`Sources/MonitorKit/Chat/ComposerSync.swift`・テストあり）。変換中は送信ボタンも効かない。
  空欄の案内（プレースホルダー）は下書きではなく端末ビュー（`SubmitTextView`）が表示内容で出し分けて自前で描くので、変換中も確定前の文字に重ならず、
  取り消して空に戻れば出直す（`Sources/MonitorKit/Chat/ComposerPlaceholder.swift`・テストあり）。

#### 添付（画像・ファイル）

- 入れ方: 入力欄左のクリップ（NSOpenPanel・複数選択可）、**⌘V**（クリップボードにファイル URL があればそのファイル、文字列が無く画像（PNG / JPEG / HEIC / TIFF 等）だけならその画像。
  文字列を含むコピーは従来どおり文字として貼る。⌥⇧⌘V 等の pasteAsPlainText も同じ）、入力欄へのドラッグ＆ドロップ（ファイル・画像のデータ表現。ファイルプロミスは対象外）。入力欄の上にチップ（画像はサムネイル、
  それ以外は名前とアイコン、× で外す）。下書きと同じくルームごとに保持し（`ChatOutbox.attachments`）、1 通 20 個まで。本文が空でも添付だけで送れる。
  ルームを閉じた時・外部ルームが一覧から消えた時（監視の開始前・引き継ぎ中を除く）は、送る前の添付・サムネイル・一時ファイルを片付ける
  （引き継ぎで再開したルームへは、取り込み中のものも含めて移す）。
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
  クリックで拡大表示（シート・Esc で閉じる）。画像は表示された時にだけ `MonitorStore.imageSource`（行の位置を覚えて読み直す）で取り出し、
  縮小（長辺 480px）してから `NSCache`（300 枚・128MB）に持つ。同じ画像の同時の読み込みは 1 回にまとめる。VS Code 等から送った画像付きの発話も同じく出る。
  アプリから画像を添えて送った発話は、transcript に載るまでの間も端末へ画像として貼った分（手元の一時ファイル）を薄い吹き出しで出す
  （`ChatOutbox.sentImages`）。パスとして本文に回った画像（貼り付けモードでない端末・貼れない形のパス）だけなら記録に画像が付かないので出さない。
  送信後の本人の発話で、画像の枚数と本文（`[Image #N]`・`[画像]` の印と空白を除いたもの）が一致するものが transcript に載ったら消す
  （1 件の発話は 1 通にだけ対応・時計のずれ 5 秒まで許す。ターミナルから直接送った別の画像付き発話では消さない）。
  Enter まで届かなかった送信は出さず、3 分経っても載らなければ（キューの取り下げ・捨てられた Enter 等）下げる。
  画面は `Chat/Views/ChatImageViews.swift`、突き合わせは `packages/DeckCore/Sources/DeckCore/Chat/ChatImages.swift`（テストあり）。
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
- 入力欄の上に重なったメニュー（上の「入力欄の上に重なるダイアログ」）はその範囲だけを読み、番号付きの選択肢が読めれば通常のカードにする。
- 中身を読み取れないメニュー（`/auto-mode-setup` のウィザード等）は、その旨と「キャンセル（Esc）」だけのカードを出す。押した時のカードと今の画面が同じ「読めないメニュー」
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
     外部ルームの書きかけと添付は新しいルームへ移す（`ChatOutbox.move`）。取り込み中だった添付もそのまま新しいルームの取り込み中として扱い、
     後から元のルーム宛てに届く取り込みの結果は `RoomRedirects` で新しいルームへ付け替える（全部届いたら表は空になる）。
     引き継ぎが失敗・取りやめになって新しいルームが無い時は従来どおり、外部ルームが一覧から消えた時点で片付ける。
  - 上限到達中（`LimitWatch.isLimitReached`）は引き継がない（確認ダイアログの間・終了待ちの間に到達した場合も、止める前／再開前に判定し直す）。
  - **制約: npm 版（node で動く）claude は引き継げない**。実体が `node` で argv[0] も `node` になり、プロセスが claude だと確かめられないため
    安全側に倒して中止する（ネイティブ版 `~/.local/share/claude/versions/<版>` は引き継げる）。

### 終了と次の起動（前回のセッションの再開）

アプリを終了するとホスト中の claude は PTY ごと閉じて止まる。次の起動で同じ会話を自動で続けられるよう、記録して再開する。
判定と記録の読み書きは `Sources/MonitorKit/Chat/SessionRestore.swift`・上限の記録は `Sources/MonitorKit/Limit/LimitState.swift`（どちらもテストあり）、
つなぎは `Chat/Model/SessionRestorer.swift`・`App/QuitCoordinator.swift`・`App/LimitWatch.swift`。

- **記録**: 動いているホスト中のセッション（名前・cwd・sessionId・最後の状態・書きかけ）を `ChatModel.hosted` そのものから組み立て
  （一覧 `rooms` は次の周回まで古いので使わない）、見送り中の分と合わせて
  `~/Library/Application Support/claude-deck/hosted-sessions.json`（`CLAUDE_DECK_HOSTED_SESSIONS` で差し替え）に 0600・置き換えで書く。
  ルームの起動・閉じる時・アプリの終了時（SIGTERM / SIGINT を含む）と 3 秒ごと（中身が変わった時だけ）に書くので、強制終了・クラッシュでも直前の分が残る。
  `/exit` で終了した claude とまだ sessionId の分からないルームは記録しない。壊れた・知らない版のファイルは空とみなして書き直す。
- **二重起動**: 記録の隣の `hosted-sessions.json.lock` を起動中ずっと flock で持つ（exec で閉じるので子の claude には残らない）。
  取れない時（別の claude-deck が動いている）は再開も記録の書き込みもせず、その旨を帯に出す。
- **起動時の再開**（設定「起動と終了」の「起動時に前回のセッションを再開する」。既定はオン・UserDefaults）: 監視が始まって残量を読むまで待ってから（最大 10 秒）、
  記録したものを同じ cwd で `claude --resume=<sessionId>` で起動する（「アプリに引き継ぐ」と同じ `launchClaude(in:resumeSessionId:)`。UUID 形式のみ・API キー除去は維持）。
  - 同じ sessionId が別の claude で動いていれば起動せず（`SessionHandover.liveDuplicate`。前回の claude がまだ終了の途中のこともある）、記録は見送りに残す。
    sessionId の形が想定外・フォルダが無い・同じ会話を既にホストしている時は起動しない。
  - 上限到達中（`LimitWatch.isLimitReached`）は起動せず見送りに残す。
  - **再開の直後に落ちた時**: 自動で再開した時刻を記録に `restoredAt` として持ち、正常に終わる時（`applicationWillTerminate`）に外す。
    次の起動で印が残っていて 2 分以内なら、再開が原因で落ちた疑いがあるので自動では再開せず見送りに回す。
  - 見送った分は一覧の上の帯に「再開を見送ったセッション N 件（上限 / 再開の直後に落ちた / 同じ会話が動いている）［再開する］［破棄］」で出し、記録にも残し続ける
    （次の起動でもう一度判定する）。［再開する］はまだ上限中なら何もしない。
  - 再開した件数（続きを頼んだ件数・見送り）を一覧の上の帯に出す（× で閉じる）。選択は未選択の時だけ移す。書きかけは入力欄に戻す。
- **上限の記録**: `LimitWatch` は起動時から残量を見張り、到達の解ける時刻（と理由）を `limit-state.json`（`CLAUDE_DECK_LIMIT_STATE` で差し替え・0600・置き換え）に書き、
  解けたら消す。起動時はこれを読んで到達を持ち越すので、usage.json が古い（セッションが止まっていて statusLine が書いていない）間も、リセット時刻までは再開しない。
  新しい残量が 100% 未満を示せば解除する。再開後に上限で止められたセッションの記録は見送りの一覧へ移し、続けて止まった分の知らせは 1 回の確認にまとめる。
- **続きを頼む**（「作業中だったものに続きを頼む」。既定はオン）: 記録した状態が稼働中だったものだけ、再開後に
  「前回はアプリの終了で作業の途中で止まりました。続きを進めてください。」を通常の送信（`HostedSession.send`）で送る。
  起動直後は trust 確認・メニュー・入力欄の準備があるので、「動いている・選択待ちでない・送信中でない・端末の入力欄が空で見えている」が 2 秒続いてから送る。
  選択待ち等で送れなければまた落ち着くのを待ち、2 分経っても送れなければ入力欄の下書きに入れる（本文を貼る前にやめた時も下書きに戻す）。
  利用者がそのルームから送った時（入力欄・iPhone）と、端末が稼働中になった時（伝言などで動き出した）は頼むのをやめる。
  終了の確認ダイアログの表示中・終了の保留中は送らない。
  権限待ち・入力待ち・待機だったものは起動だけ。頼む前にアプリが止まったら、次の起動でも頼めるよう稼働中として記録する。
- **終了時の確認**: ⌘Q・メインウィンドウを閉じる（最後のウィンドウを閉じると終了するため、閉じる前に同じ確認を通す。ルームの別ウィンドウが残っていても同じ。取り消したらウィンドウは残す）時に、
  稼働中・権限待ちのホスト中ルームがあれば「稼働中 N 件（名前…）・権限待ち M 件（名前…）。終了すると中断し、次の起動時に再開します」と
  「作業が終わったら終了」の扱い（権限待ち・入力待ちは待たずに中断する）を出し、［キャンセル］（既定・Return）［作業が終わったら終了］［終了する］を選ばせる。
  待機・入力待ち（応答の後の idle_prompt）と終了済みだけなら確認しない。
  「作業が終わったら終了」は `.terminateLater` で保留し、稼働中のルームが無い状態が 3 秒続いたら終了する（ツールの合間の一瞬では終えない）。
  待っている間は一覧の上に帯（［取り消す］）を出す。待っている間にもう一度 ⌘Q を押すとすぐ終える。ウィンドウの閉じるボタンでは終えず、待ちを続けたままウィンドウを隠す（Dock から出し直せる）。
  保留中は run loop がモーダルの mode で回るので、記録と待ちのタイマーは common の mode に載せている。
- **SIGTERM / SIGINT での終了**（`MonitorBridge` のハンドラ → `QuitCoordinator.terminateBySignal`）は確認を出さず、記録だけ書き切って必ず終える
  （保留中なら `NSApp.reply(toApplicationShouldTerminate: true)`、確認ダイアログの表示中なら `NSApp.abortModal()` してから終了へ進める）。
- **ログアウト・再起動・シャットダウン**（quit の Apple Event に `kAEQuitReason` が付く）でも確認を出さず、記録だけ書き切って終える。

### 設定（settings.json）

管理対象のプロジェクトと GitHub の紐づけは **`~/Library/Application Support/claude-deck/settings.json` だけ**に持つ（アプリにもリポジトリにも埋め込まない）。
試験用に別のファイルを使うときは環境変数 `CLAUDE_DECK_SETTINGS`（JSON のパス）で差し替える。場所は `claude-deck --print-settings-path` で GUI を出さずに確かめられる。

```json
{ "version": 1,
  "projects": [ { "id": "<UUID>", "name": "mirio", "path": "/abs/path", "status": "active", "note": "…",
                  "github": { "owner": "ShinjoSato", "repo": "ailovei", "projectNumber": 4 },
                  "links": [ { "name": "LP", "url": "https://example.com/lp" },
                             { "name": "Stripe", "url": "https://dashboard.stripe.com/invoices", "kind": "billing",
                               "pinned": true, "note": "月初に請求を見る", "reminderDay": 1 },
                             { "name": "Figma", "url": "https://www.figma.com/file/…" } ],
                  "site": { "path": "site" },
                  "icon": "iphone", "color": "blue" } ],
  "boards": [ { "name": "overview", "owner": "ShinjoSato", "number": 5 } ] }
```

- `status` は `active` / `paused` / `archived`。`github` は省略でき、その中の `repo` / `projectNumber` もどちらか片方だけでよい。
  `links` は会話の見出しの「リンク」から開くもの（LP・デザイン・請求ページ等）で、省略できる（空ならアプリも書かない）。並びは配列の順。
  `url` は http / https で host のあるものだけ（それ以外や `user:pass@` 付きは警告として読み込み、ボタンには出さない）。`name` は同じプロジェクトの中で重ねない（重なれば先のものだけボタンに出す）。
  `kind` は種類で `billing`（請求）/ `dashboard`（ダッシュボード）/ `store`（ストア）/ `docs`（ドキュメント）/ `other`（その他）。省略できる（無ければその他として扱い、種類に触れずに保存しても書き足さない）。知らない値はその他として読み、そのリンクの種類を選び直して保存すると `other` に書き換わる。
  `pinned`（true なら会話と詳細の見出しに単独のボタンで出す。設定の順に 3 つまで）・`note`（1 行のメモ）・`reminderDay`（1〜31。毎月この日に確認する）はどれも省略でき、
  既定の値（false・空・無し）はアプリも書かない。`reminderDay` が 1〜31 の整数でなければ警告として読み、次に保存した時に落とす。
  リンクを最後に開いた時刻は settings.json には書かず、`~/Library/Application Support/claude-deck/link-visits.json`
  （`CLAUDE_DECK_LINK_VISITS` で差し替え・0600・置き換えで書く。`{"version":1,"visits":{"<プロジェクト id>|<正規化した URL>": <epoch ミリ秒>}}`）に持つ。
  アプリから開いた時だけ記録し、URL を編集した行は新しい URL に引き継ぎ、設定から消えたリンクの分は起動時に片付ける（壊れた・知らない版のファイルは空とみなす）。
  「毎月 N 日に確認」は、今月の N 日（N が月の日数を超える月は末日）以降にまだ開いていなければ「確認」の印を出す（前月の N 日以降に一度も開いていなければ、今月の N 日の前でも出す）。
  印はアプリの中だけで、通知はしない。判定は `Sources/MonitorKit/Projects/LinkReminder.swift`、記録は `LinkVisits.swift`（どちらもテストあり）。
  種類はアイコンで見分け、「リンク」のメニューを種類ごとに区切る。ディレクトリの詳細の「リンク」の節から追加・編集・並べ替え・削除ができ（設定画面のプロジェクトタブでも同じ）、
  「+ 追加」はクリップボードの http / https のアドレスを初期値にして種類と名前（host の主要部分）を提案する。クエリの無いアドレスは加えてページの `<title>` を 3 秒以内に取りに行き（一度きりのログイン用リンク等を使い切らないため、クエリ付きは名前欄の横のボタンで頼んだ時だけ）、取れれば名前を触っていない時だけ置き換える。
  `links` の形が崩れている（配列でない・要素に `name` か `url` の文字列が無い）ファイルは読めない扱いになる。
  **リンクを使い始めたら、`links` を知らない前のビルドで設定を保存しない**（`links` を落として書くため）。
  `site` はディレクトリの詳細の「サイト」でプレビューする LP の場所で、省略できる（省略なら自動で探す。空ならアプリも書かない）。
  `path` はプロジェクトからの相対パス（`.` はプロジェクト直下。静的書き出しはその下の `out/`）。絶対パス・`~`・`..` を含むものは警告として読み込み、使わない
  （シンボリックリンクでプロジェクトの外を指すものも使わない）。`site` の形が崩れている（オブジェクトでない・`path` の文字列が無い）時は、その `site` だけを無視して警告を出す（ファイル全体は読める。次に保存すると `site` は書かれない）。
  **サイトを指定したら、`site` を知らない前のビルドで設定を保存しない**（`site` を落として書くため）。
  `icon` / `color` はディレクトリ一覧・詳細の見出し・「+」の一覧に出る印で、どちらも省略できる（無ければアプリも書かない）。
  `icon` は SF Symbol の名前（無ければ `folder`。この OS に無い名前は読めて値も残るが、表示は `folder` に落ちる。空は警告）。
  `color` は `red` / `orange` / `yellow` / `green` / `teal` / `blue` / `indigo` / `purple` / `pink` / `brown` / `gray` のどれか（無ければ名前から決める。知らない値は警告として読み込み、値は残したまま名前から決めた色で出す）。
  設定画面のプロジェクトタブの「アイコンと色」か、ディレクトリ一覧の行の右クリック「アイコンと色を変更…」から選ぶ（「自動」「既定」でキーを消す）。
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
- 文字欄（名前・メモ・GitHub の欄・リンクの名前と URL）は 0.5 秒まとめて保存する。⏎・フォーカスが外れた時・設定画面を閉じた時・アプリの終了時はすぐ書く。
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
  「アイコンと色」の節で今の印のプレビューと、色のスウォッチ（11 色 + 「自動」）・アイコンのグリッド（`ProjectBadge.symbolChoices` の 40 個。既定の `folder` を押すか
  「既定に戻す」で `icon` を消す）から選ぶと即時に保存する（`ProjectBadgeEditor`）。
  「リンク」の節で LP 等のリンクを追加（名前と URL）・編集・削除・「∧ / ∨」で並べ替え。URL は http / https で host のあるもの、名前は空でなく同じプロジェクト内で重ねない。
  全行が正しい間だけ保存し、途中の行がある間はファイルは前の内容のまま（行ごとに理由を赤で出す）。名前と URL が両方空の行は画面に残すだけで保存しない。
  開いただけ・空白を落としただけでは書き直さない（利用者が欄を触ってから）。
  「サイト」の節で LP の場所を指定（相対パスの入力・「フォルダを選ぶ…」（プロジェクトの外は選べない）・候補のボタン）・「自動に戻す」（キーを消す）。
  正しい相対パスの間だけ保存し、検出の結果（指定 / 自動で検出・書き出しの有無）を出す。
- **GitHub**: プロジェクトごとの owner / リポジトリ / Project 番号と、リポジトリに紐づかないボードの追加・編集・削除。
  owner は英数字と途中のハイフン（39 文字まで）、リポジトリは英数字と `. _ -`、番号は 1 以上。正しい間だけ保存する。GitHub 上に実在するかは確かめない。
- **iPhone 連携**: 上の「iPhone 連携」の設定（メニュー「claude-deck → iPhone 連携…」はこのタブを開く）と、「iPhone への通知」の入り切り・状態。
- **キャラクター**: 2D のドット絵を全状態ぶんルーム一覧と同じ動きで並べ、3D はステージと同じ組み立てで見本のセッションを、状態・サブエージェントの職業の組・持ち物を選んで描く。
  見るだけで、タブが見えている間だけ動き、「動きを減らす」設定では止まる。見本は `Sources/MonitorKit/Stage/CharacterGallery.swift`（テストあり）。
- **起動と終了**: 「起動時に前回のセッションを再開する」「作業中だったものに続きを頼む」（上の「終了と次の起動」）。
- **外観**: カラーテーマ「ナイト」（既定・従来の暗い配色）/「ライト」を選ぶ。UserDefaults に保存し、アプリの外観（`NSApp.appearance`）を差し替えて再起動なしで全画面に映す。
  システムの外観には追従しない。ライトは面が白で、段差はサイドバー・入力欄・コード面のごく薄いグレー、区切りは薄いグレーの線だけ。
  色はパステルの赤・青・緑・黄の 4 色だけを役割で使い分ける（青＝選択行・自分の吹き出し・切り替えバーの選択・入力待ち・リンク、緑＝稼働中・許可 / 送信・未読、
  黄＝権限待ち・権限 / 選択肢カード・ツール、赤＝エラー・拒否 / キャンセル。塗りは淡いパステル、文字に使う状態色は同じ色相の濃い版）。
  プロジェクトの印の色だけは利用者が選ぶ 11 色相で、ライトではナイトと同じ色相の濃い版（`ThemePalette.avatarPalette`）。Claude の吹き出しは白地に薄いグレーの枠。
  ステージの床・段・霧も白いパネルに馴染むグレー。色の組は `Sources/MonitorKit/Theme/DeckTheme.swift`・ステージの背景側は `StageBackdrop`（テストあり）。
- **書き出し・読み込み**: settings.json と同じ形で書き出す。読み込みは中身から形式を判断して、足りないものだけを足す（既にあるものは上書きしない）。
  - registry.tsv 形式（name / path / status / note。`#` の行と空行は無視）: 同じパスのプロジェクトは足さない。
  - github-projects.tsv 形式（name / owner / number / repo / url）: repo が `-`（または空）ならボードへ（owner + 番号が同じものは足さない）。
    repo 付きは同じ名前のプロジェクトがあり、まだ紐づけが無ければその `github` に入れる。同じ名前のプロジェクトが無い行は取り込まず
    （ボードにすると repo が落ちるため）、件数と「先に registry.tsv を読み込んでください」を出す。
  - 書き出した settings.json: プロジェクトはパス・ボードは owner + 番号で重複を除く。同じパスのプロジェクトに紐づけが無ければ紐づけだけ足し、
    `site` は手元に無い時だけ入れる。リンクは同じ名前（前後の空白は除く）の無いものだけ末尾に足す（同じ名前は手元を残す。ファイルの中で重なる名前も 1 つだけ）。
    名前が空・URL が http / https でないリンクは足さず、件数を「不正 N 件は除外」と出す。

型・読み書き・検証・移行・取り込みは `Sources/MonitorKit/Settings/`（テストあり）、画面は `Sources/ClaudeDeck/Settings/`。

## ビルド / 実行

```sh
cd /Users/shinjo/project/ai-manager/mac
swift build          # ビルド
swift run            # 起動（ウィンドウが開く）
swift test           # テスト
```

- Swift 6.3 / Xcode 26.5 で確認済み。Swift 6.4 / Xcode 27 では `swift build --build-system native` / `swift test --build-system native` で確認している
  （Metal Toolchain が無い環境では通常ビルドが SwiftTerm のシェーダーで失敗するため。下の「`.app` として起動する」）。

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
- ホスト中のルームはアプリを終了すると claude ごと終わる（次の起動で `--resume` で再開するが、作業は一度止まる。アプリを閉じても動かし続ける常駐プロセスの設計は `docs/pty-daemon.md`・未実装）。
- アプリが強制終了・クラッシュした時は、サイトの開発サーバー（`npm run dev`）と「iPhone のプレビュー」の mcpbridge が残りうる。
- 「iPhone のプレビュー」は起動中の Xcode（RenderPreview のある 27 以降）が要る（Xcode を起動していない時の自前の描き手は未実装）。描画とキャッシュへの写しは
  MonitorKit のクライアントで sandora（描けた）と mirio（ビルド失敗の文言）で確かめたが、アプリの画面での操作（グリッド・シートでの切り替え）とアプリからの初回の承認は目視で未確認。
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
