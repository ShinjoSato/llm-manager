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

- 管理対象とボードの紐づけは mac アプリの設定 `~/Library/Application Support/claude-deck/settings.json` が唯一の正（形は `mac/README.md`「設定（settings.json）」）。リポジトリには置かない。
- **管理対象・ボードを知りたい時は settings.json を `jq` で読む**:
  - 管理対象: `jq -r '.projects[] | [.name, .path, .status] | @tsv' ~/Library/Application\ Support/claude-deck/settings.json`
  - ボード: プロジェクトに紐づくものは `.projects[].github`（owner / repo / projectNumber）、リポジトリに紐づかないものは `.boards[]`（name / owner / number）。
    例: `jq -r '(.projects[] | select(.github.projectNumber) | [.name, .github.owner, .github.projectNumber, (.github.repo // "-")]), (.boards[] | [.name, .owner, .number, "-"]) | @tsv' <settings.json>`
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

`mac/` にある Swift/macOS ネイティブアプリ。プロジェクトごとに `claude`（Claude Code）を PTY でホストし、セッションをチャットアプリの操作感（トークルーム）で扱う。SwiftTerm（VT100 エミュレータ + PTY ホスト）使用。詳細は `mac/README.md`。

- **配置**: ai-manager 内 `mac/`（SPM 実行ファイル `claude-deck`）。
- **メイン画面 = チャット（画面案B）**: セッション 1 つ = トークルーム 1 つ。SwiftUI（`mac/Sources/ClaudeDeck/Chat/`。ChatModel と部品は `Chat/Model/`・画面は `Chat/Views/`。一覧は `Views/RoomList/`・会話は `Views/Conversation/`・入力欄は `Views/Composer/` に部品ごとのファイルで置く。端末ビューは `Terminal/` で `ClaudeTerminalView` を役割ごとの extension（`+Launch` / `+Input` / `+Screen` / `+Limit`）に分けている）を NSHostingView で載せる。
  - **ルーム一覧（左 312px）**: 監視のセッション + アプリでホスト中のセッションを「要対応（権限待ち・入力待ち）/ 稼働中 / 待機」に分けて表示。行はドット絵キャラのアイコン（ステージの 3D と同じ絵・配色。状態で姿勢と色が変わり、稼働中は跳ね、要対応はマークが点滅、待機は Zz が浮く。画面内の行だけ 4fps で描き直す。会話の見出しも同じ。絵は `packages/DeckCore/Sources/DeckCore/Pixel/PixelCharacter.swift`。iPhone アプリも同じ絵）・ブランチ・状態 + 直近の一行・時刻・未読数。外部セッションは「外部」タグ。検索・「+」（プロジェクト一覧から選んで `claude` 起動。動いているルームがある同じプロジェクトは重複起動せずそのルームへ移る）。検索欄の下に、監視の開始中はその旨、フックの受け口（:8766）を別のプロセスが使っている間はフックが届かない旨を出す。上限の残り% は出さない（statusLine はターミナル起動のセッションでしか更新されず値がずれるため。上限到達の強制終了の判定は別で従来どおり）。
  - **会話（中央）**: アプリ内の `TranscriptStore` から組み立てる（ルームを開いたら追記の購読を張ってから全件を取得。会話を持ち・購読するのは直近に開いた 4 ルームだけで、他は開き直した時に取り直す。監視を始め直した後は全件を取り直して置き換える）。ユーザー発話は右の青、Claude は左の暗色の吹き出し（Markdown の見出し・表・リスト・引用・区切り線・コードブロック・リンクを描く。解析は `packages/DeckCore/Sources/DeckCore/Chat/ChatMarkdown.swift`、描画は `ClaudeDeck/Chat/Views/MarkdownView.swift`。表は広い時だけ横スクロール）、ツールは「ツール N件 ▸」に畳む。表示の切替は無く常にチャット（端末ビューは画面に載せず、PTY の受信と画面読み取りだけに使う。ビュー階層に無くても動く）。claude が終了したルームも最後の sessionId で会話を出し続ける。
  - **入力欄**: ⏎ 送信・⇧⏎ 改行。ホスト中のセッションの PTY に bracketed paste で本文を入れ、0.3 秒後に Enter（作業中は Claude Code がキューに積む）。本文の制御文字（改行・タブ以外）は落とす。**端末で選択待ちの間は送らない**（権限プロンプト・plan 承認・AskUserQuestion・trust 確認など「❯」で選ぶメニューでは Enter が選択の確定になるため。判定は実画面の末尾（下の空行は除く）。上下の罫線に挟まれた入力欄の中は番号付きの文（`❯ 1. …`）でもメニューとみなさず、右に縦線 `│` で区切って出る差分パネルは除いて左だけを読む（`TerminalScreen.mainPane`）。メニューには下記の選択肢カードで答える。文言だけの「入力待ち」はバッジ用で送信は止めない）。判定は貼り付けの前と Enter の直前。途中で取りやめたセッションは、次の送信前に端末の入力欄が空かを確かめ、残っていれば送らない。TUI 更新時は `mac/Sources/MonitorKit/Chat/PTYInput.swift` の判定を見直す（入力欄は上下に罫線・メニューは ❯ の下を罫線で閉じない、差分パネルは縦線 1 本で区切る、が前提。`ScreenPane.swift`）。書きかけはルームごとに `ChatOutbox.drafts` に持つ。日本語の変換中（marked text）は確定前の文字が下書きに入らないため、再描画で入力欄へ書き戻すのは送信後の空など本当の外部変更の時だけ（`mac/Sources/MonitorKit/Chat/ComposerSync.swift`・テストあり）。変換中は送信ボタンも効かない。**添付**: クリップ・⌘V（ファイル URL か、文字列の無い画像。文字専用の NSTextView は画像だけのクリップボードで「ペースト」を無効にするため、添付にできる時はメニュー検証で有効にする。`AttachmentPasteTextView`）・ドロップで画像 / ファイルを添え、入力欄の上のチップ（× で外す）でルームごとに持つ。画像は `~/Library/Caches/claude-deck/attachments/`（0700 / 0600・7 日超は起動時に掃除）へ写し、そのパスだけを先に貼り付けて Claude Code に `[Image #N]` として取り込ませ（v2.1.286 の貼り付け処理で確認）、出たのを画面で確かめてから本文を貼る。送信中は次の送信を止めて「送信中…」を出し、本文を貼る前に選択待ちで取りやめたら本文と添付を入力欄へ戻す（本文を貼った後なら戻さない）。取り込み（写し・変換・サムネイル）はバックグラウンドで、画像は 1 件 20MB まで。ルームを閉じたら添付と一時ファイルを片付ける。画像以外は元のパスを本文末尾に書く（伝言は画像も含めパスを添える）。組み立てと掃除は `mac/Sources/MonitorKit/Chat/Attachments.swift`（テストあり）。**吹き出しの画像**: transcript の発話の画像（`images` 目録 + `MonitorStore.imageSource` で行を読み直して取り出す）をサムネイル（最大 3 列・角丸）で出し、クリックでシートに拡大。表示時にだけ読み込み、縮小して NSCache に持つ。画像を出せる時は本文の `[画像]` の印を外す。アプリから画像を添えて送った発話は、端末へ画像として貼った分だけを transcript に載るまで手元の一時ファイルで薄く出し（パスとして本文に回った画像だけなら出さない）、送信後の本人の発話で画像の枚数と本文（`[Image #N]`・`[画像]`・空白を除く）が一致するものが載ったら消す。3 分載らなければ下げる（伝言の点線吹き出しにも添えた画像を出す）。画面は `ClaudeDeck/Chat/Views/ChatImageViews.swift`、突き合わせは `packages/DeckCore/Sources/DeckCore/Chat/ChatImages.swift`（テストあり）。選択中のルームが一覧から消えても別のルームへ自動では移らない（自動選択は未選択の時だけ）。
  - **権限カード**: 会話末尾に amber のカード。監視の permissions（Channels）があれば `store.decide`、無ければ端末画面のプロンプトを読んで PTY に **許可 `1` / 拒否 `Esc`**（TUI v2.1.251 / v2.1.286 で確認）。押した時のカードと今のプロンプトが違えば送らない。送信中は二度押し不可。
  - **選択肢カード**: ホスト中のセッションの端末に plan 承認・AskUserQuestion・trust 確認などのメニューが出たら、権限カードと同じ位置に amber のカード（問いの上の本文・問い・選択肢・キャンセル（Esc））。中身は実画面から読む（`ChoiceMenu.parse`）。押すと **↑/↓ で「❯」を 1 行ずつ動かし、着いたのを画面で確かめてから Enter**（番号キーは使わない。trust 確認に番号が無く、番号キーが移動か即決定かがメニューで違うため）。「❯」の変化は送った向きへちょうど 1 行の時だけ受け入れ（2 行以上・逆向き・送っていない動きはやめる）、着いた位置が次の読み取りでも変わらない時だけ Enter。未反映の矢印は常に 0 か 1 個で、ナビゲーションをまたいでも保つ（反映を待ち切れなければ再送せずやめ、未反映の矢印を残した時は「❯」が動く・出力が 1.5 秒止まる・5 秒経つまで次の移動を始めない。`PendingArrowHold`）。押した時のカードと今のメニュー（本文・問い・選択肢）が違えば送らない・途中で変われば Enter を押さずにやめる・送信中は二度押し不可。Esc が claude の終了になるメニュー（案内が `Esc to exit`・trust 確認）はボタンを「終了（Esc）」にして確認を挟み、確認を開いた時のメニューで照合する（終了になるかどうかも一致を確かめる）。自由入力の行に「❯」が乗った空の `❯ n.` もメニューとして送信を止める。複数選択（チェック欄付き）は押すとチェックの切り替えになる旨を出し、選択肢の下の `Submit` / `Next` の行（番号無し）を「先へ進む」選択肢として同じ手順で押せる。AskUserQuestion のタブ行（`← ☒ 見出し ✔ Submit →`）は本文と分けてタブとして出し（今のタブは端末の背景色から読む）、「前の問い / 次の問い」は →/← を 1 回だけ送って問いが替わったのを確かめる（`MenuTabMover`。「❯」が文字入力の行にある時は送らない）。Submit タブの「Submit answers / Cancel」は通常の選択肢。縦線 `│` 付きで折り返した問いは 1 つにまとめる。文字入力の選択肢（「Type something.」「Tell Claude what to change」）は対象外（キャンセルして入力欄で伝える）。端末ビューは起動前に約 160 桁へ広げる。カードを出した・読めなかった画面の写しを `~/Library/Logs/claude-deck/menu-screens.log` に直近 5 件だけ残す（0600）。判定と手順は `mac/Sources/MonitorKit/Chat/MenuPrompt.swift`（TUI v2.1.286 のバイナリの描画コードで確認。テストあり）。本物の claude での目視は未確認。
  - **外部セッション（ターミナル等で起動したもの）**: 見出しに「外部セッション」タグとバナー。入力欄は黄色の「伝言」モードで `store.sendMessage`（受信箱ソケットへ直接書く）で送る（受け手には「別セッションからのメッセージ」として届き、本人の指示・権限承認にはならない）。受け手は伝言を isMeta で記録するため transcript には出ないので、送った伝言はアプリが覚えて点線の吹き出しで差し込む（写しが出ても `RelayNotes` で重複排除）。権限は監視の permissions（Channels）がある時だけ許可 / 拒否、無ければ「Channels を載せていない」旨を出す。
  - **アプリに引き継ぐ**: 確認ダイアログ → pid が今も同じ sessionId の claude か（uid・argv[0]/実行ファイル・`~/.claude/sessions/<pid>.json` の sessionId・`procStart` と起動時刻）を確かめてから SIGINT → 5 秒 → 同じプロセスのままなら SIGTERM → 終了を確認でき、同じ sessionId の生存 pid が他に無い時だけ同じ cwd で `claude --resume=<sessionId>`（UUID 形式のみ。API キー除去は維持）を PTY で起動し、通常のルームに切り替わる。終了を確認できなければ再開しない。上限到達中は引き継がない。引き継げるのはターミナル起動（`entrypoint: cli`）の対話セッションだけで、VS Code 拡張等は理由を出してボタンを出さない。npm 版（node）の claude は確かめられないので引き継げない。判定は `mac/Sources/MonitorKit/Chat/SessionHandover.swift`（テストあり）。
  - **ステージパネル（右 360px）**: 選択ルームのセッションの 3D ステージ（段々のピラミッド・最上段に親・1 つ下の段にサブエージェント最大 4 体・稼働中は持ち物・要対応は頭上の「!」「?」と光・段の縁取りが状態の色で脈打つ）を **アプリが SceneKit で描く**（3D 固定・背景透過）。寸法・色・カメラ・動きの数値は three.js で描いていた頃の見た目に合わせ、ACES トーンマッピングと sRGB での重ね方も揃えてある。組み立ては MonitorKit の純粋なロジック（`StageBlueprint`・`StageScene`）、SceneKit への起こしは `StageSceneRig`（オフスクリーン描画のテストあり。`STAGE_SNAPSHOT_DIR` で状態ごとの画像を書き出せる）、画面は `mac/Sources/ClaudeDeck/Stage/`（`StageSceneView`）。中身が変わった時だけ組み直し、表示中・ウィンドウが見えている・動くものがある時だけ 30fps で回す。「動きを減らす」設定では止める。下に「いまの動き」（スキル > 説明 > ツールの動作）・随伴するサブエージェント（職業名・状態）・ライブフィード（新しい順）。開閉は UserDefaults に保存し、ウィンドウ幅 1100px 未満では自動で畳む。監視の開始中・未解決はプレースホルダー。文言・判定は `mac/Sources/MonitorKit/Stage/StageLogic.swift`。
  - **プロジェクト一覧（「+」の中）**: ユーザーが自由に追加（「フォルダを追加…」）・削除（各行の「…」/右クリック →「一覧から削除」）でき、下部の「設定を開く…」で設定画面へ。設定画面と同じデータ（`SettingsStore`）を見るので即座に揃う。ボードの中身の表示はアプリには無い（会話の見出しの「GitHub」でブラウザに開くか、上の `gh` の手順で見る）。
  - **設定画面（「claude-deck → 設定…」⌘,）**: ウィンドウは 1 つ。タブは「プロジェクト」（追加・名前 / 状態 / メモの編集・削除（確認あり）・並べ替え）・「GitHub」（プロジェクトごとの owner / repo / Project 番号とリポジトリに紐づかないボード。入力は GitHub の文字種・正の整数で検証し、正しい間だけ保存。gh での存在確認はしない）・「iPhone 連携」（「iPhone 連携…」メニューもここを開く）・「書き出し・読み込み」（settings.json と同じ形で書き出し。読み込みは registry.tsv / github-projects.tsv / 書き出した settings.json を中身で判別し、足りないものだけ足す）。
  - **設定ファイル**: `~/Library/Application Support/claude-deck/settings.json`（`CLAUDE_DECK_SETTINGS` で差し替え・`claude-deck --print-settings-path` で場所を出す）。原子的に 0600 で書く（ディレクトリを 0700 にするのは既定の場所の時だけ）。壊れた・知らない version・id / path の重複・相対パスのファイルは上書きせず理由を出す（軽いものは警告）。無い時は以前の `projects.json` を取り込んで作る（`projects.json` は残す。書けなければ読んだ内容を出したまま、読み直しでやり直す）。置き場所のディレクトリとファイル自体を監視して外の変更（置き換え・その場の書き換え）をすぐ読み直し、保存の直前にも読み直して外の変更に今の変更をかけ直す（かけ直せないものがあれば捨てて案内を出す。同じ欄の入力とぶつかれば外の変更を残す）。書きかけを読んだら入力を残して少し後に読み直す。一度作った後に外で消されたら空の一覧として扱い、移行し直さない。文字欄は 0.5 秒まとめて保存（設定画面での変換中は待つ・閉じる時と終了時は書き切る）。型・読み書き・検証・移行・取り込みは `mac/Sources/MonitorKit/Settings/`（テストあり）、画面は `mac/Sources/ClaudeDeck/Settings/`。
- **「GitHub」ボタン**: ルームの cwd が settings のプロジェクトの `path` と一致するか配下にあり（複数ならいちばん深い path）、そのプロジェクトに `github` の紐づけがあるルームだけ、見出しの「VS Code」の隣に出す。開く先が 1 つ（Project 番号かリポジトリ）ならそのまま、両方あればメニュー（「Project ボードを開く」「リポジトリを開く」）。既定のブラウザで開く（`NSWorkspace.open`）。ボードの URL は owner が個人なら `github.com/users/…/projects/N`、組織なら `orgs/…`で、種類は押した時に公開 API `api.github.com/users/<owner>` の `type` で引き（認証なし・3 秒・owner ごとにアプリが動いている間だけ覚える）、取れなければ users の形で開く。設定の変更はすぐボタンに映る。判定と URL は `mac/Sources/MonitorKit/Projects/GitHubLinks.swift`（テストあり）。
- **「Xcode」「閉じる」ボタン**: プロジェクト配下（浅い範囲・`ios/` 等のサブディレクトリ含む）に `.xcworkspace`/`.xcodeproj` があるルームだけ、見出しにラベル付きの「Xcode」「閉じる」を出す（「VS Code」は常に出す）（`mac/Sources/MonitorKit/Hub/XcodeFinder.swift`）。「Xcode」は `NSWorkspace.open` で Xcode の GUI を開く（実行＝Cmd+R はユーザー操作）。「閉じる」は確認ダイアログの後、AppleScript をアプリから `osascript` で実行してそのワークスペースだけを閉じる（Xcode 本体は終了しない・未起動なら立ち上げない）。結果は見出しに数秒出す。判定と文言は `mac/Sources/MonitorKit/Projects/EditorActions.swift`（テストあり）。初回は macOS のオートメーション許可が要る。`.xcworkspace` 優先・最も浅い階層を選択。SPM のみ（claude-deck 自身等）は非表示。ワンクリックでのシミュレータ自動実行（`xcodebuild`/`simctl`）は将来。
- **設計の絶対方針（料金事故ゼロ）**: 子プロセスの環境から `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` を必ず除去して `claude` を起動する（Claude Code の中から起動された時の `CLAUDE_CODE_*` 等の子セッション印も除く）。API 課金経路を作らないため、Max 枠の上限に達しても課金は発生しない（待つだけ）。**headless（`claude -p` / Agent SDK）の起動口は設けない方針**。
- **上限到達で強制終了**: 公式の残量（アプリ内の監視が statusLine の書いた使用量ファイルから読む `MonitorStore.usage`。5 時間 / 7 日間が 100% 以上かつ取得 10 分以内）を主、端末の実画面の末尾に出た上限表示（Claude Code v2.1.286 のバイナリで確認した文言のみ・会話本文は見ない）を補助として、ホスト中の全セッションを `terminate()`。到達はリセット時刻まで覚え、その間の新規起動も止める。判定は `mac/Sources/MonitorKit/Limit/LimitGuard.swift`（テストあり）、購読は `mac/Sources/ClaudeDeck/App/LimitWatch.swift`。残量経路は statusLine（`mac/scripts/statusline.sh`）の設定が前提。
- **ビルド/実行**: `cd mac && swift build` / `swift run`。ビルドは Swift 6.3 / Xcode 26.5 で確認済み（共有パッケージ化の後は Swift 6.4 / Xcode 27 で `swift build --build-system native` / `swift test --build-system native` を確認）。
- **署名・識別子**: チーム ID・バンドル ID・iCloud コンテナはリポジトリに書かず、`config/Local.xcconfig`（追跡しない。雛形は `config/Local.example.xcconfig`）に `DEVELOPMENT_TEAM`・`DECK_BUNDLE_PREFIX`・`DECK_ICLOUD_CONTAINER` を書く。既定（`config/Deck.xcconfig`）はチーム・コンテナ空・`local.claude-deck`。iPhone の Xcode プロジェクトは全構成が `Deck.xcconfig` を土台にし、mac の bundle.sh も同じファイルを読む（環境変数 `CLAUDE_DECK_TEAM_ID` / `CLAUDE_DECK_BUNDLE_PREFIX` / `CLAUDE_DECK_ICLOUD_CONTAINER` で上書き可）。手順は `mac/README.md`「署名・識別子」。
- **`.app` 化**: `mac/scripts/bundle.sh` → `mac/dist/claude-deck.app`（バンドル ID は `DECK_BUNDLE_PREFIX`、Info.plist の `DeckICloudContainer` もここで埋める。チーム ID とコンテナが設定されていて、このアプリ用の macOS のプロビジョニングプロファイル（`--profile`・`CLAUDE_DECK_PROFILE`・`mac/Resources/claude-deck.provisionprofile`（追跡しない）・Xcode のプロファイル置き場の順）があれば Apple Development で署名して iCloud のエンタイトルメント（`mac/Resources/claude-deck.entitlements`）を付け、無ければ ad-hoc。チャネル `Contents/MacOS/claude-deck-channel` も同梱）→ `open mac/dist/claude-deck.app`。Metal Toolchain が無い環境では通常ビルドが SwiftTerm のシェーダーで失敗するため、自動で `--build-system native` に切り替える。Developer ID 署名・公証・配布・自動更新はしない。
- **アプリ内サーバー（:8766）**: 起動時に `127.0.0.1:8766` で小さな HTTP サーバー（Network.framework）を開き、外から叩かれる口だけを出す: `POST /hook`（`~/.claude/settings.json` のフックの宛先そのまま）・`POST /api/channel/permissions`（Channels の `claude-deck-channel` が使う）・`GET /api/health`。全口で Host / Origin / 接続元（ループバックのみ）を確かめ、POST は `content-type: application/json` 必須・本文 8MB まで・同時接続 64 まで（超えたら即切断）。`/hook` は本文を確かめたら反映を待たずに 200 を返し、反映は届いた順に後から流す（初回走査中でも curl の 1 秒に間に合わせるため）。フックの時刻は受け口に届いた時刻で数え（時刻の取得と積み込みは一続きで、待ち行列の順＝時刻の順）、届いた後のログ活動を反映前に読んでいれば権限待ち等は答え済みとして出さない。未知のセッションのメタ読み込みで後ろのフックを待たせない。止めて開き直す時は前の待ち受けがポートを手放すのを待つ（最大 2 秒）。振り分け後の相手の FIN は切断とみなさない（半閉じの相手にも応答を返す。長ポーリングは早めに timeout を返し、全閉じなら送信の失敗で閉じて待ち手を外す）。ポートは `CLAUDE_DECK_SERVER_PORT`（`off` で開かない）。**8766 を別のプロセスが使っている時は奪わず・止めず**、ルーム一覧にフックが届かない旨を出して監視は続け、5 秒ごとに取り直す（そのプロセスを止めれば自動で引き継ぐ）。アプリが動いていない間のフックは取りこぼす（curl は 1 秒で諦めるだけ）。アプリ側の SIGTERM / SIGINT は `SIG_IGN` にしない（exec を越えてホスト中の claude に残り、上限到達時の `terminate()` が効かなくなる。何もしないハンドラで捕捉して通常の終了経路に乗せる）。実装は `mac/Sources/MonitorKit/Server/`、状態は `MonitorStore.serverState`。
- **iPhone 連携の口**: 設定画面の「iPhone 連携」タブ（メニュー「claude-deck → iPhone 連携…」でも開く）で有効にした時だけ（**既定は無効**）、選んだ LAN のインターフェースの IPv4 アドレス・既定ポート 8767 で **TLS のみ**で待ち受ける（0.0.0.0 にはしない。:8766 のフック・チャネルの口とは別のサーバーで、`/hook` 等は LAN に出さない）。初回に自己署名の証明書（P-256。DER を自前で組む）を作って `~/Library/Application Support/claude-deck/remote/` に 0600 で置き（キーチェーンは使わない）、QR（`claude-deck://pair?...`: 接続先・5 分で失効の 1 回限りの一時トークン・証明書の SHA-256 指紋）で iPhone にピン留めさせる。`POST /v1/pair` で端末トークン（256bit。mac にはハッシュだけ）を発行し、全 API は Bearer。失敗は接続元ごとに回数制限。ウィンドウで端末一覧（接続中・最後に使った時刻）と取り消し。API は `/v1`（一覧・状態・要対応、SSE の変化、会話・画像、権限の許可 / 拒否、選択肢の回答、メッセージ送信）で、仕様は `mac/docs/remote-api.md`、共有の型とクライアントは `packages/DeckCore`（`Remote/`・`Client/`）。**iPhone からの操作は `ChatModel+Remote.swift` が画面のカード・入力欄と同じ処理（`MonitorStore.decide`・`answerOnTerminal`・`answerMenu`・`HostedSession.send`・伝言）に渡す**（`promptId` / `menuId` が今のものと一致する時だけ・選択待ちでは送らない。ID には表示の世代を混ぜ、同じ文面で出し直された確認に古い表示から答えさせない。答えた ID の押し直しは `answered` で送らない）。有効にした時のネットワーク（アドレス帯 + ルーターの MAC）を覚え、別のネットワークでは開かずに画面で確かめさせる。新しい claude の起動口・headless の口は無い。実機ではファイアウォールの「受信接続を許可」を確かめる。
- **要対応の iPhone 通知（iCloud）**: 要対応（権限待ち・入力待ち・エラー）が 5 秒続いたら、自分の iCloud（コンテナは `config/Local.xcconfig` の `DECK_ICLOUD_CONTAINER`・CloudKit のプライベート DB）にレコード `AttentionNotice`（ルーム名・定型文・時刻・ルーム / セッション ID だけ。**会話の本文・ツールの入力は載せない**）を書き、解消したら消す。同じ要対応は 1 回、その時に待っている他のルームは 1 件にまとめ、1 件書いたら 30 秒は次を書かない（`AttentionNoticePlanner`）。失敗は静かに送り直す（`AttentionNoticeSync`）。iPhone は `CKQuerySubscription`（作成時のみ）でプッシュを受け、開くと該当ルームへ。**コンテナが空・未定義の起動（`swift run` を含む）と、エンタイトルメントの無い起動（ad-hoc）では無効**で、設定画面の「iPhone 連携」タブに理由を出す。**iCloud コンテナ・App ID・プロファイルの登録はユーザーが行う**（コンテナは消せない。Claude は `-allowProvisioningUpdates` も実行しない）。手順は `mac/README.md`「iPhone への通知（iCloud・CloudKit）」。

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
- **8766 を別のプロセスが使っている時**: アプリはポートを奪わずにフックが届かない旨を出す。止めれば 5 秒以内にアプリが受け口を引き継ぐ。
- 制約: macOS ローカルのセッションのみ（クラウドセッションは映らない）。ログの粒度はターン／ツール単位で、生成中テキストは流れない。

## スプレッドシート勉強管理

- 未着手。着手時に方針をここに追記する。

## メモ
- GitHub リポジトリは `ShinjoSato/llm-manager`（ベースブランチは develop）。`.gitignore` で `node_modules/`・ビルド成果物・削除済みの `monitor/` の残骸を除外。
- **手元だけで持つもの（git で追跡しない）**: `config/Local.xcconfig`（署名・識別子）、`.claude/github-project.json`（開発フローの設定）、
  `~/Library/Application Support/claude-deck/`（settings.json・iPhone 連携の証明書と端末トークン・usage.json）。リポジトリに秘密情報の置き場は無い。
- 開発フロー（developer-plugin）の設定 `.claude/github-project.json` は **git で追跡せず手元で持つ**（GitHub の owner・リポジトリ・Project の各 ID を含むため）。
  新しい clone では `.claude/github-project.example.json` をコピーして値を入れるか、developer-plugin の `project-init` で作る。無いと Issue〜PR の skill は動かない。
  - スクリプトはカレントから上へ探すので、`.claude/worktrees/` の中からでも本体のファイルを読む。
  - このファイルを追跡していた頃のコミット・ブランチと行き来すると git が手元のファイルを消すことがある。消えたら作り直す。
- 旧ダッシュボード（データ中核 server・Web・MCP・App Store / Google カレンダー連携・補助シェル）は使われていなかったため削除済み。App Store の確認は appstore-plugin の skill、カレンダーは claude.ai の Google Calendar MCP を使う。
