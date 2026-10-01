# claude-deck

プロジェクトごとに **Claude Code を同時起動**する macOS ネイティブ司令塔アプリ（PoC）。
ai-manager の管理対象プロジェクト一覧と連携し、各プロジェクトのディレクトリで `claude` を端末として起動する。

SwiftTerm（VT100/Xterm エミュレータ + PTY ホスト）を使い、Terminal.app 同等の操作感を持たせている。

## 設計上の方針（重要）

- **料金事故ゼロ**: 子プロセスの環境から `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` を必ず除去して `claude` を起動する。API 課金経路が存在しないため、Max 枠の上限に達しても「待つ」だけで課金は発生しない。さらにログインシェル側でも `unset` してから `exec claude` する二重防御。
- **headless 不採用**: `claude -p` / Agent SDK の起動口は一切設けない（別枠課金や非対話実行を避ける）。
- **上限到達で強制終了**: PTY 出力を監視し、Claude Code が出す「上限到達」文言を検知したら、そのセッションを `terminate()` で強制終了し、警告ダイアログを出す。
  - ⚠️ **要・実機検証**: 検知文言は `Sources/ClaudeDeck/ClaudeTerminalView.swift` の `limitPhrases` に暫定で複数並べてある。実際の Claude Code の上限メッセージ文言を確認し、最小限に絞ること。正確な「残り何%」を返すクリーンな公開 API は無いため、本実装は「100%到達の文言検知 → 強制終了」という事後トリガー方式。

## 構成

```
mac/
  Package.swift                 SPM。SwiftTerm を依存に持つ実行ファイル "claude-deck"
  Sources/ClaudeDeck/
    main.swift                  NSApplication 起動
    AppDelegate.swift           ウィンドウ + メニュー
    MainSplitViewController.swift   サイドバー + メイン領域の2ペイン
    SidebarViewController.swift     プロジェクト一覧（名称 + パス表示・追加/削除）
    ProjectStore.swift              一覧の永続化（Application Support の JSON）
    TileContainerViewController.swift 開いたセッションをタイル状に同時表示・グリッド配置
    TerminalPaneViewController.swift 1ペイン = Claude Code / GitHub / App Store を切替（見出し + ✕）
    GitHubBoard.swift               github-projects.tsv 読込 + gh によるボード取得
    GitHubBoardView.swift           Issue をステータス別にグループ表示（クリックで GitHub を開く）
    AppStoreClient.swift            appstore.tsv 読込 + server HTTP API（/api/appstore）の取得
    AppStoreView.swift              審査/提出/ビルド/評価サマリ表示（Web の AppStoreCard 相当）
    ClaudeTerminalView.swift    PTY ホスト + 環境からの API キー除去 + 上限文言監視
    ProjectRegistry.swift       projects/registry.tsv のパーサ
    AIManagerRoot.swift         ai-manager ルートの解決（.app 起動でも TSV / monitor を引ける）
    MonitorBridge.swift         アプリ全体で 1 つの MonitorStore（SSE 接続は 1 本）
  Sources/MonitorKit/           monitor（:8766）クライアント。UI 無し・テスト可能な library
    MonitorModels.swift         monitor/src/types.ts に対応する Codable 型
    SSEParser.swift             text/event-stream の逐次パーサ（URLSession の生バイトを自前で解釈）
    MonitorEvent.swift          sessions / feed / feed-batch / usage / permissions / transcript のデコード
    MonitorConfiguration.swift  接続先・無通信タイムアウト・再接続バックオフ
    MonitorClient.swift         SSE 購読（自動再接続）+ REST / 書き込み系ラッパー
    MonitorStore.swift          @Observable ストア（接続状態・セッション・フィード・残量・権限確認・pid 対応付け）
    ClaudeSessionRegistry.swift ~/.claude/sessions/<pid>.json から sessionId を引く
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

```sh
# GUI 無しで接続・再接続・対応付けを確かめる（45 秒、pid 14978 をホスト中とみなす）
CLAUDE_DECK_MONITOR_PORT=8799 swift run monitor-probe 45 14978
# 実 monitor に繋ぐテスト（未設定ならスキップ）
MONITOR_TEST_URL=http://127.0.0.1:8799 swift test
```

## プロジェクト一覧（ユーザー管理 + 永続化）

サイドバーの一覧は**ユーザーが自由に追加・削除でき、永続化される**。

- 表示: 各行は **名称（上）+ フルパス（下・中央省略、ホバーで全文）**。
- 追加: 下部の **「+」** → フォルダ選択（複数可）。選んだディレクトリで `claude` を起動するエントリになる。
- 削除: **「−」** / **Delete キー** / 行を**右クリック → 削除**。
- 起動: 行を**ダブルクリック / Enter**（単純選択では起動しない＝削除操作の邪魔をしない）。
- 取り込み: **取り込みボタン**で `registry.tsv` の内容を一覧へマージ（重複パスは無視）。

### メイン領域: 複数セッションの同時表示

開いたセッションは**タイル状のグリッドに並べて同時表示**する（タブ切替ではない）。

- プロジェクトを開くたびにペインが増え、`ceil(√n)` 列の均等グリッドに自動配置。
- 各ペインに見出し（名称）と **✕** があり、個別に閉じられる。
- 同じプロジェクトを再度開くとフォーカスのみ（重複起動しない）。

### ペイン内: Claude Code / GitHub 切替

GitHub Project のマッピングがあるプロジェクトは、ペイン見出しに **「Claude Code / GitHub」** のセグメント切替が出る。

- **Claude Code**: 端末（既定）。GitHub に切り替えても `claude` プロセスは裏で動き続ける。
- **GitHub**: そのプロジェクトの Issue を**ステータス別（Todo / In Progress / Debug / Review / Done / その他）にグループ化**して表示。各行は `[repo] #番号 タイトル @担当`、**クリックで GitHub を開く**。右上の 🔄 で再取得。
- マッピング元: `projects/github-projects.tsv`（name / owner / number / repo / url）。**マッピングが無いプロジェクトでは切替を出さず Claude Code のみ**。
- 取得は `gh project item-list <number> --owner <owner> --format json` をログインシェル経由で実行（**`gh` の認証 + `project` スコープが前提**）。
- 解決順（github-projects.tsv）: 環境変数 `CLAUDE_DECK_GH_PROJECTS` → ai-manager ルート配下（後述「ai-manager ルートの解決」）。

### ペイン内: App Store 切替

`projects/appstore.tsv` に登録があるプロジェクト（mirio / sandora 等）は、ペイン見出しに **App Store** トグル（🅰️ `app.badge`）が追加で出る。

- **App Store**: そのアプリの審査ステータス・最新 TestFlight ビルド・レビュー件数などを **Web の AppStoreCard 相当のサマリ**で表示。REJECT/FAILED 系は赤、配信中/完了/利用可は緑のバッジ（Web と色基準を合わせている）。右上の 🔄 で再取得。
- ロジックは **server に一本化**。claude-deck は ASC API を直接叩かず、既存 HTTP API `GET /api/appstore/:name` を fetch するだけ（二重実装しない）。
- 前提: **server（`:8765`）が起動していること**（`./scripts/dev.sh` 等）。**server 未起動・API エラー・認証未設定時は、その旨をペイン内に文言表示してフォールバック**（アプリは落とさない）。
- 対象判定元: `projects/appstore.tsv`（name / bundleId）。**登録が無いプロジェクトでは App Store トグルを出さない**。
- 解決順（appstore.tsv）: 環境変数 `CLAUDE_DECK_APPSTORE_TSV` → ai-manager ルート配下（後述「ai-manager ルートの解決」）。API ベース URL は `CLAUDE_DECK_API_BASE`（既定 `http://localhost:8765`）で差し替え可能。

**永続化先**: `~/Library/Application Support/claude-deck/projects.json`（人が読める JSON）。
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
- 上限検知の文言は要・実機検証（上記）。
- 削除しても、開いているタブは閉じない（タブ側は手動で対応）。サイドバーとタブの連動は将来拡張。
- 追加時の表示名はフォルダ名固定（リネーム UI は未実装）。
- タブのウィンドウ分割・レイアウト保存・GitHub ステータスバッジ等は将来拡張。
