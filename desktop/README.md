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
desktop/
  Package.swift                 SPM。SwiftTerm を依存に持つ実行ファイル "claude-deck"
  Sources/ClaudeDeck/
    main.swift                  NSApplication 起動
    AppDelegate.swift           ウィンドウ + メニュー
    MainSplitViewController.swift   サイドバー + メイン領域の2ペイン
    SidebarViewController.swift     プロジェクト一覧（名称 + パス表示・追加/削除）
    ProjectStore.swift              一覧の永続化（Application Support の JSON）
    TileContainerViewController.swift 開いたセッションをタイル状に同時表示・グリッド配置
    TerminalPaneViewController.swift 1ペイン = Claude Code / GitHub を切替（見出し + ✕）
    GitHubBoard.swift               github-projects.tsv 読込 + gh によるボード取得
    GitHubBoardView.swift           Issue をステータス別にグループ表示（クリックで GitHub を開く）
    ClaudeTerminalView.swift    PTY ホスト + 環境からの API キー除去 + 上限文言監視
    ProjectRegistry.swift       projects/registry.tsv のパーサ
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
- 解決順（github-projects.tsv）: 環境変数 `CLAUDE_DECK_GH_PROJECTS` → 上方探索 → 既定 `/Users/shinjo/project/ai-manager/projects/github-projects.tsv`。

**永続化先**: `~/Library/Application Support/claude-deck/projects.json`（人が読める JSON）。
**初回のみ** `registry.tsv` から取り込んで空にしない（以降は完全にユーザー管理）。

### registry.tsv の解決順（初回取り込み / 取り込みボタン）

1. 環境変数 `CLAUDE_DECK_REGISTRY`（絶対パス）
2. カレントディレクトリから上方探索で `projects/registry.tsv`
3. 既定 `/Users/shinjo/project/ai-manager/projects/registry.tsv`

## ビルド / 実行

```sh
cd /Users/shinjo/project/ai-manager/desktop
swift build          # ビルド
swift run            # 起動（ウィンドウが開く）
```

> 端末から起動すると PATH（`~/.local/bin` の `claude` など）を確実に継承できる。
> アプリ内でも各セッションをログインシェル経由で起動するため、GUI 起動でも `claude` は解決される想定。

## 現状の制約 / TODO

- `.app` バンドル化・コード署名は未対応（`swift run` 起動の PoC 段階）。配布時は Developer ID 署名を検討。
- 上限検知の文言は要・実機検証（上記）。
- 削除しても、開いているタブは閉じない（タブ側は手動で対応）。サイドバーとタブの連動は将来拡張。
- 追加時の表示名はフォルダ名固定（リネーム UI は未実装）。
- タブのウィンドウ分割・レイアウト保存・GitHub ステータスバッジ等は将来拡張。
